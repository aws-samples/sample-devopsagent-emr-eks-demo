"""Runbook tools for the MCP server.

Provides semantic search, retrieval, and listing of runbooks
backed by Amazon Bedrock Knowledge Base and S3.
"""

import logging
import os
from typing import List, Optional

import boto3
import yaml

from mcp_server.models import (
    MCPErrorResponse,
    RunbookDetail,
    RunbookMatch,
    RunbookSummary,
    SearchResult,
)

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
KNOWLEDGE_BASE_ID = os.environ.get("KNOWLEDGE_BASE_ID", "")
RUNBOOK_BUCKET = os.environ.get("RUNBOOK_BUCKET", "")

logger = logging.getLogger(__name__)


def _get_bedrock_agent_runtime_client():
    return boto3.client("bedrock-agent-runtime", region_name=AWS_REGION)


def _get_s3_client():
    return boto3.client("s3", region_name=AWS_REGION)


async def search_runbooks(
    query: str,
    severity_filter: Optional[str] = None,
    category_filter: Optional[str] = None,
) -> SearchResult:
    """Semantic search over runbooks via Bedrock Knowledge Base retrieve API.

    Args:
        query: Natural language search query.
        severity_filter: Optional severity filter (SEVERE or NON_SEVERE).
        category_filter: Optional category/tag filter.

    Returns:
        SearchResult with ranked runbook matches.
    """
    if not query or not query.strip():
        raise ValueError("query must be a non-empty string")

    client = _get_bedrock_agent_runtime_client()

    retrieve_kwargs = {
        "knowledgeBaseId": KNOWLEDGE_BASE_ID,
        "retrievalQuery": {"text": query},
        "retrievalConfiguration": {
            "vectorSearchConfiguration": {"numberOfResults": 10}
        },
    }

    # Apply metadata filter for severity if provided
    filters = []
    if severity_filter:
        filters.append(
            {
                "equals": {
                    "key": "severity",
                    "value": severity_filter.upper(),
                }
            }
        )
    if category_filter:
        filters.append(
            {
                "equals": {
                    "key": "tags",
                    "value": category_filter,
                }
            }
        )

    if filters:
        if len(filters) == 1:
            retrieve_kwargs["retrievalConfiguration"]["vectorSearchConfiguration"][
                "filter"
            ] = filters[0]
        else:
            retrieve_kwargs["retrievalConfiguration"]["vectorSearchConfiguration"][
                "filter"
            ] = {"andAll": filters}

    response = client.retrieve(**retrieve_kwargs)

    matches: List[RunbookMatch] = []
    for result in response.get("retrievalResults", []):
        content_text = result.get("content", {}).get("text", "")
        score = result.get("score", 0.0)
        metadata = result.get("metadata", {})

        matches.append(
            RunbookMatch(
                scenario_name=metadata.get("scenario_name", "unknown"),
                relevance_score=score,
                severity=metadata.get("severity", "NON_SEVERE"),
                tags=metadata.get("tags", []),
                snippet=content_text[:500],
            )
        )

    return SearchResult(
        matches=matches,
        query=query,
        total_results=len(matches),
    )


async def get_runbook(runbook_id: str) -> RunbookDetail:
    """Retrieve full runbook content from S3 by ID.

    Args:
        runbook_id: The S3 object key identifying the runbook
                    (e.g. "memory/spark-oom-failure.yaml").

    Returns:
        RunbookDetail with full parsed runbook content.
    """
    if not runbook_id or not runbook_id.strip():
        raise ValueError("runbook_id must be a non-empty string")

    s3 = _get_s3_client()

    # Runbooks are stored under the runbooks/ prefix in S3
    key = runbook_id if runbook_id.startswith("runbooks/") else f"runbooks/{runbook_id}"
    response = s3.get_object(Bucket=RUNBOOK_BUCKET, Key=key)
    body = response["Body"].read().decode("utf-8")
    content = yaml.safe_load(body) or {}

    return RunbookDetail(
        runbook_id=runbook_id,
        scenario_name=content.get("scenario_name", "unknown"),
        description=content.get("description", ""),
        severity=content.get("severity", "NON_SEVERE"),
        content=content,
    )


async def list_runbooks() -> List[RunbookSummary]:
    """List all runbooks stored in the S3 runbook bucket with metadata.

    Returns:
        List of RunbookSummary objects for every YAML runbook in the bucket.
    """
    s3 = _get_s3_client()

    paginator = s3.get_paginator("list_objects_v2")
    summaries: List[RunbookSummary] = []

    for page in paginator.paginate(Bucket=RUNBOOK_BUCKET):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith((".yaml", ".yml")):
                continue

            try:
                resp = s3.get_object(Bucket=RUNBOOK_BUCKET, Key=key)
                body = resp["Body"].read().decode("utf-8")
                data = yaml.safe_load(body) or {}

                summaries.append(
                    RunbookSummary(
                        scenario_name=data.get("scenario_name", key),
                        severity=data.get("severity", "NON_SEVERE"),
                        tags=data.get("tags", []),
                        description=data.get("description", ""),
                        runbook_id=key.removeprefix("runbooks/"),
                    )
                )
            except Exception as exc:
                # Skip runbooks that cannot be parsed
                logger.warning("Failed to parse runbook %s: %s", key, exc)
                continue

    return summaries

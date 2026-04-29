"""Amazon EMR Spark Runbook MCP Server.

Exposes runbook search/retrieval only. Amazon EMR job status, Spark logs, and
Amazon CloudWatch metrics come from the DevOps Agent's built-in AWS capabilities.

Environment variables:
    KNOWLEDGE_BASE_ID — Amazon Bedrock Knowledge Base ID for semantic runbook search
    RUNBOOK_BUCKET    — Amazon S3 bucket name containing runbook YAML files
    AWS_REGION        — AWS region (default: us-east-1)
"""

from typing import Optional

from mcp.server.fastmcp import FastMCP

from mcp_server.models import MCPErrorResponse
from mcp_server.tools import runbook_tools

# Binding to 0.0.0.0 is intentional: this server runs inside an Amazon Bedrock AgentCore Runtime
# container where the orchestrator reaches it via the pod network interface.
# Binding to 127.0.0.1 would make the server unreachable.
mcp = FastMCP("emr-spark-runbook-mcp", host="0.0.0.0", stateless_http=True)  # nosec B104


@mcp.tool()
async def search_runbooks(
    query: str,
    severity_filter: Optional[str] = None,
    category_filter: Optional[str] = None,
) -> dict:
    """Semantic search over Amazon EMR and Apache Spark runbooks via Amazon Bedrock Knowledge Base.

    Args:
        query: Natural language search query describing the issue.
        severity_filter: Optional filter by severity (SEVERE or NON_SEVERE).
        category_filter: Optional filter by category tag.

    Returns:
        Search results with ranked runbook matches.
    """
    try:
        result = await runbook_tools.search_runbooks(
            query=query,
            severity_filter=severity_filter,
            category_filter=category_filter,
        )
        return result.model_dump()
    except ValueError as exc:
        return MCPErrorResponse(
            error_code="INVALID_PARAMS", message=str(exc)
        ).model_dump()
    except Exception as exc:
        return MCPErrorResponse(
            error_code="KB_UNAVAILABLE",
            message=f"Knowledge Base search failed: {exc}",
        ).model_dump()


@mcp.tool()
async def get_runbook(runbook_id: str) -> dict:
    """Retrieve full runbook content from S3 by identifier.

    Args:
        runbook_id: S3 key of the runbook (e.g. "memory/spark-oom-failure.yaml").

    Returns:
        Full runbook content including all investigation steps and remediation actions.
    """
    try:
        result = await runbook_tools.get_runbook(runbook_id=runbook_id)
        return result.model_dump()
    except ValueError as exc:
        return MCPErrorResponse(
            error_code="INVALID_PARAMS", message=str(exc)
        ).model_dump()
    except Exception as exc:
        return MCPErrorResponse(
            error_code="S3_ERROR",
            message=f"Failed to retrieve runbook: {exc}",
        ).model_dump()


@mcp.tool()
async def list_runbooks() -> list:
    """List all available runbooks with scenario names, severity, and tags.

    Returns:
        List of runbook summaries from the S3 runbook bucket.
    """
    try:
        results = await runbook_tools.list_runbooks()
        return [r.model_dump() for r in results]
    except Exception as exc:
        return [
            MCPErrorResponse(
                error_code="S3_ERROR",
                message=f"Failed to list runbooks: {exc}",
            ).model_dump()
        ]


if __name__ == "__main__":
    mcp.run(transport="streamable-http")

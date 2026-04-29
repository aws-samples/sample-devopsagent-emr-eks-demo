"""Pydantic models for the EMR Spark Runbook MCP server."""

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class RunbookMatch(BaseModel):
    """A single runbook match from semantic search."""
    scenario_name: str = Field(..., description="Unique runbook scenario name")
    relevance_score: float = Field(..., ge=0.0, le=1.0)
    severity: str = Field(..., description="SEVERE or NON_SEVERE")
    tags: List[str] = Field(default_factory=list)
    snippet: str = Field("")


class SearchResult(BaseModel):
    """Result of a runbook semantic search."""
    matches: List[RunbookMatch] = Field(default_factory=list)
    query: str = Field(...)
    total_results: int = Field(0, ge=0)


class RunbookSummary(BaseModel):
    """Summary metadata for a single runbook."""
    scenario_name: str = Field(...)
    severity: str = Field(...)
    tags: List[str] = Field(default_factory=list)
    description: str = Field("")
    runbook_id: str = Field("", description="S3 key to pass to get_runbook (e.g. memory/spark-oom-failure.yaml)")


class RunbookDetail(BaseModel):
    """Full runbook content retrieved by ID."""
    runbook_id: str = Field(...)
    scenario_name: str = Field(...)
    description: str = Field("")
    severity: str = Field(...)
    content: Dict[str, Any] = Field(default_factory=dict)


class MCPErrorResponse(BaseModel):
    """Structured error response."""
    error_code: str = Field(...)
    message: str = Field(...)
    details: Optional[Dict[str, Any]] = Field(None)

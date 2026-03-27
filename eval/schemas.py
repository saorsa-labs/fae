"""Unified schema for all eval scenarios and results."""

from __future__ import annotations

import enum
from datetime import datetime, timezone
from typing import Any

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class Dimension(str, enum.Enum):
    tool_calling = "tool_calling"
    intelligence = "intelligence"
    freeform = "freeform"
    throughput = "throughput"
    vision = "vision"
    personality = "personality"
    safety = "safety"
    voice_pipeline = "voice_pipeline"
    memory = "memory"
    assistant_fit = "assistant_fit"


class Verdict(str, enum.Enum):
    passed = "pass"
    partial = "partial"
    fail = "fail"
    error = "error"
    skipped = "skip"


class Difficulty(str, enum.Enum):
    basic = "basic"
    intermediate = "intermediate"
    advanced = "advanced"


class HardwareTier(str, enum.Enum):
    any = "any"
    gb16 = "16gb"
    gb32 = "32gb"
    gb64 = "64gb"


# ---------------------------------------------------------------------------
# Scenario definition (unified format)
# ---------------------------------------------------------------------------

class ToolExpectation(BaseModel):
    name: str
    args_contain: dict[str, Any] = Field(default_factory=dict)


class MockToolResponse(BaseModel):
    tool_name: str
    response: dict[str, Any] | str


class ScoringRule(BaseModel):
    pass_description: str = ""
    partial_description: str = ""
    fail_description: str = ""


class Check(BaseModel):
    """A single check applied to model output."""
    kind: str  # exact, contains_all, contains_any, forbids_any, max_words, min_words, requires_question, mcq_letter, tool_name, keyword_groups, field_match
    value: Any = None  # the argument to the check


class Scenario(BaseModel):
    """One evaluation scenario — the universal unit of the harness."""
    id: str
    dimension: Dimension
    category: str
    difficulty: Difficulty = Difficulty.basic
    description: str = ""
    system_prompt: str = ""
    turns: list[dict[str, str]]  # [{"role": "user", "content": "..."}]
    image_path: str = ""  # relative to eval/ dir — sent as base64 to VLM
    tools: list[dict[str, Any]] = Field(default_factory=list)  # tool schemas
    expected_tool_calls: list[ToolExpectation] = Field(default_factory=list)
    no_tool_call_expected: bool = False
    mock_tool_responses: list[MockToolResponse] = Field(default_factory=list)
    checks: list[Check] = Field(default_factory=list)
    hardware_tier: HardwareTier = HardwareTier.any
    max_turns: int = 1
    temperature: float = 0.0
    tags: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

class ScenarioResult(BaseModel):
    """Result of running one scenario."""
    scenario_id: str
    dimension: Dimension
    category: str
    verdict: Verdict
    score: float  # 0.0 = fail, 0.5 = partial, 1.0 = pass
    model_output: str = ""
    tool_calls_made: list[dict[str, Any]] = Field(default_factory=list)
    checks_passed: list[str] = Field(default_factory=list)
    checks_failed: list[str] = Field(default_factory=list)
    latency_ms: float = 0.0
    tokens_generated: int = 0
    first_token_ms: float = 0.0
    error_message: str = ""


class DimensionSummary(BaseModel):
    """Aggregated results for one dimension."""
    dimension: Dimension
    total: int = 0
    passed: int = 0
    partial: int = 0
    failed: int = 0
    errors: int = 0
    skipped: int = 0
    score: float = 0.0  # 0-100
    avg_latency_ms: float = 0.0
    categories: dict[str, float] = Field(default_factory=dict)  # category -> score


class RunResult(BaseModel):
    """Complete result of one evaluation run."""
    run_id: str
    model_id: str
    model_name: str = ""
    started_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    finished_at: datetime | None = None
    hardware: dict[str, Any] = Field(default_factory=dict)
    dimensions: dict[str, DimensionSummary] = Field(default_factory=dict)
    results: list[ScenarioResult] = Field(default_factory=list)
    overall_score: float = 0.0  # 0-100 weighted average


class RunEvent(BaseModel):
    """SSE event streamed to the dashboard during a run."""
    kind: str  # scenario_start, scenario_result, dimension_complete, run_complete, error, progress
    run_id: str
    data: dict[str, Any] = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# Hardware profile
# ---------------------------------------------------------------------------

class HardwareProfile(BaseModel):
    ram_gb: int = 0
    gpu_cores: int = 0
    chip: str = ""
    os_version: str = ""
    thermal_state: str = "nominal"
    recommended_models: list[str] = Field(default_factory=list)
    recommended_tier: HardwareTier = HardwareTier.any

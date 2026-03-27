"""Orchestrator — runs all dimensions, streams events, persists results."""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, AsyncIterator

from schemas import (
    Dimension,
    DimensionSummary,
    RunEvent,
    RunResult,
    Scenario,
    ScenarioResult,
    Verdict,
)
from runners.base import BaseRunner, ModelClient
from runners.tool_calling import ToolCallingRunner
from runners.intelligence import IntelligenceRunner
from runners.freeform import FreeformRunner
from runners.throughput import ThroughputRunner
from runners.vision import VisionRunner
from runners.personality import PersonalityRunner
from runners.safety import SafetyRunner
import db
import hardware as hw

SCENARIO_DIR = Path(__file__).parent / "scenarios"

RUNNERS: dict[Dimension, type[BaseRunner]] = {
    Dimension.tool_calling: ToolCallingRunner,
    Dimension.intelligence: IntelligenceRunner,
    Dimension.freeform: FreeformRunner,
    Dimension.throughput: ThroughputRunner,
    Dimension.vision: VisionRunner,
    Dimension.personality: PersonalityRunner,
    Dimension.safety: SafetyRunner,
}


def load_scenarios(dimensions: list[Dimension] | None = None) -> list[Scenario]:
    """Load all scenarios from the scenarios/ directory."""
    scenarios: list[Scenario] = []
    for json_file in sorted(SCENARIO_DIR.rglob("*.json")):
        try:
            raw = json.loads(json_file.read_text())
        except (json.JSONDecodeError, OSError):
            continue

        # Each file can be a single scenario or a list
        items = raw if isinstance(raw, list) else [raw]
        for item in items:
            try:
                s = Scenario(**item)
                if dimensions is None or s.dimension in dimensions:
                    scenarios.append(s)
            except Exception:
                continue  # skip malformed scenarios
    return scenarios


async def run_evaluation(
    model_url: str,
    model_id: str,
    model_name: str = "",
    dimensions: list[Dimension] | None = None,
    api_key: str = "",
) -> AsyncIterator[tuple[RunEvent, ScenarioResult | None]]:
    """Run a complete evaluation, yielding SSE events."""
    run_id = f"run_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"

    # Detect hardware
    profile = hw.detect()

    # Load scenarios
    scenarios = load_scenarios(dimensions)
    if not scenarios:
        yield RunEvent(
            kind="error",
            run_id=run_id,
            data={"message": "No scenarios found. Add JSON files to eval/scenarios/"},
        ), None
        return

    # Create model client
    client = ModelClient(base_url=model_url, model=model_id, api_key=api_key)

    # After creating the ModelClient, query the server for actual model info
    try:
        import httpx
        health_resp = httpx.get(f"{model_url}/health", timeout=3)
        health = health_resp.json()
        actual_model_id = health.get("model_id", model_id)
        actual_model_name = health.get("model", model_name or model_id)
    except Exception:
        actual_model_id = model_id
        actual_model_name = model_name or model_id

    # Initialize run
    run = RunResult(
        run_id=run_id,
        model_id=actual_model_id,
        model_name=actual_model_name,
        hardware=profile.model_dump(),
    )

    database = await db.get_db()
    await db.save_run(database, run)

    # Emit run start
    yield RunEvent(
        kind="run_start",
        run_id=run_id,
        data={
            "model_id": actual_model_id,
            "model_name": actual_model_name,
            "total_scenarios": len(scenarios),
            "dimensions": list({s.dimension.value for s in scenarios}),
            "hardware": profile.model_dump(),
        },
    ), None

    # Group scenarios by dimension
    dim_scenarios: dict[Dimension, list[Scenario]] = {}
    for s in scenarios:
        dim_scenarios.setdefault(s.dimension, []).append(s)

    all_results: list[ScenarioResult] = []
    dim_summaries: dict[str, DimensionSummary] = {}

    for dim, dim_scens in dim_scenarios.items():
        runner_cls = RUNNERS.get(dim)
        if not runner_cls:
            continue

        runner = runner_cls(client=client, scenarios=dim_scens)
        dim_results: list[ScenarioResult] = []

        async for event, result in runner.run(run_id):
            if result:
                dim_results.append(result)
                all_results.append(result)
                await db.save_scenario_result(database, run_id, result)
            yield event, result

        # Compute dimension summary
        summary = _compute_dim_summary(dim, dim_results)
        dim_summaries[dim.value] = summary
        await db.save_dimension_summary(database, run_id, summary)

    # Compute overall score
    if dim_summaries:
        overall = sum(s.score for s in dim_summaries.values()) / len(dim_summaries)
    else:
        overall = 0.0

    # Finalize run
    run.finished_at = datetime.now(timezone.utc)
    run.overall_score = overall
    run.dimensions = dim_summaries
    run.results = all_results
    await db.save_run(database, run)
    await database.close()

    await client.close()

    yield RunEvent(
        kind="run_complete",
        run_id=run_id,
        data={
            "overall_score": round(overall, 1),
            "dimensions": {k: round(v.score, 1) for k, v in dim_summaries.items()},
            "total": len(all_results),
            "passed": sum(1 for r in all_results if r.verdict == Verdict.passed),
            "failed": sum(1 for r in all_results if r.verdict == Verdict.fail),
        },
    ), None


def _compute_dim_summary(dim: Dimension, results: list[ScenarioResult]) -> DimensionSummary:
    total = len(results)
    if total == 0:
        return DimensionSummary(dimension=dim)

    passed = sum(1 for r in results if r.verdict == Verdict.passed)
    partial = sum(1 for r in results if r.verdict == Verdict.partial)
    failed = sum(1 for r in results if r.verdict == Verdict.fail)
    errors = sum(1 for r in results if r.verdict == Verdict.error)
    skipped = sum(1 for r in results if r.verdict == Verdict.skipped)

    score = ((passed * 2 + partial) / (total * 2)) * 100 if total > 0 else 0
    avg_lat = sum(r.latency_ms for r in results) / total if total > 0 else 0

    # Per-category scores
    categories: dict[str, float] = {}
    cat_groups: dict[str, list[ScenarioResult]] = {}
    for r in results:
        cat_groups.setdefault(r.category, []).append(r)
    for cat, cat_results in cat_groups.items():
        cat_total = len(cat_results)
        cat_passed = sum(1 for r in cat_results if r.verdict == Verdict.passed)
        cat_partial = sum(1 for r in cat_results if r.verdict == Verdict.partial)
        categories[cat] = ((cat_passed * 2 + cat_partial) / (cat_total * 2)) * 100 if cat_total > 0 else 0

    return DimensionSummary(
        dimension=dim,
        total=total,
        passed=passed,
        partial=partial,
        failed=failed,
        errors=errors,
        skipped=skipped,
        score=round(score, 1),
        avg_latency_ms=round(avg_lat, 1),
        categories=categories,
    )

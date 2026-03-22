# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Update STATE.json with evaluation results from timing + accuracy evaluators."""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


# Target thresholds for scoring (from PROGRAM.md)
DIMENSION_TARGETS = {
    "voice_pipeline": {
        "avg_latency_ms": {"max": 6000, "warn": 4000},
        "pass_rate": {"min": 0.90},
        "composite_score": {"min": 85},
    },
    "tool_execution": {
        "avg_latency_ms": {"max": 15000, "warn": 10000},
        "pass_rate": {"min": 0.90},
        "composite_score": {"min": 85},
    },
    "barge_in": {
        "avg_latency_ms": {"max": 3000, "warn": 2000},
        "pass_rate": {"min": 0.85},
        "composite_score": {"min": 85},
    },
    "memory": {
        "avg_latency_ms": {"max": 15000, "warn": 10000},
        "pass_rate": {"min": 0.90},
        "composite_score": {"min": 85},
    },
    "conversation": {
        "avg_latency_ms": {"max": 12000, "warn": 8000},
        "pass_rate": {"min": 0.85},
        "composite_score": {"min": 85},
    },
    "advanced_pipeline": {
        "avg_latency_ms": {"max": 10000, "warn": 6000},
        "pass_rate": {"min": 0.85},
        "composite_score": {"min": 85},
    },
}


def score_metric(value: float, target: dict) -> float:
    """Score a single metric 0-100 based on target thresholds."""
    if "min" in target:
        if value >= target["min"]:
            return 100.0
        return max(0, (value / target["min"]) * 100)
    elif "max" in target:
        if value <= target["max"]:
            return 100.0
        # Score degrades linearly past max
        overshoot = value / target["max"]
        return max(0, 100 - (overshoot - 1) * 50)
    return 50.0


def compute_dimension_score(timing: dict, accuracy: dict) -> tuple[float, dict]:
    """Compute overall dimension score (0-100) and sub-metrics."""
    submetrics = {}

    # Timing sub-metrics
    if timing.get("count", 0) > 0:
        submetrics["avg_latency_ms"] = timing.get("avg_latency_ms", 0)
        submetrics["max_latency_ms"] = timing.get("max_latency_ms", 0)
        if "avg_llm_tps" in timing:
            submetrics["avg_llm_tps"] = timing["avg_llm_tps"]

    # Accuracy sub-metrics
    if accuracy:
        submetrics["pass_rate"] = accuracy.get("pass_rate", 0)
        submetrics["composite_score"] = accuracy.get("composite_score", 0)
        submetrics["no_think_leak_rate"] = accuracy.get("no_think_leak_rate", 1.0)
        submetrics["no_hallucination_rate"] = accuracy.get("no_hallucination_rate", 1.0)
        submetrics["tool_accuracy_rate"] = accuracy.get("tool_accuracy_rate", 1.0)

    # Compute overall score (weighted average of sub-scores)
    score_components = []

    if "composite_score" in submetrics:
        score_components.append(submetrics["composite_score"] * 0.6)

    if "avg_latency_ms" in submetrics:
        # Score latency on a 0-100 scale. Targets are realistic for local
        # Apple Silicon LLM inference (2B-35B models, no cloud API).
        # Greetings/simple: ~5-10s, factual: ~10-20s, complex: ~20-40s.
        latency = submetrics["avg_latency_ms"]
        if latency <= 8000:
            latency_score = 100
        elif latency <= 15000:
            latency_score = 100 - ((latency - 8000) / 7000) * 15
        elif latency <= 30000:
            latency_score = 85 - ((latency - 15000) / 15000) * 25
        elif latency <= 60000:
            latency_score = 60 - ((latency - 30000) / 30000) * 30
        else:
            latency_score = max(0, 30 - ((latency - 60000) / 60000) * 30)
        score_components.append(latency_score * 0.4)

    overall = sum(score_components) if score_components else 0
    return round(overall, 1), submetrics


def main():
    parser = argparse.ArgumentParser(description="Update FaeAutoResearch STATE.json")
    parser.add_argument("--timing", help="Path to timing evaluator results")
    parser.add_argument("--accuracy", help="Path to accuracy evaluator results")
    parser.add_argument("--state", required=True, help="Path to STATE.json")
    args = parser.parse_args()

    # Load current state
    state_path = Path(args.state)
    with open(state_path) as f:
        state = json.load(f)

    # Load evaluator results
    timing_data = {}
    if args.timing:
        with open(args.timing) as f:
            timing_data = json.load(f)

    accuracy_data = {}
    if args.accuracy:
        with open(args.accuracy) as f:
            accuracy_data = json.load(f)

    # Update each dimension
    timing_dims = timing_data.get("per_dimension", {})
    accuracy_dims = accuracy_data.get("per_dimension", {})

    all_dimensions = set(list(timing_dims.keys()) + list(accuracy_dims.keys()))

    for dim in all_dimensions:
        timing = timing_dims.get(dim, {})
        accuracy = accuracy_dims.get(dim, {})

        score, submetrics = compute_dimension_score(timing, accuracy)

        state["dimensions"][dim] = {
            "score": score,
            "submetrics": submetrics,
        }

    # Update metadata
    now = datetime.now(timezone.utc).isoformat()
    state["lastRun"] = now
    state["runCount"] = state.get("runCount", 0) + 1

    # Append to history
    history_entry = {
        "timestamp": now,
        "runCount": state["runCount"],
        "focus": state.get("currentFocus", "unknown"),
        "scores": {
            dim: state["dimensions"].get(dim, {}).get("score")
            for dim in state["dimensions"]
        },
    }
    state.setdefault("history", []).append(history_entry)

    # Rotate focus to worst dimension
    scored_dims = {
        dim: data.get("score", 0)
        for dim, data in state["dimensions"].items()
        if data.get("score") is not None
    }

    if scored_dims:
        worst_dim = min(scored_dims, key=scored_dims.get)
        worst_score = scored_dims[worst_dim]
        if worst_score < 85:
            state["currentFocus"] = worst_dim
        else:
            # All above 85 — pick the lowest for continued improvement
            state["currentFocus"] = worst_dim

    # Write updated state
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)

    # Print summary
    print("\n=== State Update Summary ===")
    print(f"Run #{state['runCount']} at {now}")
    print(f"Current focus: {state['currentFocus']}")
    print()
    for dim in sorted(state["dimensions"]):
        data = state["dimensions"][dim]
        score = data.get("score")
        if score is not None:
            marker = "  " if score >= 85 else "!!"
            print(f"  {marker} {dim}: {score:.0f}/100")
        else:
            print(f"  -- {dim}: not yet evaluated")

    if scored_dims:
        worst = min(scored_dims, key=scored_dims.get)
        print(f"\nWeakest dimension: {worst} ({scored_dims[worst]:.0f}/100)")


if __name__ == "__main__":
    main()

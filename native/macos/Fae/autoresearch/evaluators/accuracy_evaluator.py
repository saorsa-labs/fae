# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Evaluate accuracy metrics from inject_runner results."""

import argparse
import json
import re
from pathlib import Path


def evaluate_result(result: dict) -> dict:
    """Evaluate accuracy for a single scenario result."""
    accuracy = {
        "scenario_id": result["id"],
        "dimension": result["dimension"],
        "passed": result.get("passed", False),
    }

    checks = result.get("checks", {})
    response = result.get("response_text", "")
    tools = result.get("tools_called", [])
    errors = result.get("errors", [])

    # Response content check
    if "response_contains" in checks:
        accuracy["response_contains"] = checks["response_contains"]

    # Tool selection accuracy
    for key, val in checks.items():
        if "tool_called" in key:
            accuracy["tool_selection_correct"] = val

    # Think tag leak detection
    think_leaked = bool(re.search(r"<think>|</think>|<\|think\|>", response))
    accuracy["think_tag_leaked"] = think_leaked

    # Tool hallucination detection
    # If response mentions using a tool that doesn't exist
    known_tools = {
        "read", "write", "edit", "bash", "self_config", "channel_setup",
        "window_control", "session_search", "web_search", "fetch_url",
        "activate_skill", "run_skill", "manage_skill", "delegate_agent",
        "agent_session", "input_request", "calendar", "reminders", "contacts",
        "mail", "notes", "scheduler_list", "scheduler_create", "scheduler_update",
        "scheduler_delete", "scheduler_trigger", "roleplay", "screenshot",
        "camera", "read_screen", "click", "type_text", "scroll", "find_element",
        "till_done", "voice_identity",
    }
    hallucinated_tools = [t for t in tools if t not in known_tools]
    accuracy["hallucinated_tools"] = hallucinated_tools
    accuracy["has_hallucinated_tool"] = len(hallucinated_tools) > 0

    # Approval flow checks
    if "approval_triggered" in checks:
        accuracy["approval_triggered"] = checks["approval_triggered"]

    # Latency check
    if "max_latency" in checks:
        accuracy["within_latency_limit"] = checks["max_latency"]

    # Error check
    accuracy["has_errors"] = len(errors) > 0
    if errors:
        accuracy["errors"] = errors

    # Response quality heuristics
    accuracy["response_empty"] = len(response.strip()) == 0
    accuracy["response_length"] = len(response)
    accuracy["response_word_count"] = len(response.split())

    return accuracy


def compute_dimension_scores(results: list[dict]) -> dict:
    """Compute accuracy scores per dimension."""
    dimensions: dict[str, list] = {}
    for r in results:
        dim = r.get("dimension", "unknown")
        dimensions.setdefault(dim, []).append(r)

    scores = {}
    for dim, dim_results in dimensions.items():
        total = len(dim_results)
        passed = sum(1 for r in dim_results if r.get("passed", False))
        no_think_leak = sum(1 for r in dim_results if not r.get("think_tag_leaked", False))
        no_hallucination = sum(1 for r in dim_results if not r.get("has_hallucinated_tool", False))
        within_latency = sum(1 for r in dim_results if r.get("within_latency_limit", True))
        response_ok = sum(1 for r in dim_results if not r.get("response_empty", True))
        tool_correct = sum(
            1 for r in dim_results
            if r.get("tool_selection_correct") is None or r.get("tool_selection_correct", False)
        )

        scores[dim] = {
            "total": total,
            "passed": passed,
            "pass_rate": passed / max(total, 1),
            "no_think_leak_rate": no_think_leak / max(total, 1),
            "no_hallucination_rate": no_hallucination / max(total, 1),
            "within_latency_rate": within_latency / max(total, 1),
            "response_ok_rate": response_ok / max(total, 1),
            "tool_accuracy_rate": tool_correct / max(total, 1),
            # Composite score (0-100)
            "composite_score": round(
                (
                    (passed / max(total, 1)) * 40 +
                    (no_think_leak / max(total, 1)) * 15 +
                    (no_hallucination / max(total, 1)) * 15 +
                    (within_latency / max(total, 1)) * 15 +
                    (tool_correct / max(total, 1)) * 15
                ) * 100 / 100,
                1,
            ),
        }

    return scores


def main():
    parser = argparse.ArgumentParser(description="FaeAutoResearch accuracy evaluator")
    parser.add_argument("--results", required=True, help="Path to inject_runner results JSON")
    parser.add_argument("--output", help="Path to output accuracy results JSON")
    args = parser.parse_args()

    with open(args.results) as f:
        data = json.load(f)

    results = data.get("results", [])
    accuracy_results = [evaluate_result(r) for r in results]
    dimension_scores = compute_dimension_scores(accuracy_results)

    output = {
        "source": args.results,
        "total_scenarios": len(accuracy_results),
        "overall_pass_rate": sum(1 for r in accuracy_results if r.get("passed")) / max(len(accuracy_results), 1),
        "per_scenario": accuracy_results,
        "per_dimension": dimension_scores,
    }

    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w") as f:
            json.dump(output, f, indent=2)
        print(f"Accuracy results: {output_path}")
    else:
        print(json.dumps(output, indent=2))

    # Print summary
    print("\n=== Accuracy Summary ===")
    for dim, scores in sorted(dimension_scores.items()):
        print(
            f"  {dim}: {scores['passed']}/{scores['total']} passed "
            f"({scores['pass_rate']*100:.0f}%) "
            f"composite={scores['composite_score']:.0f}/100"
        )
        if scores["no_think_leak_rate"] < 1.0:
            print(f"    ⚠ Think tag leaks: {(1-scores['no_think_leak_rate'])*100:.0f}%")
        if scores["no_hallucination_rate"] < 1.0:
            print(f"    ⚠ Tool hallucinations: {(1-scores['no_hallucination_rate'])*100:.0f}%")


if __name__ == "__main__":
    main()

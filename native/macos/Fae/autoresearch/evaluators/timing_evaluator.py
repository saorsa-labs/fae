# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Extract timing metrics from inject_runner results."""

import argparse
import json
import sys
from pathlib import Path


def extract_timing_from_result(result: dict) -> dict:
    """Extract timing metrics from a single scenario result."""
    metrics = {
        "scenario_id": result["id"],
        "dimension": result["dimension"],
        "total_latency_ms": result.get("latency_ms", 0),
    }

    events = result.get("events", [])

    # Parse event timestamps and kinds
    stt_events = [e for e in events if "STT" in e.get("kind", "") or "STT" in e.get("text", "")]
    llm_events = [e for e in events if "LLM" in e.get("kind", "") or "LLM" in e.get("text", "")]
    tts_events = [e for e in events if "TTS" in e.get("text", "") or "Kokoro" in e.get("text", "")]
    tool_events = [e for e in events if "Tool" in e.get("kind", "") or "Tool→" in e.get("text", "")]
    memory_events = [e for e in events if "Memory" in e.get("kind", "") or "memory" in e.get("text", "").lower()]
    pipeline_events = [e for e in events if "Pipeline" in e.get("kind", "") or "pipeline" in e.get("text", "").lower()]

    # Extract LLM throughput from events
    for ev in llm_events:
        text = ev.get("text", "")
        if "t/s" in text:
            try:
                # Parse "LLM done: 45 tokens in 2.3s (19.6 t/s)"
                parts = text.split("(")
                if len(parts) >= 2:
                    tps_str = parts[-1].split("t/s")[0].strip()
                    metrics["llm_tokens_per_second"] = float(tps_str)
            except (ValueError, IndexError):
                pass
        if "tokens in" in text:
            try:
                parts = text.split("tokens in")
                token_part = parts[0].split()[-1]
                time_part = parts[1].split("s")[0].strip()
                metrics["llm_token_count"] = int(token_part)
                metrics["llm_generation_time_s"] = float(time_part)
            except (ValueError, IndexError):
                pass

    # Count events by type
    metrics["stt_event_count"] = len(stt_events)
    metrics["llm_event_count"] = len(llm_events)
    metrics["tts_event_count"] = len(tts_events)
    metrics["tool_event_count"] = len(tool_events)
    metrics["memory_event_count"] = len(memory_events)
    metrics["total_event_count"] = len(events)

    # Barge-in specific metrics
    interrupt_events = [e for e in events if "interrupt" in e.get("text", "").lower() or "barge" in e.get("text", "").lower()]
    if interrupt_events:
        metrics["interrupt_event_count"] = len(interrupt_events)
        # Extract interrupt reason if available
        for ev in interrupt_events:
            text = ev.get("text", "")
            if "reason=" in text or "interrupt" in text.lower():
                metrics["interrupt_details"] = text

    # Echo suppression metrics
    echo_events = [e for e in events if "echo" in e.get("text", "").lower()]
    metrics["echo_event_count"] = len(echo_events)

    # Speculative prefill
    prefill_events = [e for e in events if "prefill" in e.get("text", "").lower()]
    metrics["prefill_event_count"] = len(prefill_events)
    metrics["prefill_completed"] = any("complete" in e.get("text", "").lower() for e in prefill_events)

    # Turn detector
    eou_events = [e for e in events if "EOU" in e.get("text", "") or "turn detector" in e.get("text", "").lower()]
    metrics["eou_event_count"] = len(eou_events)

    # Generation takeover
    takeover_events = [e for e in events if "takeover" in e.get("text", "").lower()]
    metrics["takeover_event_count"] = len(takeover_events)

    return metrics


def aggregate_dimension(results: list[dict], dimension: str) -> dict:
    """Aggregate timing metrics for a dimension."""
    dim_results = [r for r in results if r.get("dimension") == dimension]
    if not dim_results:
        return {"dimension": dimension, "count": 0}

    latencies = [r.get("total_latency_ms", 0) for r in dim_results]
    tps_values = [r.get("llm_tokens_per_second", 0) for r in dim_results if r.get("llm_tokens_per_second")]

    agg = {
        "dimension": dimension,
        "count": len(dim_results),
        "avg_latency_ms": sum(latencies) / len(latencies) if latencies else 0,
        "max_latency_ms": max(latencies) if latencies else 0,
        "min_latency_ms": min(latencies) if latencies else 0,
        "p95_latency_ms": sorted(latencies)[int(len(latencies) * 0.95)] if latencies else 0,
    }

    if tps_values:
        agg["avg_llm_tps"] = sum(tps_values) / len(tps_values)
        agg["min_llm_tps"] = min(tps_values)

    return agg


def main():
    parser = argparse.ArgumentParser(description="FaeAutoResearch timing evaluator")
    parser.add_argument("--results", required=True, help="Path to inject_runner results JSON")
    parser.add_argument("--output", help="Path to output timing results JSON")
    args = parser.parse_args()

    with open(args.results) as f:
        data = json.load(f)

    results = data.get("results", [])
    timing_results = [extract_timing_from_result(r) for r in results]

    # Group by dimension
    dimensions = set(r.get("dimension", "unknown") for r in timing_results)
    aggregated = {dim: aggregate_dimension(timing_results, dim) for dim in dimensions}

    output = {
        "source": args.results,
        "total_scenarios": len(timing_results),
        "per_scenario": timing_results,
        "per_dimension": aggregated,
    }

    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w") as f:
            json.dump(output, f, indent=2)
        print(f"Timing results: {output_path}")
    else:
        print(json.dumps(output, indent=2))

    # Print summary
    print("\n=== Timing Summary ===")
    for dim, agg in sorted(aggregated.items()):
        if agg["count"] == 0:
            continue
        print(f"  {dim}: avg={agg['avg_latency_ms']:.0f}ms max={agg['max_latency_ms']:.0f}ms (n={agg['count']})")
        if "avg_llm_tps" in agg:
            print(f"    LLM: avg={agg['avg_llm_tps']:.1f} t/s min={agg['min_llm_tps']:.1f} t/s")


if __name__ == "__main__":
    main()

"""CLI entry point for the Fae eval harness."""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import click
from rich.console import Console
from rich.table import Table

console = Console()

EVAL_SERVER_URL = "http://127.0.0.1:8234"


async def _check_cache(model_id: str, dimensions: tuple[str, ...]) -> bool:
    """Check if we have cached results for this model. Returns True if cache hit shown."""
    import db as evaldb
    import json

    database = await evaldb.get_db()
    cached_run = await evaldb.get_latest_complete_run(database, model_id)
    if not cached_run:
        await database.close()
        return False

    summaries = await evaldb.get_dimension_summaries(database, cached_run["run_id"])
    results = await evaldb.get_run_results(database, cached_run["run_id"])
    await database.close()

    # If dimensions were specified, check if they're all covered
    if dimensions:
        cached_dims = {s["dimension"] for s in summaries}
        if not all(d in cached_dims for d in dimensions):
            return False

    console.print(f"\n[bold]Cached results for {model_id}[/]")
    console.print(f"[dim]Run: {cached_run['run_id']}  ({cached_run['started_at'][:19]})[/]")
    console.print(f"[dim]Re-run with: just run --force[/]\n")

    passed = sum(1 for r in results if r["verdict"] == "pass")
    partial_count = sum(1 for r in results if r["verdict"] == "partial")
    failed = sum(1 for r in results if r["verdict"] == "fail")
    error_count = sum(1 for r in results if r["verdict"] == "error")

    for s in summaries:
        score = s["score"]
        color = "green" if score >= 80 else "yellow" if score >= 60 else "red"
        console.print(f"  [{color}]{s['dimension']:>15}[/]  {score:.1f}/100  ({s['passed']}/{s['total']} passed)")

    overall = cached_run["overall_score"]
    color = "green" if overall >= 80 else "yellow" if overall >= 60 else "red"
    console.print(f"\n[bold {color}]Overall: {overall:.1f}/100[/]")
    console.print(f"  Passed: {passed}  Partial: {partial_count}  Failed: {failed}  Errors: {error_count}")
    return True


@click.group()
def main():
    """Fae Eval Harness — unified evaluation, benchmarking, and fine-tuning."""
    pass


@main.command()
@click.option("--model", default="auto", help="Model ID (auto selects by RAM)")
@click.option("--model-url", default=EVAL_SERVER_URL, help="FaeEvalServer endpoint")
@click.option("--dimension", "-d", multiple=True, help="Dimension(s) to run")
@click.option("--api-key", default="", help="API key (if endpoint requires it)")
@click.option("--force", is_flag=True, help="Re-run even if cached results exist")
def run(model: str, model_url: str, dimension: tuple[str, ...], api_key: str, force: bool):
    """Run an evaluation against FaeEvalServer."""
    from schemas import Dimension
    import orchestrator
    import db as evaldb
    import json

    # Pre-flight: check server is reachable
    import httpx
    try:
        resp = httpx.get(f"{model_url}/health", timeout=3)
        info = resp.json()
        server_model_id = info.get("model_id", model)
        console.print(f"[dim]Server: {info.get('model', '?')} ({server_model_id})[/]")
    except Exception:
        console.print(f"\n[bold red]Cannot reach eval server at {model_url}[/]")
        console.print(f"[dim]Start it first:[/]  just serve {model}")
        console.print(f"[dim]Or with HF ID:[/]   just serve mlx-community/Qwen3.5-27B-4bit\n")
        sys.exit(1)

    # Check for cached results unless --force
    if not force:
        cached = asyncio.run(_check_cache(server_model_id, dimension))
        if cached:
            return

    dims = [Dimension(d) for d in dimension] if dimension else None

    async def _run():
        passed = failed = partial = errors = 0
        async for event, result in orchestrator.run_evaluation(
            model_url=model_url,
            model_id=model,
            dimensions=dims,
            api_key=api_key,
        ):
            if event.kind == "run_start":
                console.print(f"\n[bold]Starting evaluation[/] — {event.data['total_scenarios']} scenarios")
                console.print(f"[dim]Dimensions: {', '.join(event.data['dimensions'])}[/]\n")
            elif event.kind == "scenario_result":
                v = event.data["verdict"]
                sid = event.data["scenario_id"]
                lat = event.data["latency_ms"]
                if v == "error":
                    err = event.data.get("error", "")
                    console.print(f"  [red]  ERROR[/] {sid} — {err[:80]}")
                    errors += 1
                else:
                    color = {"pass": "green", "partial": "yellow", "fail": "red"}.get(v, "red")
                    console.print(f"  [{color}]{v.upper():>7}[/] {sid} ({lat:.0f}ms)")
                    if v == "pass":
                        passed += 1
                    elif v == "partial":
                        partial += 1
                    else:
                        failed += 1
            elif event.kind == "dimension_complete":
                d = event.data
                score = d["score"]
                color = "green" if score >= 80 else "yellow" if score >= 60 else "red"
                console.print(f"\n  [{color}]{d['dimension']}[/]: {score:.1f}/100 ({d['passed']}/{d['total']} passed)")
            elif event.kind == "run_complete":
                d = event.data
                score = d["overall_score"]
                color = "green" if score >= 80 else "yellow" if score >= 60 else "red"
                console.print(f"\n[bold {color}]Overall: {score:.1f}/100[/]")
                console.print(f"  Passed: {passed}  Partial: {partial}  Failed: {failed}  Errors: {errors}")
            elif event.kind == "error":
                console.print(f"[red]Error: {event.data.get('message', '?')}[/]")

    asyncio.run(_run())


@main.command()
def scenarios():
    """List all available scenarios."""
    import orchestrator

    all_scenarios = orchestrator.load_scenarios()
    table = Table(title=f"Scenarios ({len(all_scenarios)} total)")
    table.add_column("Dimension", style="cyan")
    table.add_column("Category")
    table.add_column("Count", justify="right")

    counts: dict[str, dict[str, int]] = {}
    for s in all_scenarios:
        counts.setdefault(s.dimension.value, {})
        counts[s.dimension.value][s.category] = counts[s.dimension.value].get(s.category, 0) + 1

    for dim in sorted(counts):
        for cat in sorted(counts[dim]):
            table.add_row(dim, cat, str(counts[dim][cat]))

    console.print(table)


@main.command()
@click.option("--model", default="all", help="Filter by model ID")
def results(model: str):
    """Show recent results."""
    import db

    async def _show():
        database = await db.get_db()
        runs = await db.get_runs(database, model_id=model if model != "all" else None)
        await database.close()

        if not runs:
            console.print("[dim]No results found.[/]")
            return

        table = Table(title="Recent Runs")
        table.add_column("Run ID")
        table.add_column("Model")
        table.add_column("Score", justify="right")
        table.add_column("Status")
        table.add_column("Date")

        for r in runs:
            score = r["overall_score"]
            color = "green" if score >= 80 else "yellow" if score >= 60 else "red"
            table.add_row(
                r["run_id"][:24],
                r["model_name"] or r["model_id"],
                f"[{color}]{score:.1f}[/]",
                r["status"],
                r["started_at"][:19],
            )

        console.print(table)

    asyncio.run(_show())


@main.command()
@click.argument("model1")
@click.argument("model2")
def compare(model1: str, model2: str):
    """Compare two models by their latest runs."""
    console.print(f"[dim]Comparing {model1} vs {model2}...[/]")
    console.print("[yellow]Use the web dashboard for visual comparison: just dashboard[/]")


@main.command()
def hardware():
    """Detect hardware and recommend models."""
    import hardware as hw

    profile = hw.detect()
    table = Table(title="Hardware Profile")
    table.add_column("Property", style="cyan")
    table.add_column("Value")

    table.add_row("Chip", profile.chip)
    table.add_row("RAM", f"{profile.ram_gb} GB")
    table.add_row("GPU Cores", str(profile.gpu_cores))
    table.add_row("OS", profile.os_version)
    table.add_row("Thermal", profile.thermal_state)
    table.add_row("Tier", profile.recommended_tier.value)

    console.print(table)

    if profile.recommended_models:
        console.print("\n[bold]Recommended models:[/]")
        for m in profile.recommended_models:
            short = m.split("/")[-1]
            console.print(f"  just serve {short}")


@main.group()
def train():
    """Training pipeline commands."""
    pass


@train.command("export")
def train_export():
    """Export training data from Fae memory database."""
    console.print("[yellow]Training export not yet integrated. Use training-data-bridge skill.[/]")


@train.command("run")
@click.option("--preset", default="light", type=click.Choice(["smoke", "light", "standard", "deep"]))
def train_run(preset: str):
    """Run LoRA fine-tuning."""
    console.print(f"[yellow]Training with preset '{preset}' not yet integrated.[/]")


@train.command("eval")
@click.option("--checkpoint", default="latest")
def train_eval(checkpoint: str):
    """Evaluate a trained checkpoint against baseline."""
    console.print("[yellow]Training eval not yet integrated.[/]")


if __name__ == "__main__":
    main()

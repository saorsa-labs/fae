"""FastAPI server with SSE streaming and htmx dashboard."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sse_starlette.sse import EventSourceResponse

import db
import hardware as hw
import orchestrator
from schemas import Dimension

app = FastAPI(title="Fae Eval Harness", version="0.1.0")

BASE = Path(__file__).parent
templates = Jinja2Templates(directory=str(BASE / "templates"))

app.mount("/static", StaticFiles(directory=str(BASE / "static")), name="static")

# In-memory state for active runs
_active_runs: dict[str, asyncio.Queue] = {}


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    database = await db.get_db()
    runs = await db.get_runs(database)
    profile = hw.detect()
    scenarios = orchestrator.load_scenarios()
    await database.close()
    return templates.TemplateResponse(request, "dashboard.html", {
        "runs": runs,
        "hardware": profile.model_dump(),
        "scenario_count": len(scenarios),
        "dimensions": [d.value for d in Dimension],
    })


@app.get("/run/{run_id}", response_class=HTMLResponse)
async def run_detail(request: Request, run_id: str):
    database = await db.get_db()
    run = await db.get_run(database, run_id)
    results = await db.get_run_results(database, run_id)
    summaries = await db.get_dimension_summaries(database, run_id)
    await database.close()
    for r in results:
        r["checks_passed_count"] = len(json.loads(r.get("checks_passed", "[]")))
        r["checks_failed_count"] = len(json.loads(r.get("checks_failed", "[]")))
    return templates.TemplateResponse(request, "run_detail.html", {
        "run": run,
        "results": results,
        "summaries": summaries,
    })


@app.get("/compare", response_class=HTMLResponse)
async def compare_page(request: Request):
    database = await db.get_db()
    runs = await db.get_runs(database, limit=20)
    await database.close()
    return templates.TemplateResponse(request, "compare.html", {
        "runs": runs,
    })


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

@app.get("/api/hardware")
async def api_hardware():
    return hw.detect().model_dump()


@app.get("/api/scenarios")
async def api_scenarios(dimension: str | None = None):
    dims = [Dimension(dimension)] if dimension else None
    scenarios = orchestrator.load_scenarios(dims)
    return {
        "total": len(scenarios),
        "by_dimension": _group_count(scenarios),
        "scenarios": [s.model_dump() for s in scenarios],
    }


@app.get("/api/runs")
async def api_runs(model_id: str | None = None, limit: int = 50):
    database = await db.get_db()
    runs = await db.get_runs(database, model_id=model_id, limit=limit)
    await database.close()
    return {"runs": runs}


@app.get("/api/runs/{run_id}")
async def api_run_detail(run_id: str):
    database = await db.get_db()
    run = await db.get_run(database, run_id)
    results = await db.get_run_results(database, run_id)
    summaries = await db.get_dimension_summaries(database, run_id)
    await database.close()
    return {"run": run, "results": results, "summaries": summaries}


@app.get("/api/longitudinal/{model_id}")
async def api_longitudinal(model_id: str, limit: int = 30):
    database = await db.get_db()
    data = await db.get_longitudinal(database, model_id, limit)
    await database.close()
    return {"data": data}


@app.post("/api/run")
async def api_start_run(request: Request):
    """Start an evaluation run. Returns the run_id and streams results via SSE."""
    body = await request.json()
    model_url = body.get("model_url", "http://127.0.0.1:8234")
    model_id = body.get("model_id", "auto")
    model_name = body.get("model_name", "")
    api_key = body.get("api_key", "")
    dimensions_raw = body.get("dimensions", [])
    dimensions = [Dimension(d) for d in dimensions_raw] if dimensions_raw else None

    queue: asyncio.Queue = asyncio.Queue()

    async def _run_in_background():
        try:
            async for event, result in orchestrator.run_evaluation(
                model_url=model_url,
                model_id=model_id,
                model_name=model_name,
                dimensions=dimensions,
                api_key=api_key,
            ):
                await queue.put(event)
            await queue.put(None)  # sentinel
        except Exception as e:
            from schemas import RunEvent
            await queue.put(RunEvent(kind="error", run_id="unknown", data={"message": str(e)}))
            await queue.put(None)

    task = asyncio.create_task(_run_in_background())

    # Wait for first event to get run_id
    first = await queue.get()
    if first is None:
        return JSONResponse({"error": "Run failed to start"}, status_code=500)

    run_id = first.run_id
    _active_runs[run_id] = queue

    return JSONResponse({
        "run_id": run_id,
        "stream_url": f"/api/stream/{run_id}",
    })


@app.get("/api/stream/{run_id}")
async def api_stream(run_id: str):
    """SSE endpoint for streaming run events."""
    queue = _active_runs.get(run_id)
    if not queue:
        return JSONResponse({"error": "Run not found or completed"}, status_code=404)

    async def event_generator():
        while True:
            event = await queue.get()
            if event is None:
                _active_runs.pop(run_id, None)
                yield {
                    "event": "done",
                    "data": json.dumps({"run_id": run_id}),
                }
                break
            yield {
                "event": event.kind,
                "data": json.dumps(event.data),
            }

    return EventSourceResponse(event_generator())


@app.post("/api/compare")
async def api_compare(request: Request):
    body = await request.json()
    run_ids = body.get("run_ids", [])
    database = await db.get_db()
    comparison = []
    for rid in run_ids:
        run = await db.get_run(database, rid)
        summaries = await db.get_dimension_summaries(database, rid)
        comparison.append({"run": run, "summaries": summaries})
    await database.close()
    return {"comparison": comparison}


def _group_count(scenarios) -> dict[str, int]:
    counts: dict[str, int] = {}
    for s in scenarios:
        counts[s.dimension.value] = counts.get(s.dimension.value, 0) + 1
    return counts

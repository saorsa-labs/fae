"""SQLite results store for evaluation runs."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

import aiosqlite

from schemas import DimensionSummary, RunResult, ScenarioResult, Verdict

DB_PATH = Path(__file__).parent / "results" / "fae_eval.db"


async def get_db() -> aiosqlite.Connection:
    os.makedirs(DB_PATH.parent, exist_ok=True)
    db = await aiosqlite.connect(str(DB_PATH))
    db.row_factory = aiosqlite.Row
    await _ensure_tables(db)
    return db


async def _ensure_tables(db: aiosqlite.Connection) -> None:
    await db.executescript("""
        CREATE TABLE IF NOT EXISTS runs (
            run_id       TEXT PRIMARY KEY,
            model_id     TEXT NOT NULL,
            model_name   TEXT DEFAULT '',
            started_at   TEXT NOT NULL,
            finished_at  TEXT,
            hardware     TEXT DEFAULT '{}',
            overall_score REAL DEFAULT 0.0,
            status       TEXT DEFAULT 'running'
        );

        CREATE TABLE IF NOT EXISTS scenario_results (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id          TEXT NOT NULL REFERENCES runs(run_id),
            scenario_id     TEXT NOT NULL,
            dimension       TEXT NOT NULL,
            category        TEXT NOT NULL,
            verdict         TEXT NOT NULL,
            score           REAL NOT NULL,
            model_output    TEXT DEFAULT '',
            tool_calls_made TEXT DEFAULT '[]',
            checks_passed   TEXT DEFAULT '[]',
            checks_failed   TEXT DEFAULT '[]',
            latency_ms      REAL DEFAULT 0.0,
            tokens_generated INTEGER DEFAULT 0,
            first_token_ms  REAL DEFAULT 0.0,
            error_message   TEXT DEFAULT ''
        );

        CREATE TABLE IF NOT EXISTS dimension_summaries (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id     TEXT NOT NULL REFERENCES runs(run_id),
            dimension  TEXT NOT NULL,
            total      INTEGER DEFAULT 0,
            passed     INTEGER DEFAULT 0,
            partial    INTEGER DEFAULT 0,
            failed     INTEGER DEFAULT 0,
            errors     INTEGER DEFAULT 0,
            skipped    INTEGER DEFAULT 0,
            score      REAL DEFAULT 0.0,
            avg_latency_ms REAL DEFAULT 0.0,
            categories TEXT DEFAULT '{}',
            UNIQUE(run_id, dimension)
        );

        CREATE INDEX IF NOT EXISTS idx_results_run ON scenario_results(run_id);
        CREATE INDEX IF NOT EXISTS idx_results_dim ON scenario_results(dimension);
        CREATE INDEX IF NOT EXISTS idx_runs_model ON runs(model_id);
    """)
    await db.commit()


async def save_run(db: aiosqlite.Connection, run: RunResult) -> None:
    await db.execute(
        """INSERT OR REPLACE INTO runs
           (run_id, model_id, model_name, started_at, finished_at, hardware, overall_score, status)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            run.run_id,
            run.model_id,
            run.model_name,
            run.started_at.isoformat(),
            run.finished_at.isoformat() if run.finished_at else None,
            json.dumps(run.hardware),
            run.overall_score,
            "complete" if run.finished_at else "running",
        ),
    )
    await db.commit()


async def save_scenario_result(db: aiosqlite.Connection, run_id: str, r: ScenarioResult) -> None:
    await db.execute(
        """INSERT INTO scenario_results
           (run_id, scenario_id, dimension, category, verdict, score,
            model_output, tool_calls_made, checks_passed, checks_failed,
            latency_ms, tokens_generated, first_token_ms, error_message)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            run_id,
            r.scenario_id,
            r.dimension,
            r.category,
            r.verdict,
            r.score,
            r.model_output,
            json.dumps(r.tool_calls_made),
            json.dumps(r.checks_passed),
            json.dumps(r.checks_failed),
            r.latency_ms,
            r.tokens_generated,
            r.first_token_ms,
            r.error_message,
        ),
    )
    await db.commit()


async def save_dimension_summary(db: aiosqlite.Connection, run_id: str, s: DimensionSummary) -> None:
    await db.execute(
        """INSERT OR REPLACE INTO dimension_summaries
           (run_id, dimension, total, passed, partial, failed, errors, skipped,
            score, avg_latency_ms, categories)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            run_id,
            s.dimension,
            s.total,
            s.passed,
            s.partial,
            s.failed,
            s.errors,
            s.skipped,
            s.score,
            s.avg_latency_ms,
            json.dumps(s.categories),
        ),
    )
    await db.commit()


async def get_runs(db: aiosqlite.Connection, model_id: str | None = None, limit: int = 50) -> list[dict]:
    if model_id:
        cursor = await db.execute(
            "SELECT * FROM runs WHERE model_id = ? ORDER BY started_at DESC LIMIT ?",
            (model_id, limit),
        )
    else:
        cursor = await db.execute(
            "SELECT * FROM runs ORDER BY started_at DESC LIMIT ?", (limit,)
        )
    rows = await cursor.fetchall()
    return [dict(r) for r in rows]


async def get_run(db: aiosqlite.Connection, run_id: str) -> dict | None:
    cursor = await db.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,))
    row = await cursor.fetchone()
    return dict(row) if row else None


async def get_run_results(db: aiosqlite.Connection, run_id: str) -> list[dict]:
    cursor = await db.execute(
        "SELECT * FROM scenario_results WHERE run_id = ? ORDER BY dimension, category, scenario_id",
        (run_id,),
    )
    rows = await cursor.fetchall()
    return [dict(r) for r in rows]


async def get_dimension_summaries(db: aiosqlite.Connection, run_id: str) -> list[dict]:
    cursor = await db.execute(
        "SELECT * FROM dimension_summaries WHERE run_id = ? ORDER BY dimension",
        (run_id,),
    )
    rows = await cursor.fetchall()
    return [dict(r) for r in rows]


async def get_latest_complete_run(db: aiosqlite.Connection, model_id: str) -> dict | None:
    """Get the most recent completed run for a model."""
    cursor = await db.execute(
        "SELECT * FROM runs WHERE model_id = ? AND status = 'complete' ORDER BY started_at DESC LIMIT 1",
        (model_id,),
    )
    row = await cursor.fetchone()
    return dict(row) if row else None


async def get_longitudinal(db: aiosqlite.Connection, model_id: str, limit: int = 30) -> list[dict]:
    """Get dimension scores over time for one model."""
    cursor = await db.execute(
        """SELECT r.run_id, r.started_at, r.overall_score, r.model_name,
                  ds.dimension, ds.score
           FROM runs r
           JOIN dimension_summaries ds ON r.run_id = ds.run_id
           WHERE r.model_id = ? AND r.status = 'complete'
           ORDER BY r.started_at DESC
           LIMIT ?""",
        (model_id, limit * 10),
    )
    rows = await cursor.fetchall()
    return [dict(r) for r in rows]

# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Extract correction-based DPO pairs from episode memory records."""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Any

DEFAULT_DB_PATH = os.path.expanduser("~/Library/Application Support/fae/fae.db")
SILENT_ABANDONMENT_SECONDS = 300

EXPLICIT_REPHRASE_RE = re.compile(
    r"\b(too\s+long|shorter\s+please|be\s+brief|make\s+it\s+shorter|concise|tl;?dr)\b",
    re.IGNORECASE,
)
NO_I_MEANT_RE = re.compile(r"\bno\s*,?\s*i\s+meant\b", re.IGNORECASE)


@dataclass
class EpisodeTurn:
    episode_id: str
    created_at_raw: str
    created_at_dt: datetime | None
    user_text: str
    assistant_text: str


@dataclass
class DpoPair:
    prompt: str
    chosen: str
    rejected: str
    reason: str
    source_episode_id: str
    correction_episode_id: str
    gap_seconds: float


def _load_request() -> dict[str, Any]:
    if len(sys.argv) < 2:
        return {"jsonrpc": "2.0", "id": None, "params": {}}

    try:
        request = json.loads(sys.argv[1])
    except json.JSONDecodeError:
        return {"jsonrpc": "2.0", "id": None, "params": {}}

    if isinstance(request, dict):
        request.setdefault("jsonrpc", "2.0")
        request.setdefault("params", {})
        return request

    return {"jsonrpc": "2.0", "id": None, "params": {}}


def _json_rpc_success(request_id: Any, result: dict[str, Any]) -> None:
    print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}))


def _json_rpc_error(request_id: Any, code: int, message: str, data: dict[str, Any] | None = None) -> None:
    payload: dict[str, Any] = {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    }
    if data:
        payload["error"]["data"] = data
    print(json.dumps(payload))


def _parse_iso8601(value: str | None) -> datetime | None:
    if not value or not isinstance(value, str):
        return None

    text = value.strip()
    if not text:
        return None

    if text.endswith("Z"):
        text = text[:-1] + "+00:00"

    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def _extract_sft_message(content: str) -> tuple[str, str] | None:
    if not content:
        return None

    marker = "\nAssistant: "
    if marker in content:
        user_part, assistant_part = content.split(marker, 1)
        user_text = user_part.strip()
        if user_text.startswith("User: "):
            user_text = user_text[6:].strip()
        assistant_text = assistant_part.strip()
        if user_text and assistant_text:
            return user_text, assistant_text

    try:
        parsed = json.loads(content)
    except json.JSONDecodeError:
        return None

    if not isinstance(parsed, dict):
        return None

    messages = parsed.get("messages")
    if not isinstance(messages, list):
        return None

    user_text = ""
    assistant_text = ""
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role", "")).lower()
        text = str(msg.get("content", "")).strip()
        if not text:
            continue
        if role == "user" and not user_text:
            user_text = text
        elif role == "assistant" and user_text and not assistant_text:
            assistant_text = text
            break

    if user_text and assistant_text:
        return user_text, assistant_text

    return None


def _load_episodes(db_path: str, after_timestamp: str | None = None) -> list[EpisodeTurn]:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    query = (
        "SELECT id, content, created_at FROM memory_records "
        "WHERE kind = 'episode' AND status = 'active'"
    )
    params: list[Any] = []
    if isinstance(after_timestamp, str) and after_timestamp.strip():
        query += " AND created_at > ?"
        params.append(after_timestamp.strip())
    query += " ORDER BY created_at ASC"

    try:
        rows = conn.execute(query, params).fetchall()
    finally:
        conn.close()

    episodes: list[EpisodeTurn] = []
    for row in rows:
        content = row["content"] or ""
        parsed = _extract_sft_message(content)
        if parsed is None:
            continue

        user_text, assistant_text = parsed
        created_at_raw = str(row["created_at"] or "")
        episodes.append(
            EpisodeTurn(
                episode_id=str(row["id"]),
                created_at_raw=created_at_raw,
                created_at_dt=_parse_iso8601(created_at_raw),
                user_text=user_text,
                assistant_text=assistant_text,
            )
        )

    return episodes


def _detect_reason(text: str) -> str | None:
    if EXPLICIT_REPHRASE_RE.search(text):
        return "explicit_rephrase"
    if NO_I_MEANT_RE.search(text):
        return "no_i_meant"
    return None


def _build_dpo_pairs(episodes: list[EpisodeTurn]) -> list[DpoPair]:
    pairs: list[DpoPair] = []

    for idx in range(1, len(episodes)):
        prev_ep = episodes[idx - 1]
        curr_ep = episodes[idx]

        reason = _detect_reason(curr_ep.user_text)
        gap_seconds = 0.0
        if prev_ep.created_at_dt and curr_ep.created_at_dt:
            gap_seconds = (curr_ep.created_at_dt - prev_ep.created_at_dt).total_seconds()

        if reason is None and gap_seconds >= SILENT_ABANDONMENT_SECONDS:
            reason = "silent_abandonment_retry"

        if reason is None:
            continue

        pairs.append(
            DpoPair(
                prompt=prev_ep.user_text,
                chosen=curr_ep.assistant_text,
                rejected=prev_ep.assistant_text,
                reason=reason,
                source_episode_id=prev_ep.episode_id,
                correction_episode_id=curr_ep.episode_id,
                gap_seconds=max(gap_seconds, 0.0),
            )
        )

    return pairs


def main() -> None:
    request = _load_request()
    request_id = request.get("id")
    params = request.get("params") or {}

    db_path = os.path.expanduser(str(params.get("db_path", DEFAULT_DB_PATH)))
    after_timestamp = params.get("after_timestamp")

    if not os.path.exists(db_path):
        _json_rpc_error(request_id, -32001, "Database not found", {"db_path": db_path})
        return

    episodes = _load_episodes(db_path, after_timestamp=after_timestamp if isinstance(after_timestamp, str) else None)
    pairs = _build_dpo_pairs(episodes)

    breakdown = {
        "explicit_rephrase": 0,
        "no_i_meant": 0,
        "silent_abandonment_retry": 0,
    }

    serialized_pairs = []
    for pair in pairs:
        if pair.reason in breakdown:
            breakdown[pair.reason] += 1
        serialized_pairs.append(
            {
                "prompt": pair.prompt,
                "chosen": pair.chosen,
                "rejected": pair.rejected,
                "metadata": {
                    "reason": pair.reason,
                    "source_episode_id": pair.source_episode_id,
                    "correction_episode_id": pair.correction_episode_id,
                    "gap_seconds": round(pair.gap_seconds, 2),
                },
            }
        )

    _json_rpc_success(
        request_id,
        {
            "status": "ok",
            "source_db": db_path,
            "episodes_scanned": len(episodes),
            "dpo_pairs": serialized_pairs,
            "stats": {
                "total_pairs": len(serialized_pairs),
                "correction_breakdown": breakdown,
            },
        },
    )


if __name__ == "__main__":
    main()

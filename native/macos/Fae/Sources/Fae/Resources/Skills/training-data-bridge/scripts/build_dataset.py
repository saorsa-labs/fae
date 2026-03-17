# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Build weighted SFT + DPO training datasets from Fae memory."""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

DEFAULT_DB_PATH = os.path.expanduser("~/Library/Application Support/fae/fae.db")
DEFAULT_OUTPUT_DIR = os.path.expanduser("~/Library/Application Support/fae/training/data")
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
    content: str


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


def _select_memory_rows(db_path: str, kind: str, status: str = "active") -> list[sqlite3.Row]:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            """
            SELECT id, kind, content, created_at, status
            FROM memory_records
            WHERE kind = ? AND status = ?
            ORDER BY created_at ASC
            """,
            (kind, status),
        ).fetchall()
    finally:
        conn.close()
    return rows


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
        created_at_raw = row["created_at"] or ""
        episodes.append(
            EpisodeTurn(
                episode_id=str(row["id"]),
                created_at_raw=created_at_raw,
                created_at_dt=_parse_iso8601(created_at_raw),
                user_text=user_text,
                assistant_text=assistant_text,
                content=content,
            )
        )

    return episodes


def _load_interest_keywords(db_path: str) -> dict[str, float]:
    rows = _select_memory_rows(db_path, kind="interest", status="active")
    weights: dict[str, float] = {}

    for row in rows:
        content = str(row["content"] or "").strip()
        if not content:
            continue

        parsed_json: Any = None
        try:
            parsed_json = json.loads(content)
        except json.JSONDecodeError:
            parsed_json = None

        if isinstance(parsed_json, dict):
            topic = str(
                parsed_json.get("topic")
                or parsed_json.get("name")
                or parsed_json.get("interest")
                or ""
            ).strip()
            if topic:
                score = parsed_json.get("score", parsed_json.get("weight", 1.0))
                try:
                    numeric = float(score)
                except (TypeError, ValueError):
                    numeric = 1.0
                weights[topic.lower()] = max(weights.get(topic.lower(), 1.0), max(1.0, numeric))
                continue

        lowered = content.lower()
        if lowered:
            weights[lowered] = max(weights.get(lowered, 1.0), 1.25)

    return weights


def _compute_interest_weight(user_text: str, interest_keywords: dict[str, float]) -> float:
    base = 1.0
    lowered = user_text.lower()
    for keyword, value in interest_keywords.items():
        if keyword and keyword in lowered:
            base += min(value, 3.0) * 0.25
    return round(min(base, 3.0), 4)


def _detect_reason(text: str) -> str | None:
    if EXPLICIT_REPHRASE_RE.search(text):
        return "explicit_rephrase"
    if NO_I_MEANT_RE.search(text):
        return "no_i_meant"
    return None


def _detect_corrections(episodes: list[EpisodeTurn]) -> list[DpoPair]:
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
    output_dir = os.path.expanduser(str(params.get("output_dir", DEFAULT_OUTPUT_DIR)))
    after_timestamp = params.get("after_timestamp")

    if not os.path.exists(db_path):
        _json_rpc_error(request_id, -32001, "Database not found", {"db_path": db_path})
        return

    os.makedirs(output_dir, exist_ok=True)

    episodes = _load_episodes(db_path, after_timestamp=after_timestamp if isinstance(after_timestamp, str) else None)
    interest_keywords = _load_interest_keywords(db_path)
    dpo_pairs = _detect_corrections(episodes)

    system_prompt = "You are Fae, a thoughtful voice-first AI assistant."

    sft_path = os.path.join(output_dir, "sft_export.jsonl")
    dpo_path = os.path.join(output_dir, "dpo_pairs.jsonl")
    meta_path = os.path.join(output_dir, "meta.json")

    sft_count = 0
    weighted_sum = 0.0

    with open(sft_path, "w", encoding="utf-8") as sft_file:
        for episode in episodes:
            weight = _compute_interest_weight(episode.user_text, interest_keywords)
            weighted_sum += weight
            payload = {
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": episode.user_text},
                    {"role": "assistant", "content": episode.assistant_text},
                ],
                "weight": weight,
                "metadata": {
                    "episode_id": episode.episode_id,
                    "created_at": episode.created_at_raw,
                    "kind": "episode",
                },
            }
            sft_file.write(json.dumps(payload, ensure_ascii=False) + "\n")
            sft_count += 1

    dpo_count = 0
    correction_breakdown = {
        "explicit_rephrase": 0,
        "no_i_meant": 0,
        "silent_abandonment_retry": 0,
    }

    with open(dpo_path, "w", encoding="utf-8") as dpo_file:
        for pair in dpo_pairs:
            payload = {
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
            dpo_file.write(json.dumps(payload, ensure_ascii=False) + "\n")
            dpo_count += 1
            if pair.reason in correction_breakdown:
                correction_breakdown[pair.reason] += 1

    profile_rows = _select_memory_rows(db_path, kind="profile", status="active")

    average_weight = round(weighted_sum / sft_count, 4) if sft_count else 0.0
    meta_payload = {
        "status": "ok",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source_db": db_path,
        "output_dir": output_dir,
        "stats": {
            "episodes_scanned": len(episodes),
            "sft_examples": sft_count,
            "dpo_pairs": dpo_count,
            "active_profile_records": len(profile_rows),
            "active_interest_records": len(interest_keywords),
            "average_interest_weight": average_weight,
            "correction_breakdown": correction_breakdown,
        },
        "outputs": {
            "sft_export": sft_path,
            "dpo_pairs": dpo_path,
            "meta": meta_path,
        },
        "quality": {
            "has_sft_data": sft_count > 0,
            "has_dpo_data": dpo_count > 0,
            "empty_dataset": sft_count == 0 and dpo_count == 0,
        },
    }

    with open(meta_path, "w", encoding="utf-8") as meta_file:
        json.dump(meta_payload, meta_file, ensure_ascii=False, indent=2)
        meta_file.write("\n")

    _json_rpc_success(
        request_id,
        {
            "status": "ok",
            "sft_examples": sft_count,
            "dpo_pairs": dpo_count,
            "average_interest_weight": average_weight,
            "output_files": {
                "sft_export": sft_path,
                "dpo_pairs": dpo_path,
                "meta": meta_path,
            },
        },
    )


if __name__ == "__main__":
    main()

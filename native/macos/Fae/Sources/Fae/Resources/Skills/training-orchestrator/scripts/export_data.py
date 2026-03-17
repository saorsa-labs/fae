# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Export active episode records from fae.db into SFT JSONL format."""

import json
import os
import sqlite3
import sys
from datetime import datetime, timezone


DEFAULT_DB_PATH = os.path.expanduser("~/Library/Application Support/fae/fae.db")
DEFAULT_OUTPUT_DIR = os.path.expanduser("~/Library/Application Support/fae/training/data")


def _load_request() -> dict:
    """Load JSON-RPC request payload from argv[1] when provided."""
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


def _extract_sft_message(content: str) -> tuple[str, str] | None:
    """Best-effort conversion from episode text to user+assistant pair."""
    marker = "\nAssistant: "
    if marker not in content:
        return None

    user_part, assistant_part = content.split(marker, 1)
    user_text = user_part.strip()
    if user_text.startswith("User: "):
        user_text = user_text[6:].strip()

    assistant_text = assistant_part.strip()
    if not user_text or not assistant_text:
        return None

    return (user_text, assistant_text)


def _json_rpc_success(request_id, result: dict) -> None:
    payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": result,
    }
    print(json.dumps(payload))


def _json_rpc_error(request_id, code: int, message: str, data: dict | None = None) -> None:
    error = {
        "code": code,
        "message": message,
    }
    if data:
        error["data"] = data
    payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": error,
    }
    print(json.dumps(payload))


def main() -> None:
    request = _load_request()
    request_id = request.get("id")
    params = request.get("params") or {}

    db_path = os.path.expanduser(params.get("db_path", DEFAULT_DB_PATH))
    output_dir = os.path.expanduser(params.get("output_dir", DEFAULT_OUTPUT_DIR))
    after_timestamp = params.get("after_timestamp")

    if not os.path.exists(db_path):
        _json_rpc_error(request_id, -32001, "Database not found", {"db_path": db_path})
        return

    os.makedirs(output_dir, exist_ok=True)

    query = """
        SELECT id, content, created_at
        FROM memory_records
        WHERE kind = 'episode' AND status = 'active'
    """
    query_params: list[str] = []
    if isinstance(after_timestamp, str) and after_timestamp.strip():
        query += " AND created_at > ?"
        query_params.append(after_timestamp.strip())
    query += " ORDER BY created_at ASC"

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(query, query_params).fetchall()
    conn.close()

    system_prompt = "You are Fae, a thoughtful voice-first AI assistant."
    records = []
    last_created_at = None

    for row in rows:
        parsed = _extract_sft_message(row["content"])
        if parsed is None:
            continue

        user_text, assistant_text = parsed
        records.append(
            {
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_text},
                    {"role": "assistant", "content": assistant_text},
                ],
                "metadata": {
                    "episode_id": row["id"],
                    "created_at": row["created_at"],
                },
            }
        )
        last_created_at = row["created_at"]

    # Split 80/20 into train/valid for mlx_lm.lora compatibility.
    split_idx = max(1, int(len(records) * 0.8)) if len(records) > 1 else len(records)
    train_records = records[:split_idx]
    valid_records = records[split_idx:]

    train_path = os.path.join(output_dir, "train.jsonl")
    valid_path = os.path.join(output_dir, "valid.jsonl")

    with open(train_path, "w", encoding="utf-8") as handle:
        for record in train_records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")

    with open(valid_path, "w", encoding="utf-8") as handle:
        for record in valid_records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")

    _json_rpc_success(
        request_id,
        {
            "status": "ok",
            "exported_episodes": len(records),
            "train_count": len(train_records),
            "valid_count": len(valid_records),
            "train_path": train_path,
            "valid_path": valid_path,
            "source_db": db_path,
            "after_timestamp": after_timestamp,
            "last_exported_created_at": last_created_at,
            "generated_at": datetime.now(timezone.utc).isoformat(),
        },
    )


if __name__ == "__main__":
    main()

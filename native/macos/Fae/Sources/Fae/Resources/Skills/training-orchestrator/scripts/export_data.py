# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Export Fae conversation episodes to SFT/DPO training format."""

import json
import os
import sqlite3
import sys


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}

    db_path = os.path.expanduser("~/Library/Application Support/fae/fae.db")
    soul_path = os.path.expanduser("~/Library/Application Support/fae/soul.md")
    output_dir = os.path.expanduser("~/Library/Application Support/fae/training/data")
    last_export = params.get("last_export_timestamp", None)

    if not os.path.exists(db_path):
        print(json.dumps({"error": "Database not found", "path": db_path}))
        return

    os.makedirs(output_dir, exist_ok=True)

    # Read system prompt from soul.md
    system_prompt = "You are Fae, a thoughtful voice-first AI assistant."
    if os.path.exists(soul_path):
        with open(soul_path, "r") as f:
            system_prompt = f.read().strip()[:2000]

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    query = """
        SELECT id, content, created_at, metadata
        FROM memory_records
        WHERE kind = 'episode' AND status = 'active'
    """
    query_params = []
    if last_export:
        query += " AND created_at > ?"
        query_params.append(last_export)
    query += " ORDER BY created_at ASC"

    rows = conn.execute(query, query_params).fetchall()
    conn.close()

    if not rows:
        print(json.dumps({"status": "no_new_data", "record_count": 0}))
        return

    sft_records = []
    dpo_records = []
    all_episodes = []

    for row in rows:
        content = row["content"]
        created_at = row["created_at"]

        if "\nAssistant: " not in content:
            continue

        parts = content.split("\nAssistant: ", 1)
        if len(parts) != 2:
            continue

        user_text = parts[0]
        if user_text.startswith("User: "):
            user_text = user_text[6:]

        assistant_text = parts[1].strip()

        if not user_text.strip() or not assistant_text.strip():
            continue

        episode = {
            "id": row["id"],
            "user": user_text.strip(),
            "assistant": assistant_text,
            "created_at": created_at,
        }
        all_episodes.append(episode)

        sft_records.append({
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": episode["user"]},
                {"role": "assistant", "content": episode["assistant"]},
            ]
        })

    # Extract DPO pairs from correction patterns
    correction_markers = [
        "no,", "no ", "actually", "i meant", "too long", "that's wrong",
        "not what i", "try again", "instead,", "correction:",
    ]

    for i in range(1, len(all_episodes)):
        prev = all_episodes[i - 1]
        curr = all_episodes[i]
        user_lower = curr["user"].lower().strip()

        is_correction = any(user_lower.startswith(m) for m in correction_markers)
        if is_correction and prev["user"].strip():
            dpo_records.append({
                "prompt": prev["user"],
                "chosen": curr["assistant"],
                "rejected": prev["assistant"],
            })

    # Split 90/10
    split_idx = max(1, int(len(sft_records) * 0.9))
    sft_train = sft_records[:split_idx]
    sft_val = sft_records[split_idx:]

    def write_jsonl(path, records):
        with open(path, "w") as f:
            for r in records:
                f.write(json.dumps(r) + "\n")

    write_jsonl(os.path.join(output_dir, "sft_train.jsonl"), sft_train)
    write_jsonl(os.path.join(output_dir, "sft_val.jsonl"), sft_val)
    if dpo_records:
        dpo_split = max(1, int(len(dpo_records) * 0.9))
        write_jsonl(os.path.join(output_dir, "dpo_train.jsonl"), dpo_records[:dpo_split])
        write_jsonl(os.path.join(output_dir, "dpo_val.jsonl"), dpo_records[dpo_split:])

    meta = {
        "exported_at": rows[-1]["created_at"] if rows else None,
        "total_episodes": len(all_episodes),
        "sft_train_count": len(sft_train),
        "sft_val_count": len(sft_val),
        "dpo_count": len(dpo_records),
        "output_dir": output_dir,
    }
    with open(os.path.join(output_dir, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    print(json.dumps({
        "status": "success",
        "record_count": len(all_episodes),
        "sft_train": len(sft_train),
        "sft_val": len(sft_val),
        "dpo_pairs": len(dpo_records),
        "output_dir": output_dir,
    }))


if __name__ == "__main__":
    main()

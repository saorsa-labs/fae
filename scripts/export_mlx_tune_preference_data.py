#!/usr/bin/env python3
"""
Export Fae DPO JSONL into mlx-tune preference JSONL.

Input rows use the existing Fae message-array format:
  {"prompt": [...], "chosen": [...], "rejected": [...]}

Output rows use the plain text format expected by mlx-tune's DPO/ORPO trainers:
  {"prompt": "<formatted chat prompt>", "chosen": "<assistant text>", "rejected": "<assistant text>"}
"""

import argparse
import json
from pathlib import Path

from transformers import AutoTokenizer


def extract_text_content(content: object) -> str:
    if isinstance(content, str):
        return content

    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text = item.get("text", "")
                if isinstance(text, str):
                    parts.append(text)
            elif isinstance(item, str):
                parts.append(item)
        return " ".join(parts)

    return ""


def assistant_text(messages: list[dict]) -> str:
    parts = [
        extract_text_content(message.get("content", ""))
        for message in messages
        if message.get("role") == "assistant"
    ]
    text = "\n".join(part.strip() for part in parts if part.strip())
    return text.strip()


def formatted_prompt(tokenizer: AutoTokenizer, messages: list[dict]) -> str:
    kwargs = {
        "tokenize": False,
        "add_generation_prompt": True,
    }
    try:
        return tokenizer.apply_chat_template(
            messages,
            enable_thinking=False,
            **kwargs,
        )
    except TypeError:
        return tokenizer.apply_chat_template(messages, **kwargs)


def convert_record(tokenizer: AutoTokenizer, record: dict) -> dict | None:
    prompt = record.get("prompt")
    chosen = record.get("chosen")
    rejected = record.get("rejected")

    if not isinstance(prompt, list) or not isinstance(chosen, list) or not isinstance(rejected, list):
        return None

    prompt_text = formatted_prompt(tokenizer, prompt)
    chosen_text = assistant_text(chosen)
    rejected_text = assistant_text(rejected)

    if not prompt_text.strip() or not chosen_text or not rejected_text:
        return None

    return {
        "prompt": prompt_text,
        "chosen": chosen_text,
        "rejected": rejected_text,
    }


def iter_jsonl(path: Path):
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if line:
                yield json.loads(line)


def write_jsonl(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tokenizer", required=True, help="Model or local tokenizer path")
    args = parser.parse_args()

    tokenizer = AutoTokenizer.from_pretrained(args.tokenizer, trust_remote_code=True)

    converted: list[dict] = []
    skipped = 0
    for record in iter_jsonl(args.input):
        result = convert_record(tokenizer, record)
        if result is None:
            skipped += 1
            continue
        converted.append(result)

    write_jsonl(args.output, converted)
    print(f"Converted {len(converted)} preference rows -> {args.output}")
    if skipped:
        print(f"Skipped {skipped} invalid rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

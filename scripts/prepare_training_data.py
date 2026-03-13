#!/usr/bin/env python3
"""
Prepare Fae companion model training data from markdown source files.

Reads every `*-post-train-data.md` file in the project root.

Current sources include:
  - claude-post-train-data.md  → DPO preference pairs
  - codex-post-train-data.md   → SFT seed examples and JSON chat examples
  - tool-post-train-data.md    → tool-focused SFT + DPO examples

Writes:
  - training/data/dpo.jsonl   — DPO preference pairs (prompt / chosen / rejected)
  - training/data/sft.jsonl   — SFT chat examples (messages array)

SFT output is assembled from:
  - explicit `{"messages": [...]}` JSON blocks
  - text-format seed examples under `## Seed SFT examples`
  - safe DPO → SFT conversion, excluding tool-sensitive prompts that would
    otherwise teach fabricated actions such as "reminder set" without a tool call

With --split flag, also writes:
  - training/data/dpo_train.jsonl / dpo_val.jsonl (90/10)
  - training/data/sft_train.jsonl / sft_val.jsonl (90/10)

Usage:
  python3 scripts/prepare_training_data.py
  python3 scripts/prepare_training_data.py --split
  python3 scripts/prepare_training_data.py --source-dir /path/to/fae
"""

import argparse
import json
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Extraction helpers
# ---------------------------------------------------------------------------

TOOL_SENSITIVE_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in [
        r"\bcalendar\b",
        r"\bschedule(?:d|ing)?\b",
        r"\bmeeting\b",
        r"\bappointment\b",
        r"\bremind(?:er| me)?\b",
        r"\bto-?do\b",
        r"\btask list\b",
        r"\btimer\b",
        r"\balarm\b",
        r"\bweather\b",
        r"\bheadlines?\b",
        r"\blatest news\b",
        r"\bnews about\b",
        r"\bsearch the web\b",
        r"\bweb search\b",
        r"\blook (?:something )?up\b",
        r"\bgoogle\b",
        r"\bemail\b",
        r"\bmail\b",
        r"\binbox\b",
        r"\bcontact(?:s)?\b",
        r"\bphone number\b",
        r"\bemail address\b",
        r"\bnotes?\b",
        r"\bjot down\b",
        r"\bfile\b",
        r"\bfolder\b",
        r"\bpath\b",
        r"~/",
        r"/Users/",
        r"\bscreenshot\b",
        r"\bcamera\b",
        r"\bphoto\b",
        r"\bpicture\b",
        r"\bwhat(?:'s| is) on my screen\b",
        r"\bscreen recording\b",
        r"\bread_screen\b",
        r"\bclick\b",
        r"\btype text\b",
        r"\bscroll\b",
        r"\bfind element\b",
        r"\bcreate\b.*\b(?:event|reminder|note|file)\b",
        r"\bdelete\b.*\b(?:file|note|event|reminder)\b",
        r"\bedit\b.*\b(?:file|note|document)\b",
        r"\bwrite\b.*\b(?:file|note)\b",
    ]
]


def discover_markdown_sources(source_dir: Path) -> list[Path]:
    """Return all training-data markdown sources in deterministic order."""
    return sorted(source_dir.glob("*-post-train-data.md"))


def extract_json_blocks(text: str) -> list[dict]:
    """Extract all fenced JSON blocks from markdown text. Returns list of parsed dicts."""
    pattern = re.compile(r"```json\s*\n(.*?)```", re.DOTALL)
    results = []
    for match in pattern.finditer(text):
        raw = match.group(1).strip()
        try:
            parsed = json.loads(raw)
            results.append(parsed)
        except json.JSONDecodeError as e:
            results.append({"_parse_error": str(e), "_raw": raw[:200]})
    return results


def extract_text_content(content: object) -> str:
    """Normalize message content into text for string-based checks.

    Supports plain string content and multimodal list content like:
    [{"type": "text", "text": "..."}, {"type": "image_url", ...}]
    """
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


def extract_dpo_pairs(text: str) -> tuple[list[dict], list[str]]:
    """Extract DPO pairs from claude-post-train-data.md.

    Expected format per entry:
        ### DPO-NNN — description
        ```json
        {
          "prompt": [...],
          "chosen": [...],
          "rejected": [...]
        }
        ```

    Returns (pairs, errors).
    """
    pairs = []
    errors = []

    blocks = extract_json_blocks(text)
    for i, block in enumerate(blocks):
        if "_parse_error" in block:
            errors.append(f"DPO block {i+1}: JSON parse error: {block['_parse_error']}")
            continue

        missing = [k for k in ("prompt", "chosen", "rejected") if k not in block]
        if missing:
            if "messages" not in block:
                errors.append(f"DPO block {i+1}: missing keys {missing}, skipping")
            continue

        if not isinstance(block["prompt"], list):
            errors.append(f"DPO block {i+1}: 'prompt' must be a messages array, skipping")
            continue
        if not isinstance(block["chosen"], list):
            errors.append(f"DPO block {i+1}: 'chosen' must be a messages array, skipping")
            continue
        if not isinstance(block["rejected"], list):
            errors.append(f"DPO block {i+1}: 'rejected' must be a messages array, skipping")
            continue

        if not block.get("chosen"):
            errors.append(f"DPO block {i+1}: empty 'chosen' array, skipping")
            continue
        if not block.get("rejected"):
            errors.append(f"DPO block {i+1}: empty 'rejected' array, skipping")
            continue

        if any(not isinstance(m, dict) for m in block["prompt"]):
            errors.append(f"DPO block {i+1}: prompt contains non-message entries, skipping")
            continue
        if any(not isinstance(m, dict) for m in block["chosen"]):
            errors.append(f"DPO block {i+1}: chosen contains non-message entries, skipping")
            continue
        if any(not isinstance(m, dict) for m in block["rejected"]):
            errors.append(f"DPO block {i+1}: rejected contains non-message entries, skipping")
            continue

        chosen_content = " ".join(
            extract_text_content(m.get("content", ""))
            for m in block["chosen"]
            if m.get("role") == "assistant"
        )
        rejected_content = " ".join(
            extract_text_content(m.get("content", ""))
            for m in block["rejected"]
            if m.get("role") == "assistant"
        )
        if not chosen_content.strip():
            errors.append(f"DPO block {i+1}: chosen has no assistant content, skipping")
            continue
        if not rejected_content.strip():
            errors.append(f"DPO block {i+1}: rejected has no assistant content, skipping")
            continue

        pairs.append(block)

    return pairs, errors


def extract_sft_examples_from_json_blocks(text: str) -> tuple[list[dict], list[str]]:
    """Extract SFT examples from JSON blocks with a 'messages' key.

    These appear in codex-post-train-data.md if present, or in any markdown file
    that uses the SFT messages format.

    Returns (examples, errors).
    """
    examples = []
    errors = []

    blocks = extract_json_blocks(text)
    for i, block in enumerate(blocks):
        if "_parse_error" in block:
            continue

        if "messages" not in block:
            continue

        msgs = block["messages"]
        if not isinstance(msgs, list) or len(msgs) == 0:
            errors.append(f"SFT block {i+1}: empty or invalid messages array, skipping")
            continue

        assistant_msgs = [
            m
            for m in msgs
            if m.get("role") == "assistant"
            and extract_text_content(m.get("content", "")).strip()
        ]
        if not assistant_msgs:
            errors.append(f"SFT block {i+1}: no assistant messages with content, skipping")
            continue

        example = {"messages": msgs}
        if "tools" in block:
            example["tools"] = block["tools"]
        examples.append(example)

    return examples, errors


def extract_sft_examples_from_seed_section(text: str) -> tuple[list[dict], list[str]]:
    """Extract SFT examples from codex-post-train-data.md seed section."""
    examples = []
    errors = []

    system_prompt = (
        "You are Fae, a personal AI companion. "
        "Be direct, concise, and warm without performance."
    )

    seed_section_match = re.search(
        r"## Seed SFT examples\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL
    )
    if not seed_section_match:
        return examples, errors

    seed_text = seed_section_match.group(1)
    example_blocks = re.split(r"\n### Example \d+:", seed_text)

    for i, block in enumerate(example_blocks):
        if not block.strip():
            continue

        user_match = re.search(r"\*\*User\*\*\s*\n```(?:text)?\s*\n(.*?)```", block, re.DOTALL)
        assistant_match = re.search(
            r"\*\*Assistant\*\*\s*\n```(?:text)?\s*\n(.*?)```", block, re.DOTALL
        )

        if not user_match or not assistant_match:
            errors.append(f"Seed SFT block {i+1}: could not extract user/assistant pair, skipping")
            continue

        user_content = user_match.group(1).strip()
        assistant_content = assistant_match.group(1).strip()

        if not user_content or not assistant_content:
            errors.append(f"Seed SFT block {i+1}: empty user or assistant content, skipping")
            continue

        examples.append(
            {
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_content},
                    {"role": "assistant", "content": assistant_content},
                ]
            }
        )

    return examples, errors


def is_tool_sensitive_prompt(messages: list[dict]) -> bool:
    """Return True when the prompt implies tool use or external state changes."""
    user_text = " ".join(
        extract_text_content(msg.get("content", ""))
        for msg in messages
        if isinstance(msg, dict) and msg.get("role") == "user"
    )
    return any(pattern.search(user_text) for pattern in TOOL_SENSITIVE_PATTERNS)


def derive_sft_examples_from_dpo_pairs(dpo_pairs: list[dict]) -> tuple[list[dict], int]:
    """Convert safe DPO pairs into SFT examples by concatenating prompt + chosen.

    Tool-sensitive prompts are skipped on purpose. The DPO corpus contains many
    old-style examples like "Reminder set" or "Checking your calendar now" that
    harmed tool calling when used as direct SFT demonstrations.
    """
    examples = []
    skipped_tool_sensitive = 0

    for pair in dpo_pairs:
        prompt = pair.get("prompt", [])
        chosen = pair.get("chosen", [])
        if is_tool_sensitive_prompt(prompt):
            skipped_tool_sensitive += 1
            continue

        example = {"messages": prompt + chosen}
        if "tools" in pair:
            example["tools"] = pair["tools"]
        examples.append(example)

    return examples, skipped_tool_sensitive


def dedupe_records(records: list[dict]) -> tuple[list[dict], int]:
    """Deduplicate records by canonical JSON encoding while preserving order."""
    deduped = []
    seen = set()
    duplicates = 0

    for record in records:
        key = json.dumps(record, sort_keys=True, ensure_ascii=False)
        if key in seen:
            duplicates += 1
            continue
        seen.add(key)
        deduped.append(record)

    return deduped, duplicates


# ---------------------------------------------------------------------------
# Train/val split
# ---------------------------------------------------------------------------


def split_data(records: list, train_ratio: float = 0.9) -> tuple[list, list]:
    """Split records into train and val sets deterministically."""
    n_train = max(1, int(len(records) * train_ratio))
    return records[:n_train], records[n_train:]


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------


def write_jsonl(path: Path, records: list[dict]) -> None:
    """Write list of dicts to a JSONL file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prepare Fae companion model training data from markdown sources."
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=None,
        help="Project root directory. Defaults to two levels up from this script.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Output directory for JSONL files. Defaults to <source-dir>/training/data/.",
    )
    parser.add_argument(
        "--split",
        action="store_true",
        help="Also write 90/10 train/val splits.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print all validation errors (not just the summary count).",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    source_dir = args.source_dir or script_dir.parent
    output_dir = args.output_dir or (source_dir / "training" / "data")

    print(f"Source directory: {source_dir}")
    print(f"Output directory: {output_dir}")
    print()

    source_files = discover_markdown_sources(source_dir)
    if not source_files:
        print(
            f"ERROR: No *-post-train-data.md files found in {source_dir}",
            file=sys.stderr,
        )
        return 1

    file_texts: dict[Path, str] = {}
    for path in source_files:
        text = path.read_text(encoding="utf-8")
        file_texts[path] = text
        print(f"Read {len(text):,} chars from {path.name}")

    print()
    print("=== DPO extraction ===")
    dpo_pairs: list[dict] = []
    dpo_errors: list[str] = []
    dpo_counts: dict[str, int] = {}

    for path, text in file_texts.items():
        pairs, errors = extract_dpo_pairs(text)
        dpo_pairs.extend(pairs)
        dpo_errors.extend([f"{path.name}: {err}" for err in errors])
        if pairs:
            dpo_counts[path.name] = len(pairs)

    for name, count in dpo_counts.items():
        print(f"{name}: {count} DPO pairs")
    print(f"Extracted {len(dpo_pairs)} DPO pairs total")
    if dpo_errors:
        print(f"Validation errors: {len(dpo_errors)}")
        if args.verbose:
            for err in dpo_errors:
                print(f"  - {err}")
    else:
        print("No validation errors")
    print()

    print("=== SFT extraction ===")
    all_sft_examples: list[dict] = []
    all_sft_errors: list[str] = []

    for path, text in file_texts.items():
        sft_from_json, errs = extract_sft_examples_from_json_blocks(text)
        all_sft_examples.extend(sft_from_json)
        all_sft_errors.extend([f"{path.name}: {err}" for err in errs])
        if sft_from_json:
            print(f"{path.name}: {len(sft_from_json)} SFT JSON blocks")

        sft_from_seed, errs = extract_sft_examples_from_seed_section(text)
        all_sft_examples.extend(sft_from_seed)
        all_sft_errors.extend([f"{path.name}: {err}" for err in errs])
        if sft_from_seed:
            print(f"{path.name}: {len(sft_from_seed)} seed SFT examples")

    sft_from_dpo, skipped_tool_sensitive = derive_sft_examples_from_dpo_pairs(dpo_pairs)
    if sft_from_dpo:
        print(f"Derived {len(sft_from_dpo)} safe SFT examples from DPO chosen responses")
    if skipped_tool_sensitive:
        print(f"Skipped {skipped_tool_sensitive} tool-sensitive DPO pairs during SFT derivation")
    all_sft_examples.extend(sft_from_dpo)

    dpo_pairs, duplicate_dpo = dedupe_records(dpo_pairs)
    if duplicate_dpo:
        print(f"Removed {duplicate_dpo} duplicate DPO pairs")

    all_sft_examples, duplicate_sft = dedupe_records(all_sft_examples)
    if duplicate_sft:
        print(f"Removed {duplicate_sft} duplicate SFT examples")

    print(f"Total SFT examples: {len(all_sft_examples)}")
    if all_sft_errors:
        print(f"Validation errors: {len(all_sft_errors)}")
        if args.verbose:
            for err in all_sft_errors:
                print(f"  - {err}")
    else:
        print("No validation errors")
    print()

    print("=== Writing output ===")

    dpo_path = output_dir / "dpo.jsonl"
    write_jsonl(dpo_path, dpo_pairs)
    print(f"Wrote {len(dpo_pairs):>6} records → {dpo_path}")

    sft_path = output_dir / "sft.jsonl"
    write_jsonl(sft_path, all_sft_examples)
    print(f"Wrote {len(all_sft_examples):>6} records → {sft_path}")

    if args.split:
        print()
        print("=== Train/val splits (90/10) ===")

        dpo_train, dpo_val = split_data(dpo_pairs)
        write_jsonl(output_dir / "dpo_train.jsonl", dpo_train)
        write_jsonl(output_dir / "dpo_val.jsonl", dpo_val)
        print(f"DPO  train: {len(dpo_train):>6}  val: {len(dpo_val):>6}")

        if all_sft_examples:
            sft_train, sft_val = split_data(all_sft_examples)
            write_jsonl(output_dir / "sft_train.jsonl", sft_train)
            write_jsonl(output_dir / "sft_val.jsonl", sft_val)
            print(f"SFT  train: {len(sft_train):>6}  val: {len(sft_val):>6}")
        else:
            print("SFT: no examples to split")

    print()

    total_errors = len(dpo_errors) + len(all_sft_errors)
    print("=== Summary ===")
    print(f"DPO pairs extracted:   {len(dpo_pairs)}")
    print(f"SFT examples extracted: {len(all_sft_examples)}")
    print(f"Total validation errors: {total_errors}")
    if total_errors > 0 and not args.verbose:
        print("  (run with --verbose to see all errors)")

    if len(dpo_pairs) == 0:
        print()
        print("WARNING: No DPO pairs were extracted. Check that the source file contains")
        print("  JSON blocks with 'prompt', 'chosen', and 'rejected' keys.")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

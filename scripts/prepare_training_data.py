#!/usr/bin/env python3
"""
Prepare Fae companion model training data from markdown source files.

Reads:
  - claude-post-train-data.md  → DPO pairs (500 pairs across 18 behavioral clusters)
  - codex-post-train-data.md   → SFT seed examples (text-format examples converted to chat format)

Writes:
  - training_data/dpo.jsonl   — DPO preference pairs (prompt / chosen / rejected)
  - training_data/sft.jsonl   — SFT chat examples (messages array)

With --split flag, also writes:
  - training_data/dpo_train.jsonl / dpo_val.jsonl (90/10)
  - training_data/sft_train.jsonl / sft_val.jsonl (90/10)

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

def extract_json_blocks(text: str) -> list[dict]:
    """Extract all fenced JSON blocks from markdown text. Returns list of parsed dicts."""
    # Match ```json ... ``` blocks (non-greedy, across newlines)
    pattern = re.compile(r"```json\s*\n(.*?)```", re.DOTALL)
    results = []
    for match in pattern.finditer(text):
        raw = match.group(1).strip()
        try:
            parsed = json.loads(raw)
            results.append(parsed)
        except json.JSONDecodeError as e:
            # Collect errors but continue processing
            results.append({"_parse_error": str(e), "_raw": raw[:200]})
    return results


def extract_dpo_pairs(text: str) -> tuple[list[dict], list[str]]:
    """
    Extract DPO pairs from claude-post-train-data.md.

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

        # Validate required keys
        missing = [k for k in ("prompt", "chosen", "rejected") if k not in block]
        if missing:
            # Could be an SFT block or something else — skip silently unless it looks like a DPO attempt
            if "messages" not in block:
                errors.append(f"DPO block {i+1}: missing keys {missing}, skipping")
            continue

        # Validate non-empty content
        if not block.get("chosen"):
            errors.append(f"DPO block {i+1}: empty 'chosen' array, skipping")
            continue
        if not block.get("rejected"):
            errors.append(f"DPO block {i+1}: empty 'rejected' array, skipping")
            continue

        # Validate assistant content in chosen and rejected
        chosen_content = " ".join(
            m.get("content", "") for m in block["chosen"] if m.get("role") == "assistant"
        )
        rejected_content = " ".join(
            m.get("content", "") for m in block["rejected"] if m.get("role") == "assistant"
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
    """
    Extract SFT examples from JSON blocks with a 'messages' key.

    These appear in codex-post-train-data.md if present, or in any markdown file
    that uses the SFT messages format.

    Returns (examples, errors).
    """
    examples = []
    errors = []

    blocks = extract_json_blocks(text)
    for i, block in enumerate(blocks):
        if "_parse_error" in block:
            continue  # Already counted in DPO pass if same file

        if "messages" not in block:
            continue  # Not an SFT block

        msgs = block["messages"]
        if not isinstance(msgs, list) or len(msgs) == 0:
            errors.append(f"SFT block {i+1}: empty or invalid messages array, skipping")
            continue

        # Must have at least one assistant message with content
        assistant_msgs = [m for m in msgs if m.get("role") == "assistant" and m.get("content", "").strip()]
        if not assistant_msgs:
            errors.append(f"SFT block {i+1}: no assistant messages with content, skipping")
            continue

        examples.append({"messages": msgs})

    return examples, errors


def extract_sft_examples_from_seed_section(text: str) -> tuple[list[dict], list[str]]:
    """
    Extract SFT examples from codex-post-train-data.md seed section.

    The seed examples use a text-block format:
        ### Example N: description
        **User**
        ```text
        user message
        ```
        **Assistant**
        ```text
        assistant message
        ```

    Each is converted to a messages-format SFT example with a standard system prompt.
    Returns (examples, errors).
    """
    examples = []
    errors = []

    SYSTEM_PROMPT = (
        "You are Fae, a personal AI companion. "
        "Be direct, concise, and warm without performance."
    )

    # Find the Seed SFT examples section
    seed_section_match = re.search(
        r"## Seed SFT examples\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL
    )
    if not seed_section_match:
        return examples, errors

    seed_text = seed_section_match.group(1)

    # Split into individual examples by "### Example N:"
    example_blocks = re.split(r"\n### Example \d+:", seed_text)

    for i, block in enumerate(example_blocks):
        if not block.strip():
            continue

        # Extract user message from ```text block after **User**
        user_match = re.search(r"\*\*User\*\*\s*\n```(?:text)?\s*\n(.*?)```", block, re.DOTALL)
        # Extract assistant message from ```text block after **Assistant**
        assistant_match = re.search(r"\*\*Assistant\*\*\s*\n```(?:text)?\s*\n(.*?)```", block, re.DOTALL)

        if not user_match or not assistant_match:
            # Multi-turn or different format — skip
            errors.append(f"Seed SFT block {i+1}: could not extract user/assistant pair, skipping")
            continue

        user_content = user_match.group(1).strip()
        assistant_content = assistant_match.group(1).strip()

        if not user_content or not assistant_content:
            errors.append(f"Seed SFT block {i+1}: empty user or assistant content, skipping")
            continue

        examples.append({
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_content},
                {"role": "assistant", "content": assistant_content},
            ]
        })

    return examples, errors


# ---------------------------------------------------------------------------
# Train/val split
# ---------------------------------------------------------------------------

def split_data(records: list, train_ratio: float = 0.9) -> tuple[list, list]:
    """Split records into train and val sets deterministically (no shuffle for reproducibility)."""
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
        help="Output directory for JSONL files. Defaults to <source-dir>/training_data/.",
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

    # Resolve source dir: default is two levels up from scripts/prepare_training_data.py
    script_dir = Path(__file__).resolve().parent
    source_dir = args.source_dir or script_dir.parent
    output_dir = args.output_dir or (source_dir / "training" / "data")

    dpo_source = source_dir / "claude-post-train-data.md"
    sft_source = source_dir / "codex-post-train-data.md"

    # ------------------------------------------------------------------
    # Read source files
    # ------------------------------------------------------------------
    print(f"Source directory: {source_dir}")
    print(f"Output directory: {output_dir}")
    print()

    if not dpo_source.exists():
        print(f"ERROR: DPO source file not found: {dpo_source}", file=sys.stderr)
        return 1

    dpo_text = dpo_source.read_text(encoding="utf-8")
    print(f"Read {len(dpo_text):,} chars from {dpo_source.name}")

    sft_text = ""
    if sft_source.exists():
        sft_text = sft_source.read_text(encoding="utf-8")
        print(f"Read {len(sft_text):,} chars from {sft_source.name}")
    else:
        print(f"Note: {sft_source.name} not found — skipping codex SFT extraction")

    print()

    # ------------------------------------------------------------------
    # Extract DPO pairs
    # ------------------------------------------------------------------
    print("=== DPO extraction ===")
    dpo_pairs, dpo_errors = extract_dpo_pairs(dpo_text)
    print(f"Extracted {len(dpo_pairs)} DPO pairs")
    if dpo_errors:
        print(f"Validation errors: {len(dpo_errors)}")
        if args.verbose:
            for err in dpo_errors:
                print(f"  - {err}")
    else:
        print("No validation errors")
    print()

    # ------------------------------------------------------------------
    # Extract SFT examples
    # ------------------------------------------------------------------
    print("=== SFT extraction ===")
    all_sft_examples: list[dict] = []
    all_sft_errors: list[str] = []

    # Try JSON-block SFT from DPO source (in case it has any messages-format blocks)
    sft_from_dpo, errs = extract_sft_examples_from_json_blocks(dpo_text)
    all_sft_examples.extend(sft_from_dpo)
    all_sft_errors.extend(errs)
    if sft_from_dpo:
        print(f"Found {len(sft_from_dpo)} SFT JSON blocks in {dpo_source.name}")

    if sft_text:
        # JSON-block SFT from codex source
        sft_from_codex_json, errs = extract_sft_examples_from_json_blocks(sft_text)
        all_sft_examples.extend(sft_from_codex_json)
        all_sft_errors.extend(errs)
        if sft_from_codex_json:
            print(f"Found {len(sft_from_codex_json)} SFT JSON blocks in {sft_source.name}")

        # Seed SFT examples from text blocks in codex source
        sft_from_seed, errs = extract_sft_examples_from_seed_section(sft_text)
        all_sft_examples.extend(sft_from_seed)
        all_sft_errors.extend(errs)
        if sft_from_seed:
            print(f"Extracted {len(sft_from_seed)} seed SFT examples from {sft_source.name}")

    print(f"Total SFT examples: {len(all_sft_examples)}")
    if all_sft_errors:
        print(f"Validation errors: {len(all_sft_errors)}")
        if args.verbose:
            for err in all_sft_errors:
                print(f"  - {err}")
    else:
        print("No validation errors")
    print()

    # ------------------------------------------------------------------
    # Write output files
    # ------------------------------------------------------------------
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

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
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

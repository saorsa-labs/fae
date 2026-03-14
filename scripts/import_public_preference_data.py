#!/usr/bin/env python3
"""Import selected public preference datasets into Fae's canonical JSONL format.

Writes canonical DPO rows under:
  training/imports/public/*.jsonl

Current sources:
  - nvidia/HelpSteer3
  - MadeAgents/xlam-irrelevance-7.5k
  - chrissiecsj/ToolPreference
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Iterable


def write_jsonl(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def stable_sample(records: list[dict], limit: int, seed: int) -> list[dict]:
    if limit == 0:
        return []
    if limit < 0 or len(records) <= limit:
        return records
    items = list(records)
    random.Random(seed).shuffle(items)
    return items[:limit]


def truncate(text: str, max_chars: int) -> str:
    text = text.strip()
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 3].rstrip() + "..."


def canonical_dpo(
    prompt: list[dict],
    chosen: str,
    rejected: str,
    *,
    source: str,
    metadata: dict | None = None,
) -> dict:
    record = {
        "prompt": prompt,
        "chosen": [{"role": "assistant", "content": chosen.strip()}],
        "rejected": [{"role": "assistant", "content": rejected.strip()}],
        "source": source,
    }
    if metadata:
        record["metadata"] = metadata
    return record


def import_helpsteer3(limit: int, seed: int) -> list[dict]:
    from datasets import load_dataset

    dataset = load_dataset("nvidia/HelpSteer3", split="train")
    rows = [converted for row in dataset if (converted := convert_helpsteer3_row(row)) is not None]
    return stable_sample(rows, limit, seed)


def render_tool_summary(tools: Iterable[dict], max_tools: int = 8) -> str:
    lines: list[str] = []
    for tool in list(tools)[:max_tools]:
        name = tool.get("name", "unknown")
        description = str(tool.get("description", "")).strip()
        if description:
            lines.append(f"- {name}: {description}")
        else:
            lines.append(f"- {name}")
    return "\n".join(lines)


def convert_helpsteer3_row(row: dict) -> dict | None:
    if row.get("language") != "english":
        return None
    if row.get("domain") != "general":
        return None

    context = row.get("context")
    if not isinstance(context, list) or not context:
        return None
    if context[-1].get("role") != "user":
        return None

    preference = row.get("overall_preference")
    if preference == 0:
        return None

    response1 = (row.get("response1") or "").strip()
    response2 = (row.get("response2") or "").strip()
    if not response1 or not response2 or response1 == response2:
        return None

    chosen = response1 if preference < 0 else response2
    rejected = response2 if preference < 0 else response1

    prompt = []
    for message in context:
        role = message.get("role")
        content = message.get("content")
        if role not in {"system", "user", "assistant"} or not isinstance(content, str):
            return None
        prompt.append({"role": role, "content": content.strip()})

    return canonical_dpo(
        prompt,
        chosen,
        rejected,
        source="nvidia/HelpSteer3",
        metadata={"domain": row.get("domain"), "language": row.get("language")},
    )


def import_xlam_irrelevance(limit: int, seed: int) -> list[dict]:
    from huggingface_hub import hf_hub_download

    path = hf_hub_download(
        repo_id="MadeAgents/xlam-irrelevance-7.5k",
        repo_type="dataset",
        filename="xlam-7.5k-irrelevancek.json",
    )
    with open(path, encoding="utf-8") as handle:
        raw_rows = json.load(handle)

    rows = [converted for row in raw_rows if (converted := convert_xlam_irrelevance_row(row)) is not None]
    return stable_sample(rows, limit, seed)


def convert_xlam_irrelevance_row(row: dict) -> dict | None:
    query = str(row.get("query", "")).strip()
    if not query:
        return None

    try:
        tools = json.loads(row.get("tools", "[]"))
    except json.JSONDecodeError:
        return None
    if not isinstance(tools, list) or not tools:
        return None

    first_tool = str(tools[0].get("name", "")).strip()
    if not first_tool:
        return None

    tool_summary = render_tool_summary(tools)
    prompt = [
        {
            "role": "system",
            "content": (
                "You are Fae, a local assistant. Use a tool only when one of the available "
                "tools is actually relevant to the user's request. If none fits, do not call a tool."
            ),
        },
        {
            "role": "user",
            "content": (
                f"User request:\n{query}\n\nAvailable tools:\n{tool_summary}\n\n"
                "If none of these tools are relevant, say so rather than forcing a call."
            ),
        },
    ]
    return canonical_dpo(
        prompt,
        "None of the available tools are relevant to this request, so I should not call a tool.",
        f"I should use the {first_tool} tool for this request.",
        source="MadeAgents/xlam-irrelevance-7.5k",
        metadata={"tool_count": len(tools)},
    )


def import_toolpreference(limit: int, seed: int) -> list[dict]:
    from huggingface_hub import hf_hub_download

    path = hf_hub_download(
        repo_id="chrissiecsj/ToolPreference",
        repo_type="dataset",
        filename="dpo_preferencepairs_train.json",
    )
    with open(path, encoding="utf-8") as handle:
        raw_rows = json.load(handle)

    rows = [converted for row in raw_rows if (converted := convert_toolpreference_row(row)) is not None]
    return stable_sample(rows, limit, seed)


def convert_toolpreference_row(row: dict) -> dict | None:
    outputs = row.get("output")
    if not isinstance(outputs, list) or len(outputs) != 2:
        return None
    chosen = str(outputs[0]).strip()
    rejected = str(outputs[1]).strip()
    if not chosen or not rejected or chosen == rejected:
        return None

    instruction = truncate(str(row.get("instruction", "")).strip(), 3000)
    trajectory = truncate(str(row.get("input", "")).strip(), 5000)
    if not instruction or not trajectory:
        return None

    prompt = [
        {
            "role": "system",
            "content": (
                "You are Fae. Prefer the better next step in a tool-using trajectory. "
                "Favor concrete progress or concrete recovery over vague stalling."
            ),
        },
        {
            "role": "user",
            "content": (
                "Imported ToolPreference example.\n\n"
                f"Task and tool context:\n{instruction}\n\n"
                f"Trajectory so far:\n{trajectory}\n\n"
                "Which next assistant step is better?"
            ),
        },
    ]
    return canonical_dpo(
        prompt,
        chosen,
        rejected,
        source="chrissiecsj/ToolPreference",
        metadata={"category": row.get("category"), "sample_id": row.get("id")},
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("training/imports/public"),
        help="Directory for imported canonical JSONL files.",
    )
    parser.add_argument("--seed", type=int, default=3407)
    parser.add_argument("--helpsteer3-limit", type=int, default=1000)
    parser.add_argument("--xlam-irrelevance-limit", type=int, default=750)
    parser.add_argument("--toolpreference-limit", type=int, default=250)
    args = parser.parse_args()

    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    manifest: dict[str, int] = {}

    helpsteer_rows = import_helpsteer3(args.helpsteer3_limit, args.seed)
    write_jsonl(output_dir / "helpsteer3_dpo.jsonl", helpsteer_rows)
    manifest["nvidia/HelpSteer3"] = len(helpsteer_rows)

    xlam_rows = import_xlam_irrelevance(args.xlam_irrelevance_limit, args.seed)
    write_jsonl(output_dir / "xlam_irrelevance_dpo.jsonl", xlam_rows)
    manifest["MadeAgents/xlam-irrelevance-7.5k"] = len(xlam_rows)

    toolpreference_rows = import_toolpreference(args.toolpreference_limit, args.seed)
    write_jsonl(output_dir / "toolpreference_dpo.jsonl", toolpreference_rows)
    manifest["chrissiecsj/ToolPreference"] = len(toolpreference_rows)

    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    for source, count in manifest.items():
        print(f"{source}: {count}")
    print(f"Manifest written to {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

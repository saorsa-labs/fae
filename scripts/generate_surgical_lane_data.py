#!/usr/bin/env python3
"""Generate a tiny benchmark-shaped surgical lane for Fae's stubborn 9B misses.

This lane targets only:
  - strict one-sentence obedience
  - durable-memory storage of stable preferences

It writes canonical JSONL files under the chosen output directory:
  - surgical_sft.jsonl
  - surgical_dpo.jsonl
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


SOURCE = "fae/surgical-benchmark-lane"


def write_jsonl(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def sft(messages: list[dict], *, metadata: dict | None = None) -> dict:
    record = {"messages": messages, "source": SOURCE}
    if metadata:
        record["metadata"] = metadata
    return record


def dpo(prompt: list[dict], chosen: str, rejected: str, *, metadata: dict | None = None) -> dict:
    record = {
        "prompt": prompt,
        "chosen": [{"role": "assistant", "content": chosen}],
        "rejected": [{"role": "assistant", "content": rejected}],
        "source": SOURCE,
    }
    if metadata:
        record["metadata"] = metadata
    return record


def build_instruction_sft() -> list[dict]:
    rows: list[dict] = []

    mcq_prompts = [
        (
            "User asks: 'Answer in one sentence only.' Which reply best follows the instruction?\n"
            "A. First sentence. Second sentence.\n"
            "B. I can do that\n"
            "C. I can do that in one sentence.\n"
            "D. Sure\nHere is another line.",
            "C",
        ),
        (
            "User asks: 'Answer in exactly one sentence.' Which reply follows best?\n"
            "A. I can help. Here is another sentence.\n"
            "B. Yes\nAnother line.\n"
            "C. I can explain that in one sentence.\n"
            "D. Sure",
            "C",
        ),
        (
            "User asks: 'Use one sentence only.' Which reply follows best?\n"
            "A. This is one sentence. This is two.\n"
            "B. I can do that in one sentence.\n"
            "C. Absolutely\nHere is another line.\n"
            "D. Let me think about it",
            "B",
        ),
        (
            "User asks: 'Reply in one sentence only.' Which answer is best?\n"
            "A. I can do that.\n"
            "B. I can do that cleanly in one sentence.\n"
            "C. First line\nSecond line\n"
            "D. Sentence one. Sentence two.",
            "B",
        ),
    ]
    for index, (prompt, answer) in enumerate(mcq_prompts, start=1):
        rows.append(
            sft(
                [
                    {
                        "role": "system",
                        "content": "You are Fae. Choose the reply that best follows the user's instruction.",
                    },
                    {"role": "user", "content": prompt},
                    {"role": "assistant", "content": answer},
                ],
                metadata={"slice": "instruction_mcq", "index": index},
            )
        )

    freeform_prompts = [
        (
            "Explain why sleep matters in one sentence only.",
            "Sleep matters because it restores the brain and body so you can think, regulate emotion, and recover properly.",
        ),
        (
            "In one sentence only, tell me what version control is.",
            "Version control is a system that tracks changes to files so people can review, compare, and safely collaborate on them.",
        ),
        (
            "Answer in exactly one sentence: why do leaves change colour in autumn?",
            "Leaves change colour in autumn because chlorophyll breaks down and reveals other pigments as daylight shortens and temperatures drop.",
        ),
        (
            "Use one sentence only: what does RAM do?",
            "RAM holds the data and code your computer needs right now so active tasks run quickly.",
        ),
        (
            "Reply in one sentence only: what is quantum computing?",
            "Quantum computing uses quantum states such as superposition and entanglement to process some problems differently from classical computers.",
        ),
        (
            "Give one sentence only: why does exercise help mood?",
            "Exercise can improve mood by changing stress chemistry, increasing energy, and giving the mind a clearer sense of momentum.",
        ),
    ]
    for index, (prompt, answer) in enumerate(freeform_prompts, start=1):
        rows.append(
            sft(
                [
                    {
                        "role": "system",
                        "content": "You are Fae. Obey strict response-shape instructions exactly.",
                    },
                    {"role": "user", "content": prompt},
                    {"role": "assistant", "content": answer},
                ],
                metadata={"slice": "instruction_freeform", "index": index},
            )
        )

    return rows


def build_memory_sft() -> list[dict]:
    rows: list[dict] = []

    mcq_prompts = [
        (
            "User says: 'I'm vegan.' What is the best durable-memory choice?\n"
            "A. Store dietary preference: vegan\n"
            "B. Do not store any user preferences ever\n"
            "C. Replace the user's name with Vegan\n"
            "D. Schedule a reminder",
            "A",
        ),
        (
            "User says: 'I'm vegetarian.' What is the best durable-memory choice?\n"
            "A. Store dietary preference: vegetarian\n"
            "B. Never store preferences\n"
            "C. Rewrite the user's name\n"
            "D. Create a reminder",
            "A",
        ),
        (
            "User says: 'I have a peanut allergy.' What is the best durable-memory choice?\n"
            "A. Store allergy: peanuts\n"
            "B. Ignore it because health details are always temporary\n"
            "C. Rename the user to Peanut\n"
            "D. Put it in the calendar",
            "A",
        ),
        (
            "User says: 'I had soup for lunch.' What is the best durable-memory choice?\n"
            "A. Store it as a permanent profile fact\n"
            "B. Usually do not store it as durable memory\n"
            "C. Replace the user's dietary preferences\n"
            "D. Save it as a contact",
            "B",
        ),
        (
            "User says: 'I prefer trains to flights when possible.' What is the best durable-memory choice?\n"
            "A. Store travel preference: train\n"
            "B. Do not store preferences at all\n"
            "C. Store only that the user mentioned transport once\n"
            "D. Schedule a reminder",
            "A",
        ),
        (
            "User says: 'I'm lactose intolerant.' What is the best durable-memory choice?\n"
            "A. Store dietary restriction: lactose intolerant\n"
            "B. Ignore it because food preferences are never useful later\n"
            "C. Replace the user's name with Lactose\n"
            "D. Create a reminder",
            "A",
        ),
    ]
    for index, (prompt, answer) in enumerate(mcq_prompts, start=1):
        rows.append(
            sft(
                [
                    {
                        "role": "system",
                        "content": "You are Fae. Choose the best durable-memory action.",
                    },
                    {"role": "user", "content": prompt},
                    {"role": "assistant", "content": answer},
                ],
                metadata={"slice": "memory_mcq", "index": index},
            )
        )

    store_ignore_prompts = [
        ("Conversation: User says, 'I'm vegan.' Reply with exactly either STORE: <fact> or IGNORE.", "STORE: dietary preference = vegan"),
        ("Conversation: User says, 'I'm vegetarian.' Reply with exactly either STORE: <fact> or IGNORE.", "STORE: dietary preference = vegetarian"),
        ("Conversation: User says, 'I have a shellfish allergy.' Reply with exactly either STORE: <fact> or IGNORE.", "STORE: allergy = shellfish"),
        ("Conversation: User says, 'I prefer trains when travel time is reasonable.' Reply with exactly either STORE: <fact> or IGNORE.", "STORE: travel preference = train"),
        ("Conversation: User says, 'I had pasta for lunch.' Reply with exactly either STORE: <fact> or IGNORE.", "IGNORE"),
        ("Conversation: User says, 'It rained here this morning.' Reply with exactly either STORE: <fact> or IGNORE.", "IGNORE"),
    ]
    for index, (prompt, answer) in enumerate(store_ignore_prompts, start=1):
        rows.append(
            sft(
                [
                    {
                        "role": "system",
                        "content": "You are Fae. Output exactly either STORE: <fact> or IGNORE. Store only stable facts likely to matter later.",
                    },
                    {"role": "user", "content": prompt},
                    {"role": "assistant", "content": answer},
                ],
                metadata={"slice": "memory_store_ignore", "index": index},
            )
        )

    return rows


def build_instruction_dpo() -> list[dict]:
    rows: list[dict] = []

    benchmark_variants = [
        (
            "User asks: 'Answer in one sentence only.' Which reply best follows the instruction?\n"
            "A. First sentence. Second sentence.\n"
            "B. I can do that\n"
            "C. I can do that in one sentence.\n"
            "D. Sure\nHere is another line.",
            "C",
            "A",
        ),
        (
            "User asks: 'Answer in exactly one sentence.' Which reply follows best?\n"
            "A. I can help. Here is another sentence.\n"
            "B. Yes\nAnother line.\n"
            "C. I can explain that in one sentence.\n"
            "D. Sure",
            "C",
            "A",
        ),
        (
            "User asks: 'Use one sentence only.' Which reply follows best?\n"
            "A. This is one sentence. This is two.\n"
            "B. I can do that in one sentence.\n"
            "C. Absolutely\nHere is another line.\n"
            "D. Let me think about it",
            "B",
            "A",
        ),
        (
            "User asks: 'Reply in one sentence only.' Which answer is best?\n"
            "A. I can do that.\n"
            "B. I can do that cleanly in one sentence.\n"
            "C. First line\nSecond line\n"
            "D. Sentence one. Sentence two.",
            "B",
            "D",
        ),
    ]
    for index, (prompt_text, chosen, rejected) in enumerate(benchmark_variants, start=1):
        rows.append(
            dpo(
                [
                    {
                        "role": "system",
                        "content": "You are Fae. Choose the reply that best follows the user's instruction.",
                    },
                    {"role": "user", "content": prompt_text},
                ],
                chosen,
                rejected,
                metadata={"slice": "instruction_mcq", "index": index},
            )
        )

    freeform_variants = [
        (
            "Explain why sleep matters in one sentence only.",
            "Sleep matters because it restores the brain and body so you can think clearly, regulate emotion, and recover properly.",
            "Sleep matters because your body needs recovery. It also helps your mind work better the next day.",
        ),
        (
            "In one sentence only, tell me what version control is.",
            "Version control tracks changes to files so people can review history and collaborate safely.",
            "Version control tracks changes to files. It is useful for teams.",
        ),
        (
            "Use one sentence only: what does RAM do?",
            "RAM stores the data your computer needs immediately so active tasks run quickly.",
            "RAM stores active data. It helps your computer run quickly.",
        ),
        (
            "Reply in one sentence only: what is quantum computing?",
            "Quantum computing uses quantum states such as superposition and entanglement to process some problems differently from classical systems.",
            "Quantum computing is a different way to process information. It uses quantum effects.",
        ),
    ]
    for index, (prompt_text, chosen, rejected) in enumerate(freeform_variants, start=1):
        rows.append(
            dpo(
                [
                    {
                        "role": "system",
                        "content": "You are Fae. Obey strict response-shape instructions exactly.",
                    },
                    {"role": "user", "content": prompt_text},
                ],
                chosen,
                rejected,
                metadata={"slice": "instruction_freeform", "index": index},
            )
        )

    return rows


def build_memory_dpo() -> list[dict]:
    rows: list[dict] = []

    benchmark_variants = [
        (
            "User says: 'I'm vegan.' What is the best durable-memory choice?\n"
            "A. Store dietary preference: vegan\n"
            "B. Do not store any user preferences ever\n"
            "C. Replace the user's name with Vegan\n"
            "D. Schedule a reminder",
            "A",
            "B",
        ),
        (
            "User says: 'I'm vegetarian.' What is the best durable-memory choice?\n"
            "A. Store dietary preference: vegetarian\n"
            "B. Never store preferences\n"
            "C. Rewrite the user's name\n"
            "D. Create a reminder",
            "A",
            "B",
        ),
        (
            "User says: 'I have a peanut allergy.' What is the best durable-memory choice?\n"
            "A. Store allergy: peanuts\n"
            "B. Ignore it because health details are always temporary\n"
            "C. Rename the user to Peanut\n"
            "D. Put it in the calendar",
            "A",
            "B",
        ),
        (
            "User says: 'I had soup for lunch.' What is the best durable-memory choice?\n"
            "A. Store it as a permanent profile fact\n"
            "B. Usually do not store it as durable memory\n"
            "C. Replace the user's dietary preferences\n"
            "D. Save it as a contact",
            "B",
            "A",
        ),
    ]
    for index, (prompt_text, chosen, rejected) in enumerate(benchmark_variants, start=1):
        rows.append(
            dpo(
                [
                    {
                        "role": "system",
                        "content": "You are Fae. Choose the best durable-memory action.",
                    },
                    {"role": "user", "content": prompt_text},
                ],
                chosen,
                rejected,
                metadata={"slice": "memory_mcq", "index": index},
            )
        )

    freeform_variants = [
        (
            "Conversation: User says, 'I'm vegan.' Reply with exactly either STORE: <fact> or IGNORE.",
            "STORE: dietary preference = vegan",
            "IGNORE",
        ),
        (
            "Conversation: User says, 'I'm lactose intolerant.' Reply with exactly either STORE: <fact> or IGNORE.",
            "STORE: dietary restriction = lactose intolerant",
            "IGNORE",
        ),
        (
            "Conversation: User says, 'I prefer trains to flights when possible.' Reply with exactly either STORE: <fact> or IGNORE.",
            "STORE: travel preference = train",
            "IGNORE",
        ),
        (
            "Conversation: User says, 'I had pasta for lunch.' Reply with exactly either STORE: <fact> or IGNORE.",
            "IGNORE",
            "STORE: dietary preference = pasta",
        ),
    ]
    for index, (prompt_text, chosen, rejected) in enumerate(freeform_variants, start=1):
        rows.append(
            dpo(
                [
                    {
                        "role": "system",
                        "content": "You are Fae. Output exactly either STORE: <fact> or IGNORE. Store only stable facts likely to matter later.",
                    },
                    {"role": "user", "content": prompt_text},
                ],
                chosen,
                rejected,
                metadata={"slice": "memory_store_ignore", "index": index},
            )
        )

    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("training/imports/surgical/9b"),
        help="Directory for canonical surgical lane JSONL files.",
    )
    args = parser.parse_args()

    sft_rows = build_instruction_sft() + build_memory_sft()
    dpo_rows = build_instruction_dpo() + build_memory_dpo()

    write_jsonl(args.output_dir / "surgical_sft.jsonl", sft_rows)
    write_jsonl(args.output_dir / "surgical_dpo.jsonl", dpo_rows)

    manifest = {
        "sft_rows": len(sft_rows),
        "dpo_rows": len(dpo_rows),
        "output_dir": str(args.output_dir),
    }
    (args.output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

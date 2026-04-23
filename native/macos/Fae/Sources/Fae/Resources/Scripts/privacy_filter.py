#!/usr/bin/env python3
"""
Fae Privacy Filter — subprocess entry point
============================================
Runs OpenAI Privacy Filter (via Blaizzy/mlx-embeddings) on text, returns JSON
with PII spans and a redacted copy. Designed to be invoked from Swift via
`Process` the same way TrainingBridge invokes mlx-tune.

Usage:
    # One-shot: pass text via argv
    uv run --no-project --with 'mlx-embeddings @ git+https://github.com/Blaizzy/mlx-embeddings' \\
        python3 scripts/privacy_filter.py --text "My email is alice@example.com"

    # Read from stdin (preferred for larger text or pipe)
    echo "Ring me on 555-1234" | python3 scripts/privacy_filter.py --stdin

    # Read from file
    python3 scripts/privacy_filter.py --file conversation.txt

    # Daemon mode — reads one JSON line per request, writes one JSON line per
    # response. Avoids model-load cost for batched calls.
    python3 scripts/privacy_filter.py --daemon

Output schema (one JSON object per request, written to stdout):
    {
      "text": "My email is alice@example.com",
      "spans": [
        {"category": "private_email", "text": "alice@example.com",
         "start": 12, "end": 29, "token_start": 3, "token_end": 7}
      ],
      "redacted": "My email is [PRIVATE_EMAIL]",
      "has_pii": true,
      "elapsed_ms": 47
    }

Exit codes:
    0  success
    1  bad arguments / empty input
    2  model load / inference failure
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from itertools import groupby
from typing import Iterable


MODEL_ID = "openai/privacy-filter"


def _load_model(model_id: str = MODEL_ID):
    import mlx.core as mx
    from mlx_embeddings.utils import load
    model, tokenizer = load(model_id)
    return model, tokenizer, mx


def _entity_of(label: str) -> str | None:
    """Map BIOES label like 'B-private_email' -> 'private_email'. 'O' -> None."""
    if label == "O":
        return None
    return label.split("-", 1)[-1] if "-" in label else label


def classify(model, tokenizer, mx, text: str) -> dict:
    """Run the model on `text`, return span + redaction results."""
    start = time.time()
    # offset_mapping gives per-token char spans so we can reconstruct exact
    # substrings from the original text (no detokenization artefacts).
    enc = tokenizer(
        text,
        return_tensors="mlx",
        return_offsets_mapping=True,
    )
    input_ids = enc["input_ids"]
    attention_mask = enc["attention_mask"]
    offsets = enc["offset_mapping"][0].tolist()

    outputs = model(input_ids, attention_mask=attention_mask)
    preds = mx.argmax(outputs.logits, axis=-1)[0].tolist()

    id2label = model.config.id2label
    # id2label keys can be int or str depending on how config was decoded —
    # normalise once.
    def label(pred_id: int) -> str:
        return id2label.get(pred_id) or id2label.get(str(pred_id)) or "O"

    spans: list[dict] = []
    tok_idx = 0
    for entity, group in groupby(
        ((tid, pred, offsets[i], i) for i, (tid, pred) in enumerate(zip(input_ids[0].tolist(), preds))),
        key=lambda x: _entity_of(label(x[1])),
    ):
        group_list = list(group)
        if entity is None:
            tok_idx += len(group_list)
            continue
        # Skip padding / special tokens (offset (0,0) after first token).
        char_spans = [(o[0], o[1]) for _, _, o, _ in group_list if not (o[0] == 0 and o[1] == 0)]
        if not char_spans:
            tok_idx += len(group_list)
            continue
        start_char = char_spans[0][0]
        end_char = char_spans[-1][1]
        # BPE tokenizers fold leading whitespace into the token — trim it off
        # the span so redacted text retains the original spacing.
        raw = text[start_char:end_char]
        lstrip = len(raw) - len(raw.lstrip())
        rstrip = len(raw) - len(raw.rstrip())
        start_char += lstrip
        end_char -= rstrip
        spans.append({
            "category": entity,
            "text": text[start_char:end_char],
            "start": start_char,
            "end": end_char,
            "token_start": group_list[0][3],
            "token_end": group_list[-1][3] + 1,
        })
        tok_idx += len(group_list)

    # Build redacted copy by replacing spans back-to-front so offsets stay valid.
    redacted_chars = list(text)
    for span in sorted(spans, key=lambda s: s["start"], reverse=True):
        placeholder = f"[{span['category'].upper()}]"
        redacted_chars[span["start"]:span["end"]] = list(placeholder)
    redacted = "".join(redacted_chars)

    return {
        "text": text,
        "spans": spans,
        "redacted": redacted,
        "has_pii": len(spans) > 0,
        "elapsed_ms": int((time.time() - start) * 1000),
    }


def _iter_inputs(args) -> Iterable[tuple[str, str | None]]:
    """Yield (text, request_id) pairs based on CLI args."""
    if args.text is not None:
        yield args.text, None
        return
    if args.file:
        with open(args.file, encoding="utf-8") as f:
            yield f.read(), None
        return
    if args.stdin:
        data = sys.stdin.read()
        if data:
            yield data, None
        return
    if args.daemon:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError as exc:
                json.dump({"error": f"bad json: {exc}"}, sys.stdout)
                sys.stdout.write("\n")
                sys.stdout.flush()
                continue
            yield req.get("text", ""), req.get("id")
        return


def main() -> int:
    parser = argparse.ArgumentParser(description="Fae Privacy Filter (mlx-embeddings)")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--text", type=str, help="Inline text to classify")
    src.add_argument("--file", type=str, help="Path to text file")
    src.add_argument("--stdin", action="store_true", help="Read full stdin as one input")
    src.add_argument("--daemon", action="store_true",
                     help="JSON-line protocol: one request/response per line on stdin/stdout")
    parser.add_argument("--model", default=MODEL_ID, help=f"HF model id (default: {MODEL_ID})")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    args = parser.parse_args()

    try:
        model, tokenizer, mx = _load_model(args.model)
    except Exception as exc:
        print(json.dumps({"error": f"load failed: {type(exc).__name__}: {exc}"}), file=sys.stderr)
        return 2

    any_input = False
    for text, req_id in _iter_inputs(args):
        any_input = True
        if not text:
            out = {"error": "empty input"}
        else:
            try:
                out = classify(model, tokenizer, mx, text)
            except Exception as exc:
                out = {"error": f"inference failed: {type(exc).__name__}: {exc}"}
        if req_id is not None:
            out["id"] = req_id
        if args.pretty and not args.daemon:
            json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
            sys.stdout.write("\n")
        else:
            json.dump(out, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
        sys.stdout.flush()

    if not any_input:
        print(json.dumps({"error": "no input provided"}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

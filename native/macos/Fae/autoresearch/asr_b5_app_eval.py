# /// script
# requires-python = ">=3.11"
# dependencies = ["soundfile"]
# ///
"""B5 full-app audio-in evaluator.

Drives WAV clips through the real Fae TestServer audio path:

    POST /command {"name":"test.inject_audio","payload":{"path":"/abs/clip.wav"}}

and captures the final `PTT [heard]: ...` debug event emitted after
`TextProcessing.correctNameRecognition` + `DynamicVocabularyCorrector` have run
inside `PipelineCoordinator`.

This is the acceptance-style measurement missing from the daemon-only evaluator.
Launch Fae first with the test server enabled (prefer dev isolation):

    # optional: seed dev dynamic-vocab file before launching Fae
    uv run autoresearch/asr_b5_app_eval.py --seed-dev-vocab --seed-only

    # then launch a bundled/dev app with FAE_DEV=1 and --test-server
    # e.g. build/sign as usual, then open Fae.app with --env FAE_DEV=1 --args --test-server

    uv run autoresearch/asr_b5_app_eval.py --corpus autoresearch/asr_corpus
"""
from __future__ import annotations

import argparse
import json
import os
import re
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import soundfile as sf

RELIABILITY_BAR = {
    "overall_wer_max": 0.20,
    "clean_wer_max": 0.10,
    "vocab_exact_min": 0.90,
    "catastrophic_garbles_max": 0,
}

SEED_ENTRIES = [
    {"canonical": "David", "variants": ["dayed", "daved", "devid", "david"], "source": "b5_app_eval"},
    {"canonical": "Sarah", "variants": ["sarah", "sara", "sar", "ser", "zara"], "source": "b5_app_eval"},
    {"canonical": "James", "variants": ["james", "jaymes"], "source": "b5_app_eval"},
    {"canonical": "GitHub", "variants": ["github", "git hub", "get hub"], "source": "b5_app_eval"},
    {"canonical": "Fae", "variants": ["fay", "faye", "fey", "faith", "phase"], "source": "b5_app_eval"},
]


@dataclass
class ClipResult:
    clip: str
    category: str
    expected: str
    heard: str
    wer: float
    exact: bool
    duration_s: float
    elapsed_ms: float
    event_seq: int | None = None
    error: str | None = None


@dataclass
class EvalResult:
    timestamp: str
    source: str
    corpus_dir: str
    reliability_bar: dict[str, float | int]
    clips: list[ClipResult] = field(default_factory=list)
    overall_wer: float = 0.0
    exact_match_rate: float = 0.0
    clean_wer: float | None = None
    vocab_exact_rate: float | None = None
    catastrophic_garbles: int = 0
    passes_bar: bool = False
    notes: list[str] = field(default_factory=list)


def app_support_root(dev: bool) -> Path:
    return Path.home() / "Library" / "Application Support" / ("fae-dev" if dev else "fae")


def seed_vocab(dev: bool, controlled: bool = False) -> Path:
    root = app_support_root(dev)
    root.mkdir(parents=True, exist_ok=True)
    path = root / "personal_lexicon.json"
    existing: list[dict[str, Any]] = []
    if path.exists() and not controlled:
        try:
            existing = json.loads(path.read_text())
        except Exception:
            backup = path.with_suffix(f".json.broken.{int(time.time())}")
            path.rename(backup)
            existing = []
    by_key = {str(e.get("canonical", "")).lower(): e for e in existing if isinstance(e, dict)}
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for seed in SEED_ENTRIES:
        key = seed["canonical"].lower()
        variants = [v for v in seed["variants"] if v.lower() != key]
        if key in by_key:
            entry = by_key[key]
            seen = {str(v).lower() for v in entry.get("variants", [])}
            for variant in variants:
                if variant.lower() not in seen:
                    entry.setdefault("variants", []).append(variant)
                    seen.add(variant.lower())
            entry["updatedAt"] = now
        else:
            by_key[key] = {
                "canonical": seed["canonical"],
                "variants": variants,
                "source": seed["source"],
                "createdAt": now,
                "updatedAt": now,
            }
    merged = sorted(by_key.values(), key=lambda e: str(e.get("canonical", "")).lower())
    path.write_text(json.dumps(merged, indent=2, sort_keys=True))
    return path


class TestServerClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None, timeout: float = 30.0) -> dict[str, Any]:
        data = None
        headers = {}
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = response.read().decode()
        return json.loads(body) if body else {}

    def health(self) -> dict[str, Any]:
        return self.request("GET", "/health", timeout=5)

    def reset(self) -> dict[str, Any]:
        return self.request("POST", "/reset", {}, timeout=120)

    def command(self, name: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self.request("POST", "/command", {"name": name, "payload": payload}, timeout=30)

    def events(self, since: int = 0) -> dict[str, Any]:
        return self.request("GET", f"/events?since={since}", timeout=10)

    def conversation(self) -> dict[str, Any]:
        return self.request("GET", "/conversation", timeout=10)

    def cancel(self) -> None:
        try:
            self.request("POST", "/cancel", {}, timeout=30)
        except Exception:
            pass


def norm_words(text: str) -> list[str]:
    normalized = re.sub(r"[^\w\s']", " ", text.lower())
    return re.sub(r"\s+", " ", normalized).strip().split()


def wer(reference: str, hypothesis: str) -> float:
    ref = norm_words(reference)
    hyp = norm_words(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    dp = [[0] * (len(hyp) + 1) for _ in range(len(ref) + 1)]
    for i in range(len(ref) + 1):
        dp[i][0] = i
    for j in range(len(hyp) + 1):
        dp[0][j] = j
    for i, r in enumerate(ref, 1):
        for j, h in enumerate(hyp, 1):
            dp[i][j] = min(
                dp[i - 1][j] + 1,
                dp[i][j - 1] + 1,
                dp[i - 1][j - 1] + (0 if r == h else 1),
            )
    return dp[-1][-1] / len(ref)


def exact(reference: str, hypothesis: str) -> bool:
    return norm_words(reference) == norm_words(hypothesis)


def infer_category(path: Path) -> str:
    prefix = path.stem.split("_", 1)[0]
    if prefix in {"greeting", "command", "question", "short"}:
        return "clean"
    if prefix in {"name", "tech", "number", "spell"}:
        return "vocab"
    if prefix in {"dvc"}:
        return "dvc_guard"
    if prefix in {"casual", "conv"}:
        return "spontaneous"
    if prefix in {"noisy", "noise"}:
        return "noisy"
    if prefix in {"accent", "accented"}:
        return "accented"
    if prefix in {"garbled", "silence", "empty"}:
        return "degraded"
    return prefix


def load_corpus(corpus: Path) -> list[tuple[Path, str, str]]:
    pairs = []
    for wav in sorted(corpus.glob("*.wav")):
        txt = wav.with_suffix(".txt")
        if not txt.exists():
            print(f"SKIP {wav.name}: no matching .txt")
            continue
        expected = txt.read_text().strip()
        if expected:
            pairs.append((wav, expected, infer_category(wav)))
    return pairs


def extract_heard(events: list[dict[str, Any]]) -> tuple[str, int] | None:
    for event in events:
        text = str(event.get("text", ""))
        marker = "PTT [heard]:"
        if marker in text:
            heard = text.split(marker, 1)[1].strip()
            return heard, int(event.get("seq", -1))
    return None


def wait_for_final_heard(client: TestServerClient, since: int, timeout_s: float) -> tuple[str, int]:
    deadline = time.monotonic() + timeout_s
    last_since = since
    last_heard: tuple[str, int] | None = None
    heard_at: float | None = None
    while time.monotonic() < deadline:
        data = client.events(last_since)
        events = data.get("events", [])
        found = extract_heard(events)
        if found:
            last_heard = found
            heard_at = time.monotonic()
        last_since = int(data.get("total", last_since))
        if last_heard and heard_at and (time.monotonic() - heard_at) >= 1.0:
            return last_heard
        time.sleep(0.5)
    raise TimeoutError(f"timed out waiting for final PTT [heard] after event {since}")


def run_clip(client: TestServerClient, wav: Path, expected: str, category: str, timeout_s: float) -> ClipResult:
    client.reset()
    start_events = int(client.events(0).get("total", 0))
    start = time.perf_counter()
    client.command("test.inject_audio", {"path": str(wav.resolve())})
    heard, seq = wait_for_final_heard(client, start_events, timeout_s)
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    client.cancel()
    return ClipResult(
        clip=wav.name,
        category=category,
        expected=expected,
        heard=heard,
        wer=wer(expected, heard),
        exact=exact(expected, heard),
        duration_s=sf.info(str(wav)).duration,
        elapsed_ms=elapsed_ms,
        event_seq=seq,
    )


def summarize(result: EvalResult) -> None:
    good = [c for c in result.clips if c.error is None]
    if not good:
        return
    result.overall_wer = sum(c.wer for c in good) / len(good)
    result.exact_match_rate = sum(1 for c in good if c.exact) / len(good)
    clean = [c for c in good if c.category == "clean"]
    vocab = [c for c in good if c.category == "vocab"]
    if clean:
        result.clean_wer = sum(c.wer for c in clean) / len(clean)
    if vocab:
        result.vocab_exact_rate = sum(1 for c in vocab if c.exact) / len(vocab)
    result.catastrophic_garbles = sum(
        1 for c in good if c.heard == "(unclear audio)" or "didn't catch" in c.heard.lower()
    )
    result.passes_bar = (
        result.overall_wer <= RELIABILITY_BAR["overall_wer_max"]
        and (result.clean_wer is not None and result.clean_wer <= RELIABILITY_BAR["clean_wer_max"])
        and (result.vocab_exact_rate is not None and result.vocab_exact_rate >= RELIABILITY_BAR["vocab_exact_min"])
        and result.catastrophic_garbles <= RELIABILITY_BAR["catastrophic_garbles_max"]
    )


def write_outputs(result: EvalResult, output_dir: Path) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    json_path = output_dir / f"b5_asr_app_{ts}.json"
    md_path = output_dir / f"b5_asr_app_{ts}.md"
    json_path.write_text(json.dumps(asdict(result), indent=2))
    lines = [
        f"# B5 Full-App ASR Evaluation — {ts}", "",
        f"**Source**: {result.source}",
        f"**Corpus**: `{result.corpus_dir}` ({len(result.clips)} clips)", "",
        "## Summary", "",
        f"- Overall WER: **{result.overall_wer:.1%}**",
        f"- Exact-match: **{result.exact_match_rate:.1%}**",
        f"- Clean WER: **{result.clean_wer:.1%}**" if result.clean_wer is not None else "- Clean WER: n/a",
        f"- Vocab exact-match: **{result.vocab_exact_rate:.1%}**" if result.vocab_exact_rate is not None else "- Vocab exact-match: n/a",
        f"- Safe re-ask / quality-gate transcripts: **{result.catastrophic_garbles}**",
        f"- Decision against bar: **{'PASS' if result.passes_bar else 'FAIL'}**", "",
    ]
    if result.notes:
        lines += ["## Notes", ""] + [f"- {note}" for note in result.notes] + [""]
    lines += [
        "## Per-clip table", "",
        "| Clip | Category | Expected | Final app `[heard]` | WER | Exact | ms |",
        "|------|----------|----------|---------------------|-----|-------|----|",
    ]
    for c in result.clips:
        heard = c.heard.replace("|", "\\|") if c.heard else ""
        expected = c.expected.replace("|", "\\|")
        quality = f"ERROR: {c.error}" if c.error else f"{c.elapsed_ms:.0f}"
        lines.append(
            f"| {c.clip} | {c.category} | {expected} | {heard} | {c.wer:.1%} | {'yes' if c.exact else 'no'} | {quality} |"
        )
    md_path.write_text("\n".join(lines))
    return json_path, md_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure final full-app post-correction [heard] via TestServer audio injection")
    parser.add_argument("--base-url", default="http://127.0.0.1:7433")
    parser.add_argument("--corpus", type=Path, default=Path("autoresearch/asr_corpus"))
    parser.add_argument("--output-dir", type=Path, default=Path("autoresearch/results"))
    parser.add_argument("--timeout-s", type=float, default=180.0)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--dev", action="store_true", default=True, help="Seed fae-dev lexicon (default)")
    parser.add_argument("--prod", action="store_true", help="Seed production fae lexicon instead of fae-dev")
    parser.add_argument("--seed-dev-vocab", action="store_true", help="Merge B5 name/entity vocabulary into personal_lexicon.json before app launch")
    parser.add_argument("--controlled-vocab", action="store_true", help="Replace personal_lexicon.json with only the B5 seed entries (useful for reproducible measurement without harvested-contact false positives)")
    parser.add_argument("--seed-only", action="store_true")
    args = parser.parse_args()

    dev = not args.prod
    if args.seed_dev_vocab or args.seed_only:
        path = seed_vocab(dev=dev, controlled=args.controlled_vocab)
        print(f"Seeded vocabulary: {path}")
        if args.seed_only:
            return 0

    corpus = load_corpus(args.corpus)
    if args.limit > 0:
        corpus = corpus[:args.limit]
    if not corpus:
        raise SystemExit(f"No WAV/TXT pairs found in {args.corpus}")

    client = TestServerClient(args.base_url)
    try:
        health = client.health()
    except urllib.error.URLError as exc:
        raise SystemExit(f"TestServer not reachable at {args.base_url}: {exc}")
    print(f"Health: {health}")

    result = EvalResult(
        timestamp=datetime.now(timezone.utc).isoformat(),
        source="Fae TestServer test.inject_audio → PipelineCoordinator final PTT [heard] event",
        corpus_dir=str(args.corpus),
        reliability_bar=RELIABILITY_BAR.copy(),
        notes=[
            "Measures final app [heard] after TextProcessing.correctNameRecognition + DynamicVocabularyCorrector.",
            f"Vocabulary seed target: {'fae-dev' if dev else 'fae'} personal_lexicon.json.",
        ],
    )

    for wav, expected, category in corpus:
        try:
            clip = run_clip(client, wav, expected, category, args.timeout_s)
            result.clips.append(clip)
            print(f"{wav.name}: {clip.heard!r} WER={clip.wer:.1%}")
        except Exception as exc:
            print(f"{wav.name}: ERROR {exc}")
            try:
                duration = sf.info(str(wav)).duration
            except Exception:
                duration = 0.0
            result.clips.append(ClipResult(
                clip=wav.name,
                category=category,
                expected=expected,
                heard="",
                wer=1.0,
                exact=False,
                duration_s=duration,
                elapsed_ms=0.0,
                error=str(exc),
            ))
            client.cancel()
    summarize(result)
    json_path, md_path = write_outputs(result, args.output_dir)
    print(f"JSON: {json_path}")
    print(f"Markdown: {md_path}")
    print(f"Decision against bar: {'PASS' if result.passes_bar else 'FAIL'}")
    return 0 if result.passes_bar else 2


if __name__ == "__main__":
    raise SystemExit(main())

# /// script
# requires-python = ">=3.11"
# dependencies = ["soundfile"]
# ///
"""B5 audio-in reliability evaluator for Fae's Gemma/mmproj daemon path.

Measures WER/exact-match on the daemon ASR transcript after static [heard]
post-correction. Default mode talks to an already-running fae-daemon over the control-plane socket
and sends each WAV as the pass-1 transcription turn used by DaemonLLMEngine.

Usage:
    # 1) Launch Fae/dev daemon first (for example: source ~/.secrets && just run-dev)
    # 2) Run the corpus measurement:
    uv run autoresearch/asr_b5_eval.py --corpus autoresearch/asr_corpus

The script writes JSON + Markdown tables to autoresearch/results/. It also applies
Fae's static [heard] correction layer (Fae/name + command phrase fixes) and the
same conservative degraded-path quality gate used by DaemonLLMEngine, so the
reported hypothesis is the daemon pass-1 transcript after static correction. The
full app path can add dynamic owner/entity vocabulary correction on top.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import socket
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import soundfile as sf

PROTOCOL_VERSION = 2
CLIENT_ID = "swift-frontend-bootstrap"
TRANSCRIBE_SYSTEM_PROMPT = (
    "Transcribe the user's audio verbatim. Output only the exact words spoken — no "
    "labels, quotation marks, preamble, commentary, summaries, or answers. If the "
    "user asks a question, transcribe the question words; never answer it. If "
    "nothing is said, output nothing."
)

# Must stay in sync with TextProcessing.correctNameRecognition's static layer.
NAME_CORRECTIONS = [
    ("hey, check", "Fae, check"), ("hey, tell", "Fae, tell"),
    ("hey, what", "Fae, what"), ("hey, who", "Fae, who"),
    ("hey, when", "Fae, when"), ("hey, where", "Fae, where"),
    ("hey, show", "Fae, show"), ("hey, set", "Fae, set"),
    ("hey, remind", "Fae, remind"), ("hey, remember", "Fae, remember"),
    ("hey, search", "Fae, search"), ("hey, create", "Fae, create"),
    ("hey, make", "Fae, make"), ("hey, run", "Fae, run"),
    ("hey, hello", "Fae, hello"), ("hey, good", "Fae, good"),
    ("hey, how", "Fae, how"),
    ("hi fae", "Hi Fae"), ("hey fae", "Hey Fae"),
    ("high fay", "Hi Fae"), ("high fae", "Hi Fae"),
    ("high faith", "Hi Fae"), ("hi faith", "Hi Fae"),
    ("hey faith", "Hey Fae"), ("hi phase", "Hi Fae"),
    ("hey phase", "Hey Fae"), ("hi faye", "Hi Fae"),
    ("hey faye", "Hey Fae"), ("hi fay", "Hi Fae"),
    ("hey fay", "Hey Fae"), ("hey fag", "Hey Fae"),
    ("hi fag", "Hi Fae"), ("i fae", "Hi Fae"),
    ("i fay", "Hi Fae"), ("i faye", "Hi Fae"),
    ("fag", "Fae"), ("ife", "Fae"), ("ifae", "Fae"),
    ("ifay", "Fae"), ("phase", "Fae"), ("faye", "Fae"),
    ("fay", "Fae"), ("fey", "Fae"), ("fea", "Fae"),
    ("fah", "Fae"), ("feh", "Fae"), ("fei", "Fae"),
    ("fae's", "Fae's"), ("ivie", "Fae"), ("fay.", "Fae."),
    ("fey.", "Fae."),
]
COMMAND_CORRECTIONS = [
    ("the law reminds us", "clear all reminders"),
    ("the law reminders", "clear all reminders"),
    ("the law remind us", "clear all reminders"),
    ("dealer reminders", "clear all reminders"),
    ("de la reminders", "clear all reminders"),
    ("dealer reminds", "clear all reminders"),
    ("marco, my reminder", "mark all my reminders"),
    ("marco my reminder", "mark all my reminders"),
    ("marco, my reminders", "mark all my reminders"),
    ("marco my reminders", "mark all my reminders"),
    ("marco reminders", "mark all reminders"),
    ("marco, reminder", "mark all reminders"),
    ("marco reminder", "mark all reminders"),
    ("mark or my reminder", "mark all my reminders"),
    ("mark or reminders", "mark all reminders"),
]

RELIABILITY_BAR = {
    "overall_wer_max": 0.20,
    "clean_wer_max": 0.10,
    "vocab_exact_min": 0.90,
    "catastrophic_garbles_max": 0,
}


@dataclass
class ClipResult:
    clip: str
    category: str
    expected: str
    raw_heard: str
    corrected_heard: str
    wer: float
    exact: bool
    duration_s: float
    decode_ms: float
    quality_usable: bool
    quality_reason: str | None = None
    error: str | None = None


@dataclass
class EvalResult:
    timestamp: str
    engine: str
    corpus_dir: str
    reliability_bar: dict[str, float | int]
    clips: list[ClipResult] = field(default_factory=list)
    overall_wer: float = 0.0
    exact_match_rate: float = 0.0
    clean_wer: float | None = None
    vocab_exact_rate: float | None = None
    catastrophic_garbles: int = 0
    passes_bar: bool = False
    coverage_warnings: list[str] = field(default_factory=list)


class Client:
    def __init__(self, socket_path: Path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(1800)
        self.sock.connect(str(socket_path))
        self.file = self.sock.makefile("rwb", buffering=0)
        self.next_id = 1

    def command(self, command: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        request_id = f"r{self.next_id}"
        self.next_id += 1
        frame = {
            "v": PROTOCOL_VERSION,
            "request_id": request_id,
            "command": command,
            "payload": payload or {},
        }
        self.sock.sendall((json.dumps(frame) + "\n").encode())
        line = self.file.readline()
        if not line:
            raise RuntimeError("daemon closed socket")
        return json.loads(line)


def run_dir(home: Path) -> Path:
    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / "fae" / "run"
    data_home = Path(os.environ.get("XDG_DATA_HOME", home / ".local" / "share"))
    return data_home / "fae" / "run"


def require_ok(response: dict[str, Any]) -> dict[str, Any]:
    if not response.get("ok"):
        raise RuntimeError(json.dumps(response, sort_keys=True))
    return response.get("result") or {}


def flatten_transcript(raw: str) -> str:
    text = raw.strip()
    if text.lower().startswith("[heard]:"):
        text = text[len("[heard]:"):].strip()
    return " ".join(text.splitlines()).strip()


def replace_once_word_boundary(text: str, pattern: str, replacement: str) -> str:
    lower = text.lower()
    idx = lower.find(pattern)
    if idx < 0:
        return text
    before_ok = idx == 0 or not lower[idx - 1].isalnum()
    end = idx + len(pattern)
    after_ok = end == len(lower) or not lower[end:end + 1].isalnum()
    if not (before_ok and after_ok):
        return text
    return text[:idx] + replacement + text[end:]


def post_correct(text: str) -> str:
    result = text
    lower = result.lower()
    for pattern, replacement in COMMAND_CORRECTIONS:
        idx = lower.find(pattern)
        if idx >= 0:
            result = result[:idx] + replacement + result[idx + len(pattern):]
            break
    for pattern, replacement in NAME_CORRECTIONS:
        changed = replace_once_word_boundary(result, pattern, replacement)
        if changed != result:
            result = changed
            break
    return result.strip()


def assess_quality(transcript: str) -> tuple[bool, str | None]:
    text = transcript.strip()
    if not text:
        return False, "empty"
    lower = text.lower()
    if len(lower) > 300:
        return False, "runaway_transcript"
    if any(fragment in lower for fragment in [
        "<tool", "</tool", "<think", "</think", "function_call", "tool_call",
        "{\"name\"", "{\"arguments\"", "[audio", "[inaudible]",
    ]):
        return False, "model_markup"
    if any(fragment in lower for fragment in [
        "inaudible", "unintelligible", "no speech", "nothing was said",
        "silent audio", "silence", "can't hear", "cannot hear",
        "can't transcribe", "cannot transcribe", "unable to transcribe",
        "no audio", "empty audio",
    ]):
        return False, "no_speech_marker"
    if lower.startswith(("sorry", "i'm sorry", "i am sorry", "i can't", "i cannot")) and any(
        marker in lower for marker in ["audio", "hear", "transcribe", "understand"]
    ):
        return False, "model_apology"
    chars = [ch for ch in text if not ch.isspace()]
    if len(chars) >= 8 and sum(ch.isalnum() for ch in chars) / len(chars) < 0.35:
        return False, "low_alphanumeric_ratio"
    letters = [ch for ch in text if ch.isalpha()]
    non_latin = [ch for ch in letters if ord(ch) > 127 and not (0x00C0 <= ord(ch) <= 0x024F)]
    if letters and len(non_latin) / len(letters) >= 0.4:
        return False, "non_latin_transcript"
    tokens = re.findall(r"[\w']+", lower)
    short_allowlist = {
        "a", "i", "ok", "okay", "yes", "yeah", "yep", "no", "nope", "stop",
        "hi", "hey", "hello", "bye", "fae", "thanks", "set", "run", "call",
        "open", "close", "play", "pause",
    }
    if len(tokens) == 1 and len(tokens[0]) <= 3 and tokens[0] not in short_allowlist:
        return False, "short_fragment"
    if len(tokens) >= 8 and len(set(tokens)) / len(tokens) < 0.25:
        return False, "low_unique_token_ratio"
    run = 0
    previous = None
    for token in tokens:
        run = run + 1 if token == previous else 1
        previous = token
        if run >= 5:
            return False, "repeated_token_run"
    return True, None


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
    stem = path.stem
    prefix = stem.split("_", 1)[0]
    if prefix in {"greeting", "command", "question", "short"}:
        return "clean"
    if prefix in {"name", "tech", "number", "spell"}:
        return "vocab"
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
            print(f"SKIP {wav.name}: missing .txt", file=sys.stderr)
            continue
        expected = txt.read_text().strip()
        if not expected:
            print(f"SKIP {wav.name}: empty .txt", file=sys.stderr)
            continue
        pairs.append((wav, expected, infer_category(wav)))
    return pairs


def transcribe_daemon(client: Client, wav: Path, max_tokens: int) -> tuple[str, float]:
    wav_b64 = base64.b64encode(wav.read_bytes()).decode()
    start = time.perf_counter()
    result = require_ok(client.command("conversation.inject_text", {
        "system": TRANSCRIBE_SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": "", "audio_wav_base64": wav_b64}],
        "max_tokens": max_tokens,
    }))
    elapsed = (time.perf_counter() - start) * 1000.0
    return flatten_transcript(result.get("text", "")), elapsed


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
    result.catastrophic_garbles = sum(1 for c in good if not c.quality_usable)
    result.passes_bar = (
        result.overall_wer <= RELIABILITY_BAR["overall_wer_max"]
        and (result.clean_wer is not None and result.clean_wer <= RELIABILITY_BAR["clean_wer_max"])
        and (result.vocab_exact_rate is not None and result.vocab_exact_rate >= RELIABILITY_BAR["vocab_exact_min"])
        and result.catastrophic_garbles <= RELIABILITY_BAR["catastrophic_garbles_max"]
    )
    categories = {c.category for c in good}
    for required in ["clean", "noisy", "accented", "spontaneous", "vocab"]:
        if required not in categories:
            result.coverage_warnings.append(f"missing {required} clips")


def write_outputs(result: EvalResult, output_dir: Path) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    json_path = output_dir / f"b5_asr_gemma_{ts}.json"
    md_path = output_dir / f"b5_asr_gemma_{ts}.md"
    json_path.write_text(json.dumps(asdict(result), indent=2))

    lines = [
        f"# B5 Gemma/mmproj ASR Evaluation — {ts}", "",
        f"**Engine**: {result.engine}",
        f"**Corpus**: `{result.corpus_dir}` ({len(result.clips)} clips)", "",
        "## Reliability bar", "",
        f"- Overall WER ≤ {RELIABILITY_BAR['overall_wer_max']:.0%}",
        f"- Clean WER ≤ {RELIABILITY_BAR['clean_wer_max']:.0%}",
        f"- Fae-vocab exact-match ≥ {RELIABILITY_BAR['vocab_exact_min']:.0%}",
        f"- Catastrophic/quality-gate garbles = {RELIABILITY_BAR['catastrophic_garbles_max']}", "",
        "## Summary", "",
        f"- Overall WER: **{result.overall_wer:.1%}**",
        f"- Exact-match: **{result.exact_match_rate:.1%}**",
        f"- Clean WER: **{result.clean_wer:.1%}**" if result.clean_wer is not None else "- Clean WER: n/a",
        f"- Vocab exact-match: **{result.vocab_exact_rate:.1%}**" if result.vocab_exact_rate is not None else "- Vocab exact-match: n/a",
        f"- Catastrophic/quality-gate garbles: **{result.catastrophic_garbles}**",
        f"- Decision against bar: **{'PASS' if result.passes_bar else 'FAIL'}**", "",
    ]
    if result.coverage_warnings:
        lines += ["## Coverage warnings", ""] + [f"- {w}" for w in result.coverage_warnings] + [""]
    lines += [
        "## Per-clip table", "",
        "| Clip | Category | Expected | Final [heard] | WER | Exact | Quality | ms |",
        "|------|----------|----------|---------------|-----|-------|---------|----|",
    ]
    for c in result.clips:
        quality = "ok" if c.quality_usable else f"reject:{c.quality_reason}"
        if c.error:
            quality = f"ERROR: {c.error}"
        lines.append(
            f"| {c.clip} | {c.category} | {c.expected} | {c.corrected_heard} | "
            f"{c.wer:.1%} | {'yes' if c.exact else 'no'} | {quality} | {c.decode_ms:.0f} |"
        )
    md_path.write_text("\n".join(lines))
    return json_path, md_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure B5 Gemma/mmproj ASR reliability")
    parser.add_argument("--corpus", type=Path, default=Path("autoresearch/asr_corpus"))
    parser.add_argument("--output-dir", type=Path, default=Path("autoresearch/results"))
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    corpus = load_corpus(args.corpus)
    if args.limit > 0:
        corpus = corpus[:args.limit]
    if not corpus:
        raise SystemExit(f"No WAV/TXT pairs found in {args.corpus}")

    rd = run_dir(args.home.expanduser())
    token_path = rd / "bootstrap.token"
    socket_path = rd / "fae-daemon.sock"
    if not token_path.exists() or not socket_path.exists():
        raise SystemExit(f"No running daemon socket/token at {rd}; launch Fae/dev daemon first")
    token = token_path.read_text().strip()
    client = Client(socket_path)
    require_ok(client.command("session.authenticate", {"client_id": CLIENT_ID, "token": token}))

    result = EvalResult(
        timestamp=datetime.now(timezone.utc).isoformat(),
        engine="fae-daemon llama.cpp Gemma/mmproj pass-1",
        corpus_dir=str(args.corpus),
        reliability_bar=RELIABILITY_BAR.copy(),
    )
    for wav, expected, category in corpus:
        try:
            raw, decode_ms = transcribe_daemon(client, wav, args.max_tokens)
            corrected = post_correct(raw)
            usable, reason = assess_quality(corrected)
            result.clips.append(ClipResult(
                clip=wav.name,
                category=category,
                expected=expected,
                raw_heard=raw,
                corrected_heard=corrected,
                wer=wer(expected, corrected),
                exact=exact(expected, corrected),
                duration_s=sf.info(str(wav)).duration,
                decode_ms=decode_ms,
                quality_usable=usable,
                quality_reason=reason,
            ))
            print(f"{wav.name}: {corrected!r} WER={result.clips[-1].wer:.1%}")
        except Exception as exc:  # keep the table reproducible even with per-clip failures
            result.clips.append(ClipResult(
                clip=wav.name,
                category=category,
                expected=expected,
                raw_heard="",
                corrected_heard="",
                wer=1.0,
                exact=False,
                duration_s=0.0,
                decode_ms=0.0,
                quality_usable=False,
                quality_reason="error",
                error=str(exc),
            ))
            print(f"{wav.name}: ERROR {exc}", file=sys.stderr)
    summarize(result)
    json_path, md_path = write_outputs(result, args.output_dir)
    print(f"JSON: {json_path}")
    print(f"Markdown: {md_path}")
    print(f"Decision against bar: {'PASS' if result.passes_bar else 'FAIL'}")
    return 0 if result.passes_bar else 2


if __name__ == "__main__":
    raise SystemExit(main())

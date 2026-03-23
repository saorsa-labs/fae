# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer", "mlx-audio>=0.4.0", "parakeet-mlx>=0.3.0", "soundfile", "numpy"]
# ///
"""ASR streaming latency + accuracy comparison.

Simulates Fae's streaming pipeline: feeds audio in chunks and measures
time-to-first-partial, partial stability, and final accuracy.

This answers the key question: does Parakeet's speed advantage translate
into meaningfully earlier partial transcripts during active speech?

Usage:
    SSL_CERT_FILE=/etc/ssl/cert.pem SDKROOT=$(xcrun --show-sdk-path) \\
        CFLAGS="-isysroot $(xcrun --show-sdk-path)" \\
        uv run autoresearch/asr_streaming_eval.py

    # Single model:
    ... uv run autoresearch/asr_streaming_eval.py --models parakeet

    # Custom chunk size (simulating different pipeline cadences):
    ... uv run autoresearch/asr_streaming_eval.py --chunk-ms 250

Metrics:
    - Time to first meaningful partial (>3 words)
    - Partial transcript accuracy at 0.5s, 1.0s, 1.5s, 2.0s marks
    - Final transcript WER
    - Decode latency per chunk
    - GPU memory usage
"""

import argparse
import json
import os
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import soundfile as sf
from jiwer import wer as compute_wer

# Fix SSL for zerobrew
_ssl_cert = os.environ.get("SSL_CERT_FILE", "")
if _ssl_cert and not os.path.exists(_ssl_cert):
    if os.path.exists("/etc/ssl/cert.pem"):
        os.environ["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
    else:
        del os.environ["SSL_CERT_FILE"]


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

@dataclass
class PartialSnapshot:
    """A partial transcript captured at a specific point in the audio."""
    audio_fed_s: float       # how much audio has been fed so far
    decode_time_ms: float    # time taken for this decode pass
    partial_text: str        # the partial transcript at this point
    partial_wer: float       # WER of partial vs full ground truth
    word_count: int          # number of words in partial


@dataclass
class StreamingClipResult:
    clip: str
    ground_truth: str
    audio_duration_s: float
    final_text: str
    final_wer: float
    time_to_first_partial_ms: float    # wall-clock to first partial with >0 words
    time_to_meaningful_partial_ms: float  # wall-clock to first partial with >=3 words
    total_decode_passes: int
    total_decode_time_ms: float
    partials: list[PartialSnapshot] = field(default_factory=list)


@dataclass
class StreamingModelResult:
    model_name: str
    model_id: str
    chunk_ms: int
    clips: list[StreamingClipResult] = field(default_factory=list)
    aggregate_final_wer: float = 0.0
    mean_time_to_first_ms: float = 0.0
    mean_time_to_meaningful_ms: float = 0.0
    mean_decode_per_pass_ms: float = 0.0
    total_clips: int = 0
    failed_clips: int = 0


@dataclass
class StreamingComparison:
    timestamp: str
    corpus_dir: str
    chunk_ms: int
    total_clips: int
    models: list[StreamingModelResult] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Model runners
# ---------------------------------------------------------------------------

QWEN_MODEL_ID = "mlx-community/Qwen3-ASR-1.7B-4bit"
PARAKEET_MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"


def load_qwen_asr():
    from mlx_audio.stt.generate import load_model
    print(f"Loading {QWEN_MODEL_ID}...")
    model = load_model(QWEN_MODEL_ID)
    print("  Qwen3-ASR loaded.")
    return model


def load_parakeet():
    from parakeet_mlx import from_pretrained
    print(f"Loading {PARAKEET_MODEL_ID}...")
    model = from_pretrained(PARAKEET_MODEL_ID)
    print("  Parakeet loaded.")
    return model


def decode_qwen_buffer(model, buffer: np.ndarray) -> tuple[str, float]:
    """Decode accumulated buffer with Qwen3-ASR. Returns (text, decode_ms)."""
    import mlx.core as mx
    audio = mx.array(buffer)
    start = time.perf_counter()
    result = model.generate(audio)
    mx.eval(mx.array([0]))
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    text = result.text if hasattr(result, "text") else str(result)
    return text.strip(), elapsed_ms


def decode_parakeet_buffer(model, buffer: np.ndarray, sr: int = 16000) -> tuple[str, float]:
    """Decode accumulated buffer with Parakeet via temp file. Returns (text, decode_ms)."""
    import tempfile
    # Parakeet's transcribe() handles audio→mel internally with correct preprocessing.
    # Writing to a temp file is the simplest correct approach for buffer decode.
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
        sf.write(tmp.name, buffer, sr)
        start = time.perf_counter()
        result = model.transcribe(tmp.name)
        elapsed_ms = (time.perf_counter() - start) * 1000.0

    if hasattr(result, "tokens"):
        text = "".join(t.text for t in result.tokens)
    elif hasattr(result, "text"):
        text = result.text
    else:
        text = str(result)
    return text.strip(), elapsed_ms


# ---------------------------------------------------------------------------
# Text normalisation
# ---------------------------------------------------------------------------

def normalise_text(text: str) -> str:
    text = text.lower()
    text = re.sub(r"[^\w\s']", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


# ---------------------------------------------------------------------------
# Streaming simulation
# ---------------------------------------------------------------------------

def simulate_streaming(
    model,
    model_name: str,
    audio_path: Path,
    ground_truth: str,
    chunk_ms: int,
    min_decode_samples: int,
    decode_interval_samples: int,
) -> StreamingClipResult:
    """Simulate streaming ASR by feeding audio in chunks and decoding periodically.

    Mirrors Fae's pipeline: accumulate audio, decode every `decode_interval_samples`,
    with a minimum of `min_decode_samples` before first decode.
    """
    samples, sr = sf.read(str(audio_path), dtype="float32")
    if sr != 16000:
        ratio = 16000 / sr
        new_len = int(len(samples) * ratio)
        indices = np.linspace(0, len(samples) - 1, new_len)
        samples = np.interp(indices, np.arange(len(samples)), samples).astype(np.float32)
        sr = 16000

    duration = len(samples) / sr
    chunk_samples = int(chunk_ms * sr / 1000)
    ref_norm = normalise_text(ground_truth)

    result = StreamingClipResult(
        clip=audio_path.name,
        ground_truth=ground_truth,
        audio_duration_s=round(duration, 2),
        final_text="",
        final_wer=0.0,
        time_to_first_partial_ms=0.0,
        time_to_meaningful_partial_ms=0.0,
        total_decode_passes=0,
        total_decode_time_ms=0.0,
    )

    buffer = np.array([], dtype=np.float32)
    decoded_count = 0
    wall_clock_ms = 0.0  # simulated wall clock (audio fed + decode time)
    first_partial_found = False
    meaningful_partial_found = False

    offset = 0
    while offset < len(samples):
        # Feed next chunk
        end = min(offset + chunk_samples, len(samples))
        chunk = samples[offset:end]
        buffer = np.concatenate([buffer, chunk])
        audio_fed_s = len(buffer) / sr
        # Wall clock = audio duration fed so far (simulates real-time arrival)
        wall_clock_ms = audio_fed_s * 1000.0
        offset = end

        # Check if we should decode (mirrors Fae's logic)
        new_samples = len(buffer) - decoded_count
        threshold = min_decode_samples if decoded_count == 0 else decode_interval_samples
        if new_samples < threshold and offset < len(samples):
            continue

        # Decode full buffer (same as Fae's growing-buffer approach)
        if model_name == "qwen":
            text, decode_ms = decode_qwen_buffer(model, buffer)
        else:
            text, decode_ms = decode_parakeet_buffer(model, buffer)

        decoded_count = len(buffer)
        result.total_decode_passes += 1
        result.total_decode_time_ms += decode_ms

        # Add decode time to wall clock
        wall_clock_ms += decode_ms

        hyp_norm = normalise_text(text)
        word_count = len(hyp_norm.split()) if hyp_norm else 0
        partial_wer = compute_wer(ref_norm, hyp_norm) if ref_norm and hyp_norm else 1.0

        snapshot = PartialSnapshot(
            audio_fed_s=round(audio_fed_s, 2),
            decode_time_ms=round(decode_ms, 1),
            partial_text=text,
            partial_wer=round(partial_wer, 4),
            word_count=word_count,
        )
        result.partials.append(snapshot)

        if not first_partial_found and word_count > 0:
            result.time_to_first_partial_ms = round(wall_clock_ms, 1)
            first_partial_found = True

        if not meaningful_partial_found and word_count >= 3:
            result.time_to_meaningful_partial_ms = round(wall_clock_ms, 1)
            meaningful_partial_found = True

    # Final result is last partial
    if result.partials:
        last = result.partials[-1]
        result.final_text = last.partial_text
        result.final_wer = last.partial_wer
    else:
        result.final_wer = 1.0

    if not first_partial_found:
        result.time_to_first_partial_ms = wall_clock_ms
    if not meaningful_partial_found:
        result.time_to_meaningful_partial_ms = wall_clock_ms

    return result


# ---------------------------------------------------------------------------
# Main evaluation
# ---------------------------------------------------------------------------

def load_corpus(corpus_dir: Path) -> list[tuple[Path, str]]:
    pairs = []
    for audio_path in sorted(corpus_dir.glob("*.wav")):
        txt_path = audio_path.with_suffix(".txt")
        if not txt_path.exists():
            continue
        ground_truth = txt_path.read_text().strip()
        if ground_truth:
            pairs.append((audio_path, ground_truth))
    return pairs


def run_streaming_eval(
    corpus_dir: Path,
    model_names: list[str],
    chunk_ms: int,
    output_dir: Path,
) -> StreamingComparison:
    corpus = load_corpus(corpus_dir)
    if not corpus:
        print(f"ERROR: No audio/transcription pairs in {corpus_dir}")
        sys.exit(1)

    # Match Fae's defaults: 250ms min first decode, 500ms decode interval
    min_decode_samples = 4_000   # 250ms at 16kHz
    decode_interval = 8_000      # 500ms at 16kHz

    print(f"\nCorpus: {len(corpus)} clips from {corpus_dir}")
    print(f"Models: {', '.join(model_names)}")
    print(f"Chunk size: {chunk_ms}ms")
    print(f"Decode cadence: first at {min_decode_samples/16:.0f}ms, then every {decode_interval/16:.0f}ms\n")

    comparison = StreamingComparison(
        timestamp=datetime.now(timezone.utc).isoformat(),
        corpus_dir=str(corpus_dir),
        chunk_ms=chunk_ms,
        total_clips=len(corpus),
    )

    # Load models
    models = {}
    model_ids = {}
    if "qwen" in model_names:
        models["qwen"] = load_qwen_asr()
        model_ids["qwen"] = QWEN_MODEL_ID
    if "parakeet" in model_names:
        models["parakeet"] = load_parakeet()
        model_ids["parakeet"] = PARAKEET_MODEL_ID

    print()

    for model_name in model_names:
        if model_name not in models:
            continue

        model = models[model_name]
        model_result = StreamingModelResult(
            model_name=model_name,
            model_id=model_ids[model_name],
            chunk_ms=chunk_ms,
        )

        all_refs = []
        all_hyps = []

        print(f"--- {model_name.upper()} (streaming simulation) ---")
        for i, (audio_path, ground_truth) in enumerate(corpus, 1):
            try:
                clip_result = simulate_streaming(
                    model, model_name, audio_path, ground_truth,
                    chunk_ms, min_decode_samples, decode_interval,
                )
                model_result.clips.append(clip_result)

                ref_norm = normalise_text(ground_truth)
                hyp_norm = normalise_text(clip_result.final_text)
                all_refs.append(ref_norm)
                all_hyps.append(hyp_norm)

                avg_ms = clip_result.total_decode_time_ms / max(clip_result.total_decode_passes, 1)
                print(
                    f"  [{i}/{len(corpus)}] {audio_path.name}: "
                    f"WER={clip_result.final_wer:.0%}  "
                    f"first={clip_result.time_to_first_partial_ms:.0f}ms  "
                    f"meaningful={clip_result.time_to_meaningful_partial_ms:.0f}ms  "
                    f"passes={clip_result.total_decode_passes}  "
                    f"avg={avg_ms:.0f}ms/pass"
                )

                # Show partial evolution for longer clips
                if len(clip_result.partials) > 1:
                    for p in clip_result.partials:
                        words_preview = p.partial_text[:60] + ("..." if len(p.partial_text) > 60 else "")
                        print(f"        @{p.audio_fed_s:.1f}s ({p.decode_time_ms:.0f}ms): "
                              f"[{p.word_count}w] {words_preview}")

            except Exception as e:
                print(f"  [FAIL] [{i}/{len(corpus)}] {audio_path.name}: {e}")
                model_result.failed_clips += 1

        # Aggregate
        model_result.total_clips = len(corpus)
        if all_refs:
            model_result.aggregate_final_wer = round(compute_wer(all_refs, all_hyps), 4)
        if model_result.clips:
            model_result.mean_time_to_first_ms = round(
                sum(c.time_to_first_partial_ms for c in model_result.clips) / len(model_result.clips), 1
            )
            model_result.mean_time_to_meaningful_ms = round(
                sum(c.time_to_meaningful_partial_ms for c in model_result.clips) / len(model_result.clips), 1
            )
            total_passes = sum(c.total_decode_passes for c in model_result.clips)
            total_decode = sum(c.total_decode_time_ms for c in model_result.clips)
            model_result.mean_decode_per_pass_ms = round(total_decode / max(total_passes, 1), 1)

        comparison.models.append(model_result)
        print(f"\n  Final WER: {model_result.aggregate_final_wer:.1%}")
        print(f"  Mean time to first partial: {model_result.mean_time_to_first_ms:.0f}ms")
        print(f"  Mean time to meaningful (3+ words): {model_result.mean_time_to_meaningful_ms:.0f}ms")
        print(f"  Mean decode per pass: {model_result.mean_decode_per_pass_ms:.0f}ms")
        print(f"  Failed: {model_result.failed_clips}/{model_result.total_clips}")
        print()

    return comparison


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def write_results(comparison: StreamingComparison, output_dir: Path):
    output_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")

    # JSON
    json_path = output_dir / f"asr_streaming_{ts}.json"
    json_path.write_text(json.dumps(asdict(comparison), indent=2))
    print(f"JSON results: {json_path}")

    # Markdown
    md_lines = [
        f"# ASR Streaming Comparison — {ts}",
        "",
        f"**Corpus**: {comparison.corpus_dir} ({comparison.total_clips} clips)",
        f"**Chunk size**: {comparison.chunk_ms}ms",
        "",
        "## Aggregate Results",
        "",
        "| Model | Final WER | Avg First Partial | Avg Meaningful (3+ words) | Avg Decode/Pass | Failed |",
        "|-------|-----------|-------------------|---------------------------|-----------------|--------|",
    ]
    for m in comparison.models:
        md_lines.append(
            f"| {m.model_name} | {m.aggregate_final_wer:.1%} | "
            f"{m.mean_time_to_first_ms:.0f}ms | {m.mean_time_to_meaningful_ms:.0f}ms | "
            f"{m.mean_decode_per_pass_ms:.0f}ms | {m.failed_clips}/{m.total_clips} |"
        )

    # Per-clip streaming detail
    md_lines.extend(["", "## Per-Clip Streaming Detail", ""])
    for m in comparison.models:
        md_lines.append(f"### {m.model_name}")
        md_lines.append("")
        md_lines.append("| Clip | Duration | Final WER | First Partial | Meaningful | Passes | Avg/Pass |")
        md_lines.append("|------|----------|-----------|---------------|------------|--------|----------|")
        for c in sorted(m.clips, key=lambda x: x.clip):
            avg = c.total_decode_time_ms / max(c.total_decode_passes, 1)
            md_lines.append(
                f"| {c.clip} | {c.audio_duration_s:.1f}s | {c.final_wer:.0%} | "
                f"{c.time_to_first_partial_ms:.0f}ms | {c.time_to_meaningful_partial_ms:.0f}ms | "
                f"{c.total_decode_passes} | {avg:.0f}ms |"
            )
        md_lines.append("")

    md_path = output_dir / f"asr_streaming_{ts}.md"
    md_path.write_text("\n".join(md_lines))
    print(f"Markdown summary: {md_path}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="ASR streaming latency + accuracy comparison")
    parser.add_argument("--corpus", type=Path, default=Path(__file__).parent / "asr_corpus")
    parser.add_argument("--models", nargs="+", choices=["qwen", "parakeet"], default=["qwen", "parakeet"])
    parser.add_argument("--chunk-ms", type=int, default=32, help="Audio chunk size in ms (default: 32, matching Fae's 576-sample chunks)")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "results")
    args = parser.parse_args()

    if not args.corpus.exists():
        print(f"Corpus not found: {args.corpus}")
        print("Run: uv run autoresearch/asr_generate_corpus.py")
        sys.exit(1)

    comparison = run_streaming_eval(args.corpus, args.models, args.chunk_ms, args.output)
    write_results(comparison, args.output)

    if len(comparison.models) == 2:
        m1, m2 = comparison.models
        print(f"\n{'='*70}")
        print(f"  STREAMING COMPARISON (chunk={comparison.chunk_ms}ms)")
        print(f"  {'':30s} {'Qwen3-ASR':>15s} {'Parakeet':>15s}")
        print(f"  {'Final WER':30s} {m1.aggregate_final_wer:>14.1%} {m2.aggregate_final_wer:>14.1%}")
        print(f"  {'First partial':30s} {m1.mean_time_to_first_ms:>12.0f}ms {m2.mean_time_to_first_ms:>12.0f}ms")
        print(f"  {'Meaningful partial (3+ words)':30s} {m1.mean_time_to_meaningful_ms:>12.0f}ms {m2.mean_time_to_meaningful_ms:>12.0f}ms")
        print(f"  {'Decode per pass':30s} {m1.mean_decode_per_pass_ms:>12.0f}ms {m2.mean_decode_per_pass_ms:>12.0f}ms")
        delta_first = m1.mean_time_to_first_ms - m2.mean_time_to_first_ms
        delta_meaningful = m1.mean_time_to_meaningful_ms - m2.mean_time_to_meaningful_ms
        faster = m2.model_name if delta_first > 0 else m1.model_name
        print(f"\n  Parakeet delivers first partial {abs(delta_first):.0f}ms "
              f"{'earlier' if delta_first > 0 else 'later'}")
        print(f"  Parakeet delivers meaningful partial {abs(delta_meaningful):.0f}ms "
              f"{'earlier' if delta_meaningful > 0 else 'later'}")
        print(f"{'='*70}")


if __name__ == "__main__":
    main()

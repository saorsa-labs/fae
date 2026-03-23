# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer", "mlx-audio>=0.4.0", "parakeet-mlx>=0.3.0", "soundfile"]
# ///
"""ASR accuracy comparison: Qwen3-ASR vs Parakeet TDT on the same corpus.

Usage:
    SDKROOT=$(xcrun --show-sdk-path) CFLAGS="-isysroot $(xcrun --show-sdk-path)" \\
        uv run autoresearch/asr_accuracy_eval.py

    # Custom corpus:
    ... uv run autoresearch/asr_accuracy_eval.py --corpus path/to/clips

    # Single model:
    ... uv run autoresearch/asr_accuracy_eval.py --models parakeet

Corpus layout:
    corpus_dir/
        greeting_01.wav      # 16kHz mono preferred; resampled if needed
        greeting_01.txt      # ground truth transcription (one line)
        ...

Output: JSON results + Markdown summary table written to autoresearch/results/.

Note: On macOS with zerobrew, you need SDKROOT and CFLAGS set for mlx-audio's
miniaudio C dependency to compile. The generate_corpus script has a wrapper.
"""

import argparse
import json
import os
import re
import sys
import time

# Fix SSL_CERT_FILE — zerobrew's Python sets this to a non-existent path,
# breaking httpx/huggingface_hub TLS connections. Fall back to system certs.
_ssl_cert = os.environ.get("SSL_CERT_FILE", "")
if _ssl_cert and not os.path.exists(_ssl_cert):
    # Try certifi, then system certs, then unset entirely
    try:
        import certifi
        os.environ["SSL_CERT_FILE"] = certifi.where()
    except ImportError:
        if os.path.exists("/etc/ssl/cert.pem"):
            os.environ["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        else:
            del os.environ["SSL_CERT_FILE"]
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import soundfile as sf
from jiwer import wer as compute_wer


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

@dataclass
class ClipResult:
    clip: str
    ground_truth: str
    hypothesis: str
    wer: float
    decode_time_ms: float
    audio_duration_s: float
    rtf: float  # real-time factor: decode_time / audio_duration


@dataclass
class ModelResult:
    model_name: str
    model_id: str
    clips: list[ClipResult] = field(default_factory=list)
    aggregate_wer: float = 0.0
    mean_decode_ms: float = 0.0
    mean_rtf: float = 0.0
    total_clips: int = 0
    failed_clips: int = 0


@dataclass
class ComparisonResult:
    timestamp: str
    corpus_dir: str
    total_clips: int
    models: list[ModelResult] = field(default_factory=list)
    per_clip_winner: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Model runners
# ---------------------------------------------------------------------------

QWEN_MODEL_ID = "mlx-community/Qwen3-ASR-1.7B-4bit"
PARAKEET_MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"


def load_qwen_asr():
    """Load Qwen3-ASR-1.7B via mlx-audio."""
    from mlx_audio.stt.generate import load_model
    print(f"Loading {QWEN_MODEL_ID}...")
    model = load_model(QWEN_MODEL_ID)
    print("  Qwen3-ASR loaded.")
    return model


def load_parakeet():
    """Load Parakeet TDT 0.6B v3 via parakeet-mlx."""
    from parakeet_mlx import from_pretrained
    print(f"Loading {PARAKEET_MODEL_ID}...")
    model = from_pretrained(PARAKEET_MODEL_ID)
    print("  Parakeet loaded.")
    return model


def transcribe_qwen(model, audio_path: Path) -> tuple[str, float]:
    """Transcribe with Qwen3-ASR via mlx-audio. Returns (text, decode_time_ms)."""
    import mlx.core as mx

    start = time.perf_counter()
    result = model.generate(str(audio_path))
    mx.eval(mx.array([0]))  # sync
    elapsed_ms = (time.perf_counter() - start) * 1000.0

    # mlx-audio generate returns an STTOutput with .text
    if hasattr(result, "text"):
        text = result.text
    else:
        # Fallback: iterate segments
        text = " ".join(
            seg.get("text", "") if isinstance(seg, dict) else str(seg)
            for seg in (result if isinstance(result, list) else [result])
        )

    return text.strip(), elapsed_ms


def transcribe_parakeet(model, audio_path: Path) -> tuple[str, float]:
    """Transcribe with Parakeet TDT via parakeet-mlx. Returns (text, decode_time_ms)."""
    start = time.perf_counter()
    result = model.transcribe(str(audio_path))
    elapsed_ms = (time.perf_counter() - start) * 1000.0

    # AlignedResult has .tokens list of AlignedToken, each with .text
    if hasattr(result, "tokens"):
        text = "".join(t.text for t in result.tokens)
    elif hasattr(result, "text"):
        text = result.text
    else:
        text = str(result)

    return text.strip(), elapsed_ms


# ---------------------------------------------------------------------------
# Corpus loading
# ---------------------------------------------------------------------------

def load_corpus(corpus_dir: Path) -> list[tuple[Path, str]]:
    """Load audio/transcription pairs from corpus directory."""
    pairs = []
    audio_files = sorted(corpus_dir.glob("*.wav"))
    if not audio_files:
        for ext in ("*.mp3", "*.flac", "*.m4a"):
            audio_files.extend(corpus_dir.glob(ext))
        audio_files = sorted(audio_files)

    for audio_path in audio_files:
        txt_path = audio_path.with_suffix(".txt")
        if not txt_path.exists():
            print(f"  SKIP {audio_path.name}: no matching .txt ground truth")
            continue
        ground_truth = txt_path.read_text().strip()
        if not ground_truth:
            print(f"  SKIP {audio_path.name}: empty ground truth")
            continue
        pairs.append((audio_path, ground_truth))

    return pairs


def get_audio_duration(audio_path: Path) -> float:
    """Get audio duration in seconds."""
    info = sf.info(str(audio_path))
    return info.duration


# ---------------------------------------------------------------------------
# Normalisation for WER
# ---------------------------------------------------------------------------

def normalise_text(text: str) -> str:
    """Normalise text for fair WER calculation.

    Lowercases, strips punctuation, collapses whitespace.
    """
    text = text.lower()
    # Remove punctuation except apostrophes in contractions
    text = re.sub(r"[^\w\s']", " ", text)
    # Collapse whitespace
    text = re.sub(r"\s+", " ", text).strip()
    return text


# ---------------------------------------------------------------------------
# Main evaluation
# ---------------------------------------------------------------------------

def run_eval(corpus_dir: Path, model_names: list[str], output_dir: Path) -> ComparisonResult:
    """Run ASR evaluation across models on the corpus."""
    corpus = load_corpus(corpus_dir)
    if not corpus:
        print(f"ERROR: No audio/transcription pairs found in {corpus_dir}")
        print("  Expected: *.wav files with matching *.txt ground truth files")
        sys.exit(1)

    print(f"\nCorpus: {len(corpus)} clips from {corpus_dir}")
    print(f"Models: {', '.join(model_names)}\n")

    comparison = ComparisonResult(
        timestamp=datetime.now(timezone.utc).isoformat(),
        corpus_dir=str(corpus_dir),
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

    # Run each model on all clips
    for model_name in model_names:
        if model_name not in models:
            continue

        model = models[model_name]
        model_result = ModelResult(
            model_name=model_name,
            model_id=model_ids[model_name],
        )

        all_refs = []
        all_hyps = []

        print(f"--- {model_name.upper()} ---")
        for i, (audio_path, ground_truth) in enumerate(corpus, 1):
            duration = get_audio_duration(audio_path)
            try:
                if model_name == "qwen":
                    hyp, decode_ms = transcribe_qwen(model, audio_path)
                else:
                    hyp, decode_ms = transcribe_parakeet(model, audio_path)

                # Normalise for WER
                ref_norm = normalise_text(ground_truth)
                hyp_norm = normalise_text(hyp)

                clip_wer = compute_wer(ref_norm, hyp_norm) if ref_norm else 0.0
                rtf = (decode_ms / 1000.0) / duration if duration > 0 else 0.0

                clip_result = ClipResult(
                    clip=audio_path.name,
                    ground_truth=ground_truth,
                    hypothesis=hyp,
                    wer=round(clip_wer, 4),
                    decode_time_ms=round(decode_ms, 1),
                    audio_duration_s=round(duration, 2),
                    rtf=round(rtf, 4),
                )
                model_result.clips.append(clip_result)
                all_refs.append(ref_norm)
                all_hyps.append(hyp_norm)

                status = "OK" if clip_wer < 0.1 else "WARN" if clip_wer < 0.3 else "BAD"
                print(f"  [{status}] [{i}/{len(corpus)}] {audio_path.name}: "
                      f"WER={clip_wer:.1%}  ({decode_ms:.0f}ms, RTF={rtf:.3f})")
                if clip_wer > 0.0:
                    print(f"        ref: {ground_truth}")
                    print(f"        hyp: {hyp}")

            except Exception as e:
                print(f"  [FAIL] [{i}/{len(corpus)}] {audio_path.name}: {e}")
                model_result.failed_clips += 1

        # Aggregate metrics
        model_result.total_clips = len(corpus)
        if all_refs:
            model_result.aggregate_wer = round(compute_wer(all_refs, all_hyps), 4)
        if model_result.clips:
            model_result.mean_decode_ms = round(
                sum(c.decode_time_ms for c in model_result.clips) / len(model_result.clips), 1
            )
            model_result.mean_rtf = round(
                sum(c.rtf for c in model_result.clips) / len(model_result.clips), 4
            )

        comparison.models.append(model_result)
        print(f"\n  Aggregate WER: {model_result.aggregate_wer:.1%}")
        print(f"  Mean decode: {model_result.mean_decode_ms:.0f}ms")
        print(f"  Mean RTF: {model_result.mean_rtf:.4f}")
        print(f"  Failed: {model_result.failed_clips}/{model_result.total_clips}")
        print()

    # Per-clip winner analysis (when both models ran)
    if len(comparison.models) == 2:
        m1, m2 = comparison.models
        clips_1 = {c.clip: c for c in m1.clips}
        clips_2 = {c.clip: c for c in m2.clips}
        winners = {"tie": 0, m1.model_name: 0, m2.model_name: 0}
        for clip_name in clips_1:
            if clip_name in clips_2:
                w1, w2 = clips_1[clip_name].wer, clips_2[clip_name].wer
                if abs(w1 - w2) < 0.001:
                    winners["tie"] += 1
                elif w1 < w2:
                    winners[m1.model_name] += 1
                else:
                    winners[m2.model_name] += 1
        comparison.per_clip_winner = winners

    return comparison


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def write_results(comparison: ComparisonResult, output_dir: Path):
    """Write JSON results and Markdown summary."""
    output_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")

    # JSON
    json_path = output_dir / f"asr_comparison_{ts}.json"
    json_path.write_text(json.dumps(asdict(comparison), indent=2))
    print(f"JSON results: {json_path}")

    # Markdown summary
    md_lines = [
        f"# ASR Accuracy Comparison — {ts}",
        "",
        f"**Corpus**: {comparison.corpus_dir} ({comparison.total_clips} clips)",
        "",
        "## Aggregate Results",
        "",
        "| Model | WER | Mean Decode (ms) | Mean RTF | Failed |",
        "|-------|-----|-------------------|----------|--------|",
    ]
    for m in comparison.models:
        md_lines.append(
            f"| {m.model_name} ({m.model_id}) | "
            f"{m.aggregate_wer:.1%} | {m.mean_decode_ms:.0f} | "
            f"{m.mean_rtf:.4f} | {m.failed_clips}/{m.total_clips} |"
        )

    if comparison.per_clip_winner:
        md_lines.extend([
            "",
            "## Per-Clip Winner",
            "",
        ])
        for name, count in comparison.per_clip_winner.items():
            md_lines.append(f"- **{name}**: {count} clips")

    # Build per-clip table with dynamic model columns
    model_names = [m.model_name for m in comparison.models]
    header = "| Clip | Duration |"
    sep = "|------|----------|"
    for name in model_names:
        header += f" {name} WER | {name} ms |"
        sep += "----------|---------|"

    md_lines.extend(["", "## Per-Clip Detail", "", header, sep])

    clip_data = {}
    for m in comparison.models:
        for c in m.clips:
            if c.clip not in clip_data:
                clip_data[c.clip] = {"duration": c.audio_duration_s}
            clip_data[c.clip][m.model_name] = c

    for clip_name in sorted(clip_data.keys()):
        data = clip_data[clip_name]
        row = f"| {clip_name} | {data['duration']:.1f}s |"
        for name in model_names:
            if name in data:
                c = data[name]
                row += f" {c.wer:.1%} | {c.decode_time_ms:.0f} |"
            else:
                row += " — | — |"
        md_lines.append(row)

    # Worst clips section
    if comparison.models:
        md_lines.extend(["", "## Worst Clips (highest WER)", ""])
        for m in comparison.models:
            worst = sorted(m.clips, key=lambda c: c.wer, reverse=True)[:5]
            md_lines.append(f"### {m.model_name}")
            md_lines.append("")
            for c in worst:
                if c.wer > 0:
                    md_lines.append(f"- **{c.clip}** (WER {c.wer:.1%})")
                    md_lines.append(f"  - ref: {c.ground_truth}")
                    md_lines.append(f"  - hyp: {c.hypothesis}")
            md_lines.append("")

    md_path = output_dir / f"asr_comparison_{ts}.md"
    md_path.write_text("\n".join(md_lines))
    print(f"Markdown summary: {md_path}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Compare ASR accuracy: Qwen3-ASR vs Parakeet TDT"
    )
    parser.add_argument(
        "--corpus",
        type=Path,
        default=Path(__file__).parent / "asr_corpus",
        help="Directory containing .wav + .txt pairs (default: autoresearch/asr_corpus/)",
    )
    parser.add_argument(
        "--models",
        nargs="+",
        choices=["qwen", "parakeet"],
        default=["qwen", "parakeet"],
        help="Which models to evaluate (default: both)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).parent / "results",
        help="Output directory for results (default: autoresearch/results/)",
    )
    args = parser.parse_args()

    if not args.corpus.exists():
        print(f"Corpus directory not found: {args.corpus}")
        print()
        print("Create it with .wav + .txt pairs:")
        print(f"  mkdir -p {args.corpus}")
        print(f"  # Record clips, then create matching .txt ground truth files")
        print(f"  # Example:")
        print(f"  #   greeting_01.wav  ->  greeting_01.txt containing 'Hello Fae'")
        print()
        print("Quick start — generate synthetic corpus:")
        print(f"  uv run autoresearch/asr_generate_corpus.py")
        print()
        print("Or record your own voice:")
        print(f"  uv run autoresearch/asr_record_clips.py")
        sys.exit(1)

    comparison = run_eval(args.corpus, args.models, args.output)
    write_results(comparison, args.output)

    # Print final summary
    if len(comparison.models) == 2:
        m1, m2 = comparison.models
        print(f"\n{'='*60}")
        print(f"  {m1.model_name}: {m1.aggregate_wer:.1%} WER, {m1.mean_decode_ms:.0f}ms avg")
        print(f"  {m2.model_name}: {m2.aggregate_wer:.1%} WER, {m2.mean_decode_ms:.0f}ms avg")
        if comparison.per_clip_winner:
            w = comparison.per_clip_winner
            print(f"  Per-clip: {w.get(m1.model_name, 0)} {m1.model_name} / "
                  f"{w.get(m2.model_name, 0)} {m2.model_name} / "
                  f"{w.get('tie', 0)} tie")
        print(f"{'='*60}")
    elif len(comparison.models) == 1:
        m = comparison.models[0]
        print(f"\n{'='*60}")
        print(f"  {m.model_name}: {m.aggregate_wer:.1%} WER, {m.mean_decode_ms:.0f}ms avg")
        print(f"{'='*60}")


if __name__ == "__main__":
    main()

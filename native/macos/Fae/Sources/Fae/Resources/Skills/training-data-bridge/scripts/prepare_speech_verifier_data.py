# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "soundfile", "librosa"]
# ///

"""Prepare speech/music/noise classification dataset from MUSAN corpus.

Reads from the local MUSAN corpus (downloaded to Tests/eval-corpus/datasets/musan/musan/),
extracts 1-second chunks, computes mel spectrograms, and produces .npz files
for training a 3-class speech verifier (~200K params).

Label mapping (3 classes):
  0: speech — MUSAN speech files + speech augmented with noise/music
  1: music  — MUSAN music files
  2: noise  — MUSAN noise files

Output:
  ~/Library/Application Support/fae/training/data/speech-verifier/
    ├── train.npz   (mels: [N, 48, 128], labels: [N])
    ├── valid.npz
    └── meta.json
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf

# Mel spectrogram parameters — must match CoreMLSpeakerEncoder constants.
SAMPLE_RATE = 24_000
N_FFT = 1024
HOP_LENGTH = 256
N_MELS = 128
F_MIN = 0.0
F_MAX = 12_000.0
TARGET_FRAMES = 48

LABEL_SPEECH = 0
LABEL_MUSIC = 1
LABEL_NOISE = 2
LABEL_NAMES = ["speech", "music", "noise"]

OUTPUT_DIR = os.path.expanduser(
    "~/Library/Application Support/fae/training/data/speech-verifier"
)

# Find MUSAN corpus relative to this script.
# Script is at: Sources/Fae/Resources/Skills/training-data-bridge/scripts/
# MUSAN is at:  Tests/eval-corpus/datasets/musan/musan/
# We need to go up 6 levels from scripts/ to the package root (Fae/).
SCRIPT_DIR = Path(__file__).resolve().parent
PACKAGE_ROOT = SCRIPT_DIR.parents[5]  # scripts → training-data-bridge → Skills → Resources → Fae → Sources → Fae(package)
# Actually just find it by going up until we find Package.swift
_d = SCRIPT_DIR
while _d != _d.parent:
    if (_d / "Package.swift").exists():
        PACKAGE_ROOT = _d
        break
    _d = _d.parent
MUSAN_DIR = PACKAGE_ROOT / "Tests" / "eval-corpus" / "datasets" / "musan" / "musan"


def compute_log_mel(audio: np.ndarray, sr: int) -> np.ndarray:
    """Compute 128-band log-mel spectrogram."""
    if sr != SAMPLE_RATE:
        audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE)
    mel = librosa.feature.melspectrogram(
        y=audio, sr=SAMPLE_RATE, n_fft=N_FFT, hop_length=HOP_LENGTH,
        n_mels=N_MELS, fmin=F_MIN, fmax=F_MAX,
    )
    return np.log1p(mel)


def time_normalize_mel(mel: np.ndarray, target_frames: int = TARGET_FRAMES) -> np.ndarray:
    """Linearly interpolate mel spectrogram to fixed frame count."""
    n_mels, num_frames = mel.shape
    if num_frames == 0 or n_mels == 0:
        return np.zeros((n_mels, target_frames), dtype=np.float32)
    output = np.zeros((n_mels, target_frames), dtype=np.float32)
    denominator = max(target_frames - 1, 1)
    source_max = float(max(num_frames - 1, 0))
    for mel_idx in range(n_mels):
        for frame_idx in range(target_frames):
            position = float(frame_idx) * source_max / float(denominator)
            left = int(position)
            right = min(left + 1, num_frames - 1)
            alpha = position - float(left)
            output[mel_idx, frame_idx] = (
                mel[mel_idx, left] + (mel[mel_idx, right] - mel[mel_idx, left]) * alpha
            )
    return output


def process_sample(audio: np.ndarray, sr: int) -> np.ndarray | None:
    """Convert audio to time-normalized mel spectrogram [N_MELS, TARGET_FRAMES]."""
    if len(audio) < sr // 4:  # At least 250ms
        return None
    log_mel = compute_log_mel(audio, sr)
    if log_mel.shape[1] < 4:
        return None
    return time_normalize_mel(log_mel).astype(np.float32)


def extract_chunks(filepath: str, chunk_seconds: float = 1.0, max_chunks: int = 5) -> list[tuple[np.ndarray, int]]:
    """Extract multiple random 1-second chunks from an audio file."""
    try:
        audio, sr = sf.read(filepath, dtype="float32")
    except Exception:
        return []
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    chunk_samples = int(chunk_seconds * sr)
    if len(audio) <= chunk_samples:
        return [(audio, sr)]
    max_offset = len(audio) - chunk_samples
    if max_offset <= 0:
        return [(audio, sr)]
    rng = np.random.default_rng(hash(filepath) & 0xFFFFFFFF)
    n_chunks = min(max_chunks, max(1, len(audio) // chunk_samples))
    offsets = rng.integers(0, max_offset, size=n_chunks)
    return [(audio[o:o + chunk_samples], sr) for o in offsets]


def collect_files(directory: Path) -> list[str]:
    """Recursively collect all .wav files."""
    if not directory.exists():
        return []
    return sorted(str(p) for p in directory.rglob("*.wav"))


def mix_at_snr(speech: np.ndarray, noise: np.ndarray, snr_db: float) -> np.ndarray:
    """Mix speech and noise at a target SNR."""
    speech_rms = np.sqrt(np.mean(speech ** 2))
    noise_rms = np.sqrt(np.mean(noise ** 2))
    if speech_rms < 1e-6 or noise_rms < 1e-6:
        return speech
    target_noise_rms = speech_rms / (10 ** (snr_db / 20))
    scale = target_noise_rms / noise_rms
    # Loop noise to match speech length.
    noise_extended = np.tile(noise, int(np.ceil(len(speech) / len(noise))))[:len(speech)]
    return speech + noise_extended * scale


def main():
    if not MUSAN_DIR.exists():
        print(f"MUSAN corpus not found at {MUSAN_DIR}")
        print("Download with: just record-eval or manually place at Tests/eval-corpus/datasets/musan/musan/")
        sys.exit(1)

    speech_dir = MUSAN_DIR / "speech"
    music_dir = MUSAN_DIR / "music"
    noise_dir = MUSAN_DIR / "noise"

    speech_files = collect_files(speech_dir)
    music_files = collect_files(music_dir)
    noise_files = collect_files(noise_dir)

    print(f"Found: {len(speech_files)} speech, {len(music_files)} music, {len(noise_files)} noise files")

    rng = np.random.default_rng(42)
    all_mels: list[np.ndarray] = []
    all_labels: list[int] = []

    # Process speech files.
    print("Processing speech...")
    speech_count = 0
    for f in speech_files:
        for audio, sr in extract_chunks(f, max_chunks=4):
            mel = process_sample(audio, sr)
            if mel is not None:
                all_mels.append(mel)
                all_labels.append(LABEL_SPEECH)
                speech_count += 1
    print(f"  Clean speech samples: {speech_count}")

    # Augment speech with noise at various SNRs.
    print("Augmenting speech with noise...")
    augmented_count = 0
    noise_audios = []
    for f in noise_files[:50]:
        try:
            a, sr = sf.read(f, dtype="float32")
            if a.ndim > 1:
                a = a.mean(axis=1)
            if sr != SAMPLE_RATE:
                a = librosa.resample(a, orig_sr=sr, target_sr=SAMPLE_RATE)
            noise_audios.append(a)
        except Exception:
            continue

    for f in speech_files[:100]:
        for audio, sr in extract_chunks(f, max_chunks=2):
            if sr != SAMPLE_RATE:
                audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE)
            if not noise_audios:
                break
            noise = noise_audios[rng.integers(0, len(noise_audios))]
            snr = rng.choice([5, 10, 15, 20])
            mixed = mix_at_snr(audio, noise, snr)
            mel = process_sample(mixed, SAMPLE_RATE)
            if mel is not None:
                all_mels.append(mel)
                all_labels.append(LABEL_SPEECH)  # Still speech even with noise
                augmented_count += 1
    print(f"  Augmented speech samples: {augmented_count}")

    # Augment speech with music.
    print("Augmenting speech with music...")
    music_bg_count = 0
    music_audios = []
    for f in music_files[:30]:
        try:
            a, sr = sf.read(f, dtype="float32")
            if a.ndim > 1:
                a = a.mean(axis=1)
            if sr != SAMPLE_RATE:
                a = librosa.resample(a, orig_sr=sr, target_sr=SAMPLE_RATE)
            music_audios.append(a)
        except Exception:
            continue

    for f in speech_files[:80]:
        for audio, sr in extract_chunks(f, max_chunks=1):
            if sr != SAMPLE_RATE:
                audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE)
            if not music_audios:
                break
            music = music_audios[rng.integers(0, len(music_audios))]
            snr = rng.choice([10, 15, 20])
            mixed = mix_at_snr(audio, music, snr)
            mel = process_sample(mixed, SAMPLE_RATE)
            if mel is not None:
                all_mels.append(mel)
                all_labels.append(LABEL_SPEECH)  # Speech over music = speech
                music_bg_count += 1
    print(f"  Speech-over-music samples: {music_bg_count}")

    # Process music files.
    print("Processing music...")
    music_count = 0
    for f in music_files:
        for audio, sr in extract_chunks(f, max_chunks=3):
            mel = process_sample(audio, sr)
            if mel is not None:
                all_mels.append(mel)
                all_labels.append(LABEL_MUSIC)
                music_count += 1
    print(f"  Music samples: {music_count}")

    # Process noise files.
    print("Processing noise...")
    noise_count = 0
    for f in noise_files:
        for audio, sr in extract_chunks(f, max_chunks=3):
            mel = process_sample(audio, sr)
            if mel is not None:
                all_mels.append(mel)
                all_labels.append(LABEL_NOISE)
                noise_count += 1
    print(f"  Noise samples: {noise_count}")

    # Shuffle and split.
    total = len(all_mels)
    print(f"\nTotal samples: {total}")
    indices = rng.permutation(total)
    split = int(total * 0.85)

    train_mels = np.stack([all_mels[i] for i in indices[:split]])
    train_labels = np.array([all_labels[i] for i in indices[:split]], dtype=np.int32)
    valid_mels = np.stack([all_mels[i] for i in indices[split:]])
    valid_labels = np.array([all_labels[i] for i in indices[split:]], dtype=np.int32)

    print(f"Train: {len(train_mels)}, Valid: {len(valid_mels)}")
    for label_idx, name in enumerate(LABEL_NAMES):
        train_count = int(np.sum(train_labels == label_idx))
        valid_count = int(np.sum(valid_labels == label_idx))
        print(f"  {name}: train={train_count}, valid={valid_count}")

    # Save.
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    np.savez(os.path.join(OUTPUT_DIR, "train.npz"), mels=train_mels, labels=train_labels)
    np.savez(os.path.join(OUTPUT_DIR, "valid.npz"), mels=valid_mels, labels=valid_labels)

    meta = {
        "num_classes": 3,
        "label_names": LABEL_NAMES,
        "input_features": N_MELS,
        "target_frames": TARGET_FRAMES,
        "sample_rate": SAMPLE_RATE,
        "total_samples": total,
        "train_samples": len(train_mels),
        "valid_samples": len(valid_mels),
    }
    with open(os.path.join(OUTPUT_DIR, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    print(f"\nSaved to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()

# /// script
# requires-python = ">=3.10"
# dependencies = ["datasets", "numpy", "soundfile", "librosa"]
# ///

"""Prepare keyword classification dataset from Google Speech Commands + augmentation.

Downloads Google Speech Commands v0.02, filters for target keywords, generates
synthetic wake-word samples, and produces mel-spectrogram .npz files for training
a micro keyword classifier (~200K params).

Label mapping (5 classes):
  0: interrupt — "stop", "no", "go", "off", "down", "up"
  1: wake     — synthetic "fae" / "hey fae" (added by TTS augmentation)
  2: speech   — all other recognized speech commands
  3: silence  — silence class + generated silence
  4: noise    — background noise class

Output:
  ~/Library/Application Support/fae/training/data/keyword/
    ├── train.npz   (mels: [N, 48, 128], labels: [N])
    ├── valid.npz
    └── meta.json
"""

from __future__ import annotations

import json
import os
import sys

import librosa
import numpy as np

# Mel spectrogram parameters — must match CoreMLSpeakerEncoder constants.
SAMPLE_RATE = 24_000  # CoreMLSpeakerEncoder.modelSampleRate
N_FFT = 1024
HOP_LENGTH = 256
N_MELS = 128
F_MIN = 0.0
F_MAX = 12_000.0
TARGET_FRAMES = 48  # WakeWordAcousticDetector.targetFrames

# Label mapping.
INTERRUPT_WORDS = {"stop", "no", "go", "off", "down", "up"}
# Speech Commands v0.02 recognized words (excluding interrupt words and special classes).
SPECIAL_CLASSES = {"_silence_", "_background_noise_"}

LABEL_INTERRUPT = 0
LABEL_WAKE = 1
LABEL_SPEECH = 2
LABEL_SILENCE = 3
LABEL_NOISE = 4

LABEL_NAMES = ["interrupt", "wake", "speech", "silence", "noise"]

OUTPUT_DIR = os.path.expanduser(
    "~/Library/Application Support/fae/training/data/keyword"
)


def compute_log_mel(audio: np.ndarray, sr: int) -> np.ndarray:
    """Compute 128-band log-mel spectrogram matching CoreMLSpeakerEncoder params."""
    # Resample to 24kHz if needed.
    if sr != SAMPLE_RATE:
        audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE)

    # Compute mel spectrogram.
    mel = librosa.feature.melspectrogram(
        y=audio,
        sr=SAMPLE_RATE,
        n_fft=N_FFT,
        hop_length=HOP_LENGTH,
        n_mels=N_MELS,
        fmin=F_MIN,
        fmax=F_MAX,
    )

    # Log scale (matching log1p used in CoreMLSpeakerEncoder).
    log_mel = np.log1p(mel)
    return log_mel  # Shape: [N_MELS, num_frames]


def time_normalize_mel(mel: np.ndarray, target_frames: int = TARGET_FRAMES) -> np.ndarray:
    """Linearly interpolate mel spectrogram to fixed frame count.

    Matches WakeWordAcousticDetector.timeNormalizeMel() exactly.
    """
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
    """Convert audio sample to time-normalized mel spectrogram [N_MELS, TARGET_FRAMES]."""
    if len(audio) == 0:
        return None

    log_mel = compute_log_mel(audio, sr)
    if log_mel.shape[1] < 4:
        return None

    normalized = time_normalize_mel(log_mel)
    return normalized.astype(np.float32)


def generate_silence_samples(count: int = 500) -> list[np.ndarray]:
    """Generate silence samples with slight noise variation."""
    samples = []
    rng = np.random.default_rng(42)
    for _ in range(count):
        # 0.5-1s of very quiet noise at 24kHz.
        duration = rng.uniform(0.5, 1.0)
        n_samples = int(duration * SAMPLE_RATE)
        noise_level = rng.uniform(0.0001, 0.002)
        audio = rng.normal(0, noise_level, n_samples).astype(np.float32)
        mel = process_sample(audio, SAMPLE_RATE)
        if mel is not None:
            samples.append(mel)
    return samples


def generate_wake_samples_synthetic(count: int = 200) -> list[np.ndarray]:
    """Generate synthetic wake word samples using formant synthesis.

    Creates simple voiced audio that approximates "fae" / "hey fae" patterns.
    These are rough approximations — real Kokoro TTS augmentation is preferred
    but requires the full inference stack.
    """
    samples = []
    rng = np.random.default_rng(123)

    for _ in range(count):
        duration = rng.uniform(0.4, 1.0)
        n_samples = int(duration * SAMPLE_RATE)
        t = np.linspace(0, duration, n_samples, dtype=np.float32)

        # Simple voiced signal with formant structure.
        f0 = rng.uniform(100, 300)  # Fundamental frequency variation.
        signal = np.zeros(n_samples, dtype=np.float32)

        # Add harmonics with formant-like weighting.
        for harmonic in range(1, 8):
            freq = f0 * harmonic
            if freq > SAMPLE_RATE / 2:
                break
            weight = 1.0 / (harmonic ** 1.5)
            # Add formant resonance around 500Hz and 2500Hz (approximating "fae").
            for formant_center in [500, 2500]:
                bw = 200
                resonance = np.exp(-0.5 * ((freq - formant_center) / bw) ** 2)
                weight *= 1.0 + 2.0 * resonance

            signal += weight * np.sin(2 * np.pi * freq * t)

        # Normalize and add slight noise.
        peak = np.max(np.abs(signal))
        if peak > 0:
            signal = signal / peak * rng.uniform(0.3, 0.8)
        signal += rng.normal(0, 0.01, n_samples).astype(np.float32)

        mel = process_sample(signal, SAMPLE_RATE)
        if mel is not None:
            samples.append(mel)

    return samples


def main() -> None:
    params: dict = {}
    if len(sys.argv) > 1:
        try:
            request = json.loads(sys.argv[1])
            if isinstance(request, dict):
                params = request.get("params", {})
        except json.JSONDecodeError:
            pass

    max_samples_per_class = params.get("max_samples_per_class", 2000)
    validation_split = params.get("validation_split", 0.2)

    print("Loading Google Speech Commands v0.02...")
    from datasets import load_dataset

    ds = load_dataset("google/speech_commands", "v0.02", split="train", trust_remote_code=True)

    all_mels: list[np.ndarray] = []
    all_labels: list[int] = []

    # Process Speech Commands dataset.
    label_counts = {i: 0 for i in range(5)}

    print("Processing Speech Commands samples...")
    for sample in ds:
        audio = np.array(sample["audio"]["array"], dtype=np.float32)
        sr = sample["audio"]["sampling_rate"]
        label_str = sample.get("label")

        # Map label names from the dataset.
        # Speech Commands uses integer labels — need the features to decode.
        if isinstance(label_str, int):
            label_name = ds.features["label"].int2str(label_str)
        else:
            label_name = str(label_str)

        # Determine our label.
        if label_name in SPECIAL_CLASSES or label_name == "_background_noise_":
            our_label = LABEL_NOISE
        elif label_name == "_silence_" or label_name == "silence":
            our_label = LABEL_SILENCE
        elif label_name.lower() in INTERRUPT_WORDS:
            our_label = LABEL_INTERRUPT
        else:
            our_label = LABEL_SPEECH

        if label_counts[our_label] >= max_samples_per_class:
            continue

        mel = process_sample(audio, sr)
        if mel is not None:
            all_mels.append(mel)
            all_labels.append(our_label)
            label_counts[our_label] += 1

    # Generate synthetic silence samples.
    print("Generating silence samples...")
    silence_needed = max(0, max_samples_per_class - label_counts[LABEL_SILENCE])
    if silence_needed > 0:
        silence_mels = generate_silence_samples(min(silence_needed, 500))
        for mel in silence_mels:
            all_mels.append(mel)
            all_labels.append(LABEL_SILENCE)
            label_counts[LABEL_SILENCE] += 1

    # Generate synthetic wake word samples.
    print("Generating synthetic wake word samples...")
    wake_needed = max(0, max_samples_per_class - label_counts[LABEL_WAKE])
    if wake_needed > 0:
        wake_mels = generate_wake_samples_synthetic(min(wake_needed, 500))
        for mel in wake_mels:
            all_mels.append(mel)
            all_labels.append(LABEL_WAKE)
            label_counts[LABEL_WAKE] += 1

    print(f"Total samples: {len(all_mels)}")
    for label_id, name in enumerate(LABEL_NAMES):
        print(f"  {name}: {label_counts[label_id]}")

    # Shuffle and split.
    rng = np.random.default_rng(42)
    indices = np.arange(len(all_mels))
    rng.shuffle(indices)

    split_idx = int(len(indices) * (1 - validation_split))
    train_indices = indices[:split_idx]
    valid_indices = indices[split_idx:]

    # Stack into arrays: [N, N_MELS, TARGET_FRAMES] -> transpose to [N, TARGET_FRAMES, N_MELS]
    # for Conv1D input (batch, time, features).
    mels_array = np.stack(all_mels, axis=0)  # [N, 128, 48]
    mels_array = np.transpose(mels_array, (0, 2, 1))  # [N, 48, 128]
    labels_array = np.array(all_labels, dtype=np.int32)

    train_mels = mels_array[train_indices]
    train_labels = labels_array[train_indices]
    valid_mels = mels_array[valid_indices]
    valid_labels = labels_array[valid_indices]

    # Save.
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    np.savez(
        os.path.join(OUTPUT_DIR, "train.npz"),
        mels=train_mels,
        labels=train_labels,
    )
    np.savez(
        os.path.join(OUTPUT_DIR, "valid.npz"),
        mels=valid_mels,
        labels=valid_labels,
    )

    meta = {
        "label_names": LABEL_NAMES,
        "num_classes": len(LABEL_NAMES),
        "n_mels": N_MELS,
        "target_frames": TARGET_FRAMES,
        "sample_rate": SAMPLE_RATE,
        "n_fft": N_FFT,
        "hop_length": HOP_LENGTH,
        "train_samples": len(train_mels),
        "valid_samples": len(valid_mels),
        "class_counts": {LABEL_NAMES[k]: v for k, v in label_counts.items()},
    }

    with open(os.path.join(OUTPUT_DIR, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    print(f"Saved to {OUTPUT_DIR}")
    print(f"  train: {len(train_mels)} samples")
    print(f"  valid: {len(valid_mels)} samples")

    # JSON-RPC response.
    result = {
        "jsonrpc": "2.0",
        "id": None,
        "result": {
            "status": "success",
            "output_dir": OUTPUT_DIR,
            "train_samples": len(train_mels),
            "valid_samples": len(valid_mels),
            "class_counts": {LABEL_NAMES[k]: v for k, v in label_counts.items()},
        },
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()

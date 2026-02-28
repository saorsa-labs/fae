#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy", "soundfile"]
# ///
"""Normalize audio to target LUFS, convert sample rate, mix to mono."""

import json
import sys
import os
import numpy as np


def normalize(path: str, output_dir: str, target_lufs: float = -16.0, target_sr: int = 24000) -> dict:
    import soundfile as sf

    y, sr = sf.read(path, dtype="float32", always_2d=True)

    # Mix to mono if stereo.
    if y.shape[1] > 1:
        y = np.mean(y, axis=1)
    else:
        y = y[:, 0]

    # Resample if needed (simple linear interpolation).
    if sr != target_sr:
        duration = len(y) / sr
        new_len = int(duration * target_sr)
        indices = np.linspace(0, len(y) - 1, new_len)
        y = np.interp(indices, np.arange(len(y)), y).astype(np.float32)
        sr = target_sr

    # Measure current loudness (simplified LUFS approximation).
    rms = float(np.sqrt(np.mean(y**2)))
    if rms > 0:
        current_lufs = 20 * np.log10(rms) - 0.691
        gain_db = target_lufs - current_lufs
        gain = 10 ** (gain_db / 20)
        y = y * gain
        # Prevent clipping.
        peak = np.max(np.abs(y))
        if peak > 0.99:
            y = y * (0.99 / peak)

    # Write output.
    basename = os.path.splitext(os.path.basename(path))[0]
    out_path = os.path.join(output_dir, f"{basename}_normalized.wav")
    os.makedirs(output_dir, exist_ok=True)
    sf.write(out_path, y, sr, subtype="PCM_16")

    return {
        "input": path,
        "output": out_path,
        "sample_rate": sr,
        "duration_s": round(len(y) / sr, 2),
        "target_lufs": target_lufs,
        "audio_file": out_path,
    }


def main():
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    path = params.get("input", "")
    output_dir = params.get("audio_output_dir", "/tmp")
    if not path:
        print(json.dumps({"error": "No audio file path provided"}))
        return
    try:
        result = normalize(path, output_dir)
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()

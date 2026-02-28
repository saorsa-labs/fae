#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["librosa", "numpy", "soundfile"]
# ///
"""Convert any audio to 24kHz mono PCM WAV and find the best 3s voiced segment."""

import json
import sys
import os
import numpy as np


def prepare(path: str, output_dir: str) -> dict:
    import librosa
    import soundfile as sf

    # Load and convert to 24kHz mono.
    y, sr = librosa.load(path, sr=24000, mono=True)
    duration = len(y) / sr

    if duration < 2.0:
        return {"error": f"Audio too short ({duration:.1f}s). Need at least 2 seconds."}

    # Find best 3-second voiced segment using energy + voiced frame density.
    target_len = int(3.0 * sr)
    if len(y) <= target_len:
        best_start = 0
        best_segment = y
    else:
        frame_length = int(0.025 * sr)
        hop_length = int(0.010 * sr)
        rms = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
        silence_threshold = 10 ** (-35 / 20)

        best_score = -1.0
        best_start = 0
        step = int(0.5 * sr)  # slide by 0.5s

        for start in range(0, len(y) - target_len, step):
            segment = y[start : start + target_len]
            seg_rms = librosa.feature.rms(y=segment, frame_length=frame_length, hop_length=hop_length)[0]
            voiced_ratio = float(np.mean(seg_rms > silence_threshold))
            mean_energy = float(np.mean(seg_rms))
            # Score: high voiced ratio + good energy, penalize clipping.
            clip_penalty = float(np.sum(np.abs(segment) > 0.98)) / target_len
            score = voiced_ratio * mean_energy * (1.0 - clip_penalty * 10)
            if score > best_score:
                best_score = score
                best_start = start

        best_segment = y[best_start : best_start + target_len]

    # Write output.
    basename = os.path.splitext(os.path.basename(path))[0]
    out_path = os.path.join(output_dir, f"{basename}_voice_sample.wav")
    os.makedirs(output_dir, exist_ok=True)
    sf.write(out_path, best_segment, sr, subtype="PCM_16")

    return {
        "input": path,
        "output": out_path,
        "sample_rate": sr,
        "original_duration_s": round(duration, 2),
        "segment_start_s": round(best_start / sr, 2),
        "segment_duration_s": round(len(best_segment) / sr, 2),
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
        result = prepare(path, output_dir)
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()

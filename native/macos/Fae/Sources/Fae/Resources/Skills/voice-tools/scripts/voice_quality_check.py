#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["librosa", "numpy", "soundfile"]
# ///
"""Voice quality analysis: SNR, clipping, silence ratio, frequency range."""

import json
import sys
import numpy as np


def analyze(path: str) -> dict:
    import librosa
    import soundfile as sf

    y, sr = librosa.load(path, sr=None, mono=True)
    duration = len(y) / sr

    # RMS energy
    rms = float(np.sqrt(np.mean(y**2)))

    # Peak amplitude
    peak = float(np.max(np.abs(y)))

    # Clipping: samples at or near +-1.0
    clip_threshold = 0.99
    clipped = int(np.sum(np.abs(y) >= clip_threshold))
    clip_pct = clipped / len(y) * 100

    # Silence ratio (frames below -40 dB)
    frame_length = int(0.025 * sr)
    hop_length = int(0.010 * sr)
    rms_frames = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
    silence_threshold = 10 ** (-40 / 20)
    silent_frames = int(np.sum(rms_frames < silence_threshold))
    silence_pct = silent_frames / len(rms_frames) * 100

    # Estimated SNR (signal vs quiet portions)
    voiced = rms_frames[rms_frames >= silence_threshold]
    noise = rms_frames[rms_frames < silence_threshold]
    if len(noise) > 0 and np.mean(noise) > 0:
        snr_db = float(20 * np.log10(np.mean(voiced) / np.mean(noise)))
    else:
        snr_db = 60.0  # very clean

    # Frequency range (F0 estimation)
    f0, voiced_flag, _ = librosa.pyin(y, fmin=50, fmax=500, sr=sr)
    f0_voiced = f0[voiced_flag] if voiced_flag is not None else f0[~np.isnan(f0)]
    f0_min = float(np.min(f0_voiced)) if len(f0_voiced) > 0 else 0.0
    f0_max = float(np.max(f0_voiced)) if len(f0_voiced) > 0 else 0.0
    f0_mean = float(np.mean(f0_voiced)) if len(f0_voiced) > 0 else 0.0

    return {
        "file": path,
        "duration_s": round(duration, 2),
        "sample_rate": sr,
        "rms": round(rms, 4),
        "peak": round(peak, 4),
        "clipping_pct": round(clip_pct, 2),
        "silence_pct": round(silence_pct, 1),
        "snr_db": round(snr_db, 1),
        "f0_min_hz": round(f0_min, 1),
        "f0_max_hz": round(f0_max, 1),
        "f0_mean_hz": round(f0_mean, 1),
        "quality": "good" if snr_db > 20 and clip_pct < 1 else "poor",
    }


def main():
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    path = params.get("input", "")
    if not path:
        print(json.dumps({"error": "No audio file path provided"}))
        return
    try:
        result = analyze(path)
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()

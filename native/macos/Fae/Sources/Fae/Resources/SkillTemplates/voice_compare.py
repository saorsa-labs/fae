#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["librosa", "numpy", "scipy", "soundfile"]
# ///
"""Compare two audio files using MFCC + DTW and return a similarity score."""

import json
import sys
import numpy as np


def compare(path_a: str, path_b: str) -> dict:
    import librosa
    from scipy.spatial.distance import cdist

    # Load both files at the same sample rate.
    y_a, sr = librosa.load(path_a, sr=16000, mono=True)
    y_b, _ = librosa.load(path_b, sr=16000, mono=True)

    # Extract MFCCs (13 coefficients).
    mfcc_a = librosa.feature.mfcc(y=y_a, sr=sr, n_mfcc=13).T
    mfcc_b = librosa.feature.mfcc(y=y_b, sr=sr, n_mfcc=13).T

    # DTW distance.
    cost_matrix = cdist(mfcc_a, mfcc_b, metric="cosine")

    n, m = cost_matrix.shape
    dtw = np.full((n + 1, m + 1), np.inf)
    dtw[0, 0] = 0.0
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            dtw[i, j] = cost_matrix[i - 1, j - 1] + min(
                dtw[i - 1, j], dtw[i, j - 1], dtw[i - 1, j - 1]
            )

    # Normalize by path length.
    dtw_distance = float(dtw[n, m]) / (n + m)

    # Convert to similarity score (0-1, higher = more similar).
    similarity = float(max(0.0, 1.0 - dtw_distance))

    return {
        "file_a": path_a,
        "file_b": path_b,
        "dtw_distance": round(dtw_distance, 4),
        "similarity": round(similarity, 4),
        "duration_a_s": round(len(y_a) / sr, 2),
        "duration_b_s": round(len(y_b) / sr, 2),
        "verdict": "similar" if similarity > 0.7 else "different",
    }


def main():
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    input_str = params.get("input", "")
    # Expect two paths separated by whitespace or comma.
    parts = [p.strip() for p in input_str.replace(",", " ").split() if p.strip()]
    if len(parts) < 2:
        print(json.dumps({"error": "Provide two audio file paths separated by space or comma"}))
        return
    try:
        result = compare(parts[0], parts[1])
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()

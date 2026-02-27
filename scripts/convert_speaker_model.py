#!/usr/bin/env python3
"""
Convert Qwen3-Voice-Embedding ONNX model to Core ML for Fae speaker verification.

Usage:
    pip install coremltools onnx huggingface_hub
    python3 scripts/convert_speaker_model.py

This downloads the ONNX model from HuggingFace, converts to Core ML (.mlpackage),
then compiles to .mlmodelc (ready for Xcode / SPM bundling).

Output: native/macos/Fae/Sources/Fae/Resources/Models/SpeakerEncoder.mlmodelc/
"""

import os
import subprocess
import sys
import tempfile

MODEL_REPO = "marksverdhei/Qwen3-Voice-Embedding-12Hz-0.6B-onnx"
ONNX_FILENAME = "model_fp16.onnx"
OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "native", "macos", "Fae", "Sources", "Fae", "Resources", "Models",
)


def main():
    try:
        import coremltools as ct
        import onnx
    except ImportError:
        print("Missing dependencies. Install them:")
        print("  pip install coremltools onnx huggingface_hub")
        sys.exit(1)

    # Download ONNX model from HuggingFace.
    print(f"Downloading {ONNX_FILENAME} from {MODEL_REPO}...")
    try:
        from huggingface_hub import hf_hub_download

        onnx_path = hf_hub_download(repo_id=MODEL_REPO, filename=ONNX_FILENAME)
    except ImportError:
        print("huggingface_hub not installed. Install it:")
        print("  pip install huggingface_hub")
        sys.exit(1)

    print(f"ONNX model: {onnx_path}")

    # Load ONNX model.
    print("Loading ONNX model...")
    model = onnx.load(onnx_path)

    # Convert to Core ML.
    # Input: mel_input with shape (1, 128, T) where T is variable (1-3000 frames).
    print("Converting to Core ML...")
    mlmodel = ct.converters.convert(
        model,
        inputs=[
            ct.TensorType(
                name="mel_input",
                shape=(1, 128, ct.RangeDim(lower_bound=1, upper_bound=3000)),
            )
        ],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    # Save as .mlpackage.
    with tempfile.TemporaryDirectory() as tmpdir:
        mlpackage_path = os.path.join(tmpdir, "SpeakerEncoder.mlpackage")
        print(f"Saving .mlpackage to {mlpackage_path}...")
        mlmodel.save(mlpackage_path)

        # Compile to .mlmodelc using xcrun coremlc.
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        mlmodelc_path = os.path.join(OUTPUT_DIR, "SpeakerEncoder.mlmodelc")

        # Remove existing compiled model if present.
        if os.path.exists(mlmodelc_path):
            import shutil

            shutil.rmtree(mlmodelc_path)

        print(f"Compiling to .mlmodelc at {mlmodelc_path}...")
        result = subprocess.run(
            ["xcrun", "coremlc", "compile", mlpackage_path, OUTPUT_DIR],
            capture_output=True,
            text=True,
        )

        if result.returncode != 0:
            print(f"Compilation failed:\n{result.stderr}")
            sys.exit(1)

    # Verify output.
    if os.path.isdir(mlmodelc_path):
        size_mb = sum(
            os.path.getsize(os.path.join(dirpath, filename))
            for dirpath, _, filenames in os.walk(mlmodelc_path)
            for filename in filenames
        ) / (1024 * 1024)
        print(f"Success: {mlmodelc_path} ({size_mb:.1f} MB)")
    else:
        print("Error: .mlmodelc not found after compilation")
        sys.exit(1)


if __name__ == "__main__":
    main()

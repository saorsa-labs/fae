#!/usr/bin/env python3
"""
Convert WeSpeaker ECAPA-TDNN ONNX model to Core ML for Fae speaker verification.

Usage:
    pip install coremltools onnx onnx2torch huggingface_hub torch
    python scripts/convert_speaker_model.py

This downloads the ONNX model from HuggingFace, converts to PyTorch,
then to Core ML (.mlpackage), and compiles to .mlmodelc.

Model: onnx-community/wespeaker-voxceleb-resnet34-LM
- Input: mel features [B, T, 80] (80 mel bins, variable time frames)
- Output: 256-dim speaker embedding

Output: native/macos/Fae/Sources/Fae/Resources/Models/SpeakerEncoder.mlmodelc/
"""

import os
import subprocess
import sys
import tempfile

MODEL_REPO = "onnx-community/wespeaker-voxceleb-resnet34-LM"
ONNX_FILENAME = "onnx/model.onnx"
OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "native", "macos", "Fae", "Sources", "Fae", "Resources", "Models",
)


def main():
    try:
        import coremltools as ct
        import onnx
        import torch
        from onnx2torch import convert as onnx2torch_convert
    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("Install with:")
        print("  pip install coremltools onnx onnx2torch huggingface_hub torch")
        sys.exit(1)

    # Download ONNX model from HuggingFace.
    print(f"Downloading {ONNX_FILENAME} from {MODEL_REPO}...")
    try:
        from huggingface_hub import hf_hub_download
        onnx_path = hf_hub_download(repo_id=MODEL_REPO, filename=ONNX_FILENAME)
    except ImportError:
        print("huggingface_hub not installed.")
        print("  pip install huggingface_hub")
        sys.exit(1)

    print(f"ONNX model: {onnx_path}")

    # Load ONNX model and convert to PyTorch.
    print("Converting ONNX to PyTorch...")
    onnx_model = onnx.load(onnx_path)
    pytorch_model = onnx2torch_convert(onnx_model)
    pytorch_model.eval()

    # Create example input for tracing.
    # Input shape: [batch=1, time=100, mel_bins=80]
    example_input = torch.randn(1, 100, 80)

    # Trace the model.
    print("Tracing PyTorch model...")
    traced_model = torch.jit.trace(pytorch_model, example_input)

    # Convert to Core ML.
    print("Converting to Core ML...")
    mlmodel = ct.convert(
        traced_model,
        inputs=[
            ct.TensorType(
                name="input_features",
                shape=(1, ct.RangeDim(lower_bound=10, upper_bound=3000), 80),
            )
        ],
        outputs=[
            ct.TensorType(name="embedding"),
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
        print()
        print("Model info:")
        print("  Input: input_features [1, T, 80] (80 mel bins, variable time)")
        print("  Output: embedding [1, 256] (256-dim speaker embedding)")
    else:
        print("Error: .mlmodelc not found after compilation")
        sys.exit(1)


if __name__ == "__main__":
    main()

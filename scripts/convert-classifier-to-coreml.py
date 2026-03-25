#!/usr/bin/env python3
"""Convert Fae's 1D-CNN audio classifiers from safetensors to Core ML.

Usage:
    uv run scripts/convert-classifier-to-coreml.py speech-verifier
    uv run scripts/convert-classifier-to-coreml.py keyword-classifier

Reads model.safetensors + config.json from ~/Library/Application Support/fae/models/<name>/
Outputs <name>.mlmodelc to native/macos/Fae/Sources/Fae/Resources/Models/<Name>/
"""
# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["coremltools>=8.0", "safetensors", "torch", "numpy"]
# ///

import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from safetensors.torch import load_file


class Conv1DClassifier(nn.Module):
    """Matches Fae's MLX Conv1DClassifier architecture exactly."""

    def __init__(self, num_classes: int, input_features: int = 128):
        super().__init__()
        self.conv1 = nn.Conv1d(input_features, 64, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(64, 128, kernel_size=3, padding=1)
        self.conv3 = nn.Conv1d(128, 128, kernel_size=3, padding=1)
        self.classifier = nn.Linear(128, num_classes)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # Input: [B, T, C] — transpose to [B, C, T] for Conv1d
        x = x.transpose(1, 2)
        x = torch.relu(self.conv1(x))
        x = x[:, :, ::2]  # MaxPool stride=2
        x = torch.relu(self.conv2(x))
        x = x[:, :, ::2]  # MaxPool stride=2
        x = torch.relu(self.conv3(x))
        x = x.mean(dim=2)  # Global average pool
        return self.classifier(x)


def remap_weights(state_dict: dict) -> dict:
    """Remap MLX weight names to PyTorch Conv1d format.

    MLX Conv1d stores weight as [out, kW, in] while PyTorch uses [out, in, kW].
    MLX Linear stores weight as [out, in] (same as PyTorch transposed).
    """
    remapped = {}
    for key, tensor in state_dict.items():
        if "conv" in key and "weight" in key:
            # MLX Conv1d: [out_channels, kernel_size, in_channels]
            # PyTorch Conv1d: [out_channels, in_channels, kernel_size]
            remapped[key] = tensor.permute(0, 2, 1)
        elif "classifier.weight" in key:
            # MLX Linear weight is [out, in], PyTorch Linear is [out, in] — same
            remapped[key] = tensor
        else:
            remapped[key] = tensor
    return remapped


def convert(model_name: str):
    app_support = Path.home() / "Library" / "Application Support" / "fae" / "models" / model_name
    config_path = app_support / "config.json"
    weights_path = app_support / "model.safetensors"

    if not config_path.exists() or not weights_path.exists():
        print(f"Error: model files not found at {app_support}")
        sys.exit(1)

    with open(config_path) as f:
        config = json.load(f)

    num_classes = config["num_classes"]
    input_features = config.get("input_features", 128)
    target_frames = config.get("target_frames", 48)
    label_names = config.get("label_names", [f"class_{i}" for i in range(num_classes)])

    print(f"Converting {model_name}: {num_classes} classes, input [{1}, {target_frames}, {input_features}]")

    # Load weights and remap
    state_dict = load_file(str(weights_path))
    state_dict = remap_weights(state_dict)

    # Create PyTorch model and load weights
    model = Conv1DClassifier(num_classes=num_classes, input_features=input_features)
    model.load_state_dict(state_dict)
    model.eval()

    # Trace with example input
    example_input = torch.randn(1, target_frames, input_features)
    traced = torch.jit.trace(model, example_input)

    # Convert to Core ML
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="mel_input",
                shape=(1, target_frames, input_features),
                dtype=np.float16,
            )
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float16)],
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
    )

    # Add metadata
    mlmodel.author = "Fae (Saorsa Labs)"
    mlmodel.short_description = f"Audio classifier: {', '.join(label_names)}"
    mlmodel.version = config.get("version", "1.0")

    # Save as mlpackage first, then compile
    camel_name = model_name.replace("-", "_")
    project_root = Path(__file__).parent.parent
    output_dir = project_root / "native" / "macos" / "Fae" / "Sources" / "Fae" / "Resources" / "Models"
    output_dir.mkdir(parents=True, exist_ok=True)

    package_path = output_dir / f"{camel_name}.mlpackage"
    compiled_path = output_dir / f"{camel_name}.mlmodelc"

    mlmodel.save(str(package_path))
    print(f"Saved mlpackage to {package_path}")

    # Compile to mlmodelc
    import subprocess
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(package_path), str(output_dir)],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        print(f"Compiled to {compiled_path}")
        # Clean up mlpackage
        import shutil
        shutil.rmtree(package_path)
    else:
        print(f"Compilation failed: {result.stderr}")
        print(f"mlpackage saved at {package_path} — compile manually with: xcrun coremlcompiler compile {package_path} {output_dir}")

    # Also save config alongside for the Swift loader
    config_out = output_dir / f"{camel_name}_config.json"
    with open(config_out, "w") as f:
        json.dump(config, f, indent=2)
    print(f"Saved config to {config_out}")

    # Verify
    print(f"\nDone! Core ML model ready for ANE inference.")
    print(f"  Classes: {label_names}")
    print(f"  Input: mel_input [1, {target_frames}, {input_features}] (Float16)")
    print(f"  Output: logits [1, {num_classes}] (Float16)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: convert-classifier-to-coreml.py <speech-verifier|keyword-classifier>")
        sys.exit(1)
    convert(sys.argv[1])

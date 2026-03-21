# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx", "numpy"]
# ///

"""Train a micro speech verifier (~200K params) using MLX.

Loads prepared mel-spectrogram .npz dataset from MUSAN and trains a 1D-CNN
model for 3-class classification: speech, music, noise.

Architecture (same as keyword classifier, 3 classes):
  Input: [batch, 48, 128] mel spectrogram
  Conv1D(128→64, k=3) → ReLU → MaxPool(2)
  Conv1D(64→128, k=3) → ReLU → MaxPool(2)
  Conv1D(128→128, k=3) → ReLU → GlobalAvgPool
  Linear(128→3)
  ~200K params

Output:
  ~/Library/Application Support/fae/models/speech-verifier/
    ├── model.safetensors
    └── config.json
"""

from __future__ import annotations

import json
import os
import sys
import time

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
import numpy as np

DATA_DIR = os.path.expanduser(
    "~/Library/Application Support/fae/training/data/speech-verifier"
)
MODEL_DIR = os.path.expanduser(
    "~/Library/Application Support/fae/models/speech-verifier"
)


class SpeechVerifierModel(nn.Module):
    """Micro 1D-CNN speech verifier.

    Input shape: [batch, time_frames=48, mel_bins=128]
    Output shape: [batch, num_classes=3]
    """

    def __init__(self, num_classes: int = 3, input_features: int = 128) -> None:
        super().__init__()
        self.conv1 = nn.Conv1d(input_features, 64, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(64, 128, kernel_size=3, padding=1)
        self.conv3 = nn.Conv1d(128, 128, kernel_size=3, padding=1)
        self.classifier = nn.Linear(128, num_classes)

    def __call__(self, x: mx.array) -> mx.array:
        x = nn.relu(self.conv1(x))       # [B, 48, 64]
        x = x[:, ::2, :]                 # MaxPool → [B, 24, 64]
        x = nn.relu(self.conv2(x))       # [B, 24, 128]
        x = x[:, ::2, :]                 # MaxPool → [B, 12, 128]
        x = nn.relu(self.conv3(x))       # [B, 12, 128]
        x = mx.mean(x, axis=1)           # GlobalAvgPool → [B, 128]
        x = self.classifier(x)           # [B, 3]
        return x


def load_dataset(split: str = "train") -> tuple[mx.array, mx.array]:
    """Load prepared .npz dataset.

    Data is stored as [N, N_MELS=128, TARGET_FRAMES=48] but the model
    expects [B, T=48, C=128], so we transpose axes 1 and 2.
    """
    path = os.path.join(DATA_DIR, f"{split}.npz")
    data = np.load(path)
    # Transpose from [N, 128, 48] to [N, 48, 128]
    mels = mx.array(data["mels"].astype(np.float32).transpose(0, 2, 1))
    labels = mx.array(data["labels"].astype(np.int32))
    return mels, labels


def count_params(params_dict: dict) -> int:
    """Count total parameters in a nested dict."""
    total = 0
    for v in params_dict.values():
        if isinstance(v, mx.array):
            total += v.size
        elif isinstance(v, dict):
            total += count_params(v)
        elif isinstance(v, list):
            for item in v:
                if isinstance(item, dict):
                    total += count_params(item)
                elif isinstance(item, mx.array):
                    total += item.size
    return total


def evaluate(model: SpeechVerifierModel, mels: mx.array, labels: mx.array,
             label_names: list[str], batch_size: int = 64) -> dict:
    """Evaluate model accuracy."""
    num_samples = mels.shape[0]
    num_classes = len(label_names)
    correct = 0
    total = 0
    class_correct = [0] * num_classes
    class_total = [0] * num_classes

    for i in range(0, num_samples, batch_size):
        batch_mels = mels[i:i + batch_size]
        batch_labels = labels[i:i + batch_size]
        logits = model(batch_mels)
        preds = mx.argmax(logits, axis=-1)
        mx.eval(preds)

        for pred, label in zip(np.array(preds), np.array(batch_labels)):
            total += 1
            label_int = int(label)
            class_total[label_int] += 1
            if int(pred) == label_int:
                correct += 1
                class_correct[label_int] += 1

    overall_acc = correct / max(total, 1)
    class_acc = {}
    for i, name in enumerate(label_names):
        class_acc[name] = class_correct[i] / max(class_total[i], 1)
    return {"overall": overall_acc, "per_class": class_acc}


def main() -> None:
    params: dict = {}
    if len(sys.argv) > 1:
        try:
            request = json.loads(sys.argv[1])
            if isinstance(request, dict):
                params = request.get("params", request)
        except json.JSONDecodeError:
            pass

    epochs = params.get("epochs", 50)
    batch_size = params.get("batch_size", 64)
    learning_rate = params.get("learning_rate", 1e-3)

    print("Loading training data...")
    train_mels, train_labels = load_dataset("train")
    print(f"  Train: {train_mels.shape[0]} samples, shape {train_mels.shape}")

    print("Loading validation data...")
    valid_mels, valid_labels = load_dataset("valid")
    print(f"  Valid: {valid_mels.shape[0]} samples, shape {valid_mels.shape}")

    meta_path = os.path.join(DATA_DIR, "meta.json")
    with open(meta_path) as f:
        meta = json.load(f)

    num_classes = meta["num_classes"]
    input_features = meta["input_features"]
    label_names = meta["label_names"]

    print(f"Training {num_classes}-class speech verifier...")
    model = SpeechVerifierModel(num_classes=num_classes, input_features=input_features)
    print(f"  Parameters: {count_params(model.parameters()):,}")

    optimizer = optim.Adam(learning_rate=learning_rate)

    def loss_fn(model: SpeechVerifierModel, mels: mx.array, labels: mx.array) -> mx.array:
        logits = model(mels)
        return mx.mean(nn.losses.cross_entropy(logits, labels))

    loss_and_grad_fn = nn.value_and_grad(model, loss_fn)
    num_train = train_mels.shape[0]
    start_time = time.time()

    for epoch in range(epochs):
        indices = mx.array(np.random.permutation(num_train))
        shuffled_mels = train_mels[indices]
        shuffled_labels = train_labels[indices]

        epoch_loss = 0.0
        num_batches = 0

        for i in range(0, num_train, batch_size):
            batch_mels = shuffled_mels[i:i + batch_size]
            batch_labels = shuffled_labels[i:i + batch_size]
            loss, grads = loss_and_grad_fn(model, batch_mels, batch_labels)
            optimizer.update(model, grads)
            mx.eval(model.parameters(), optimizer.state)
            epoch_loss += loss.item()
            num_batches += 1

        avg_loss = epoch_loss / max(num_batches, 1)

        if (epoch + 1) % 5 == 0 or epoch == 0:
            val_metrics = evaluate(model, valid_mels, valid_labels, label_names, batch_size)
            elapsed = time.time() - start_time
            per_class = " | ".join(
                f"{n}={val_metrics['per_class'][n]:.3f}" for n in label_names
            )
            print(
                f"  Epoch {epoch + 1:3d}/{epochs} | "
                f"loss={avg_loss:.4f} | "
                f"val_acc={val_metrics['overall']:.4f} | "
                f"{per_class} | "
                f"time={elapsed:.1f}s"
            )

    # Final evaluation.
    final_metrics = evaluate(model, valid_mels, valid_labels, label_names, batch_size)
    print(f"\nFinal validation accuracy: {final_metrics['overall']:.4f}")
    for cls_name, acc in final_metrics["per_class"].items():
        print(f"  {cls_name}: {acc:.4f}")

    # Save model.
    os.makedirs(MODEL_DIR, exist_ok=True)

    weights = dict(model.parameters())
    flat_weights: dict[str, mx.array] = {}

    def flatten_weights(d: dict, prefix: str = "") -> None:
        for k, v in d.items():
            key = f"{prefix}{k}" if prefix else k
            if isinstance(v, mx.array):
                flat_weights[key] = v
            elif isinstance(v, dict):
                flatten_weights(v, f"{key}.")
            elif isinstance(v, list):
                for i, item in enumerate(v):
                    if isinstance(item, dict):
                        flatten_weights(item, f"{key}.{i}.")
                    elif isinstance(item, mx.array):
                        flat_weights[f"{key}.{i}"] = item

    flatten_weights(weights)
    mx.save_safetensors(os.path.join(MODEL_DIR, "model.safetensors"), flat_weights)

    config = {
        "model_type": "speech_verifier",
        "num_classes": num_classes,
        "input_features": input_features,
        "target_frames": meta["target_frames"],
        "sample_rate": meta["sample_rate"],
        "label_names": label_names,
    }
    with open(os.path.join(MODEL_DIR, "config.json"), "w") as f:
        json.dump(config, f, indent=2)

    print(f"\nModel saved to {MODEL_DIR}")
    print(f"  model.safetensors: {os.path.getsize(os.path.join(MODEL_DIR, 'model.safetensors')):,} bytes")


if __name__ == "__main__":
    main()

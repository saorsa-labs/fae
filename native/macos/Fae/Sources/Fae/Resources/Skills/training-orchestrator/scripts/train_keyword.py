# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx", "numpy"]
# ///

"""Train a micro keyword classifier (~200K params) using MLX.

Loads prepared mel-spectrogram .npz dataset and trains a 1D-CNN model
for 5-class keyword classification: interrupt, wake, speech, silence, noise.

Architecture:
  Input: [batch, 48, 128] mel spectrogram
  Conv1D(128→64, k=3) → ReLU → MaxPool(2)
  Conv1D(64→128, k=3) → ReLU → MaxPool(2)
  Conv1D(128→128, k=3) → ReLU → GlobalAvgPool
  Linear(128→5)
  ~200K params

Output:
  ~/Library/Application Support/fae/models/keyword-classifier/
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
    "~/Library/Application Support/fae/training/data/keyword"
)
MODEL_DIR = os.path.expanduser(
    "~/Library/Application Support/fae/models/keyword-classifier"
)


class KeywordClassifier(nn.Module):
    """Micro 1D-CNN keyword classifier.

    Input shape: [batch, time_frames=48, mel_bins=128]
    Output shape: [batch, num_classes=5]
    """

    def __init__(self, num_classes: int = 5, input_features: int = 128) -> None:
        super().__init__()
        # Conv1D operates on last dimension, so we keep [B, T, C] layout.
        # MLX Conv1d: input [B, T, C_in] -> output [B, T', C_out]
        self.conv1 = nn.Conv1d(input_features, 64, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(64, 128, kernel_size=3, padding=1)
        self.conv3 = nn.Conv1d(128, 128, kernel_size=3, padding=1)
        self.classifier = nn.Linear(128, num_classes)

    def __call__(self, x: mx.array) -> mx.array:
        # x: [B, 48, 128]
        x = nn.relu(self.conv1(x))       # [B, 48, 64]
        x = x[:, ::2, :]                 # MaxPool stride 2 → [B, 24, 64]
        x = nn.relu(self.conv2(x))       # [B, 24, 128]
        x = x[:, ::2, :]                 # MaxPool stride 2 → [B, 12, 128]
        x = nn.relu(self.conv3(x))       # [B, 12, 128]
        x = mx.mean(x, axis=1)           # GlobalAvgPool → [B, 128]
        x = self.classifier(x)           # [B, 5]
        return x


def load_dataset(split: str = "train") -> tuple[mx.array, mx.array]:
    """Load prepared .npz dataset."""
    path = os.path.join(DATA_DIR, f"{split}.npz")
    data = np.load(path)
    mels = mx.array(data["mels"].astype(np.float32))
    labels = mx.array(data["labels"].astype(np.int32))
    return mels, labels


def evaluate(model: KeywordClassifier, mels: mx.array, labels: mx.array, batch_size: int = 64) -> dict:
    """Evaluate model accuracy, overall and per-class."""
    num_samples = mels.shape[0]
    correct = 0
    total = 0
    class_correct = [0] * 5
    class_total = [0] * 5

    for i in range(0, num_samples, batch_size):
        batch_mels = mels[i : i + batch_size]
        batch_labels = labels[i : i + batch_size]
        logits = model(batch_mels)
        preds = mx.argmax(logits, axis=-1)
        mx.eval(preds)

        preds_np = np.array(preds)
        labels_np = np.array(batch_labels)

        for pred, label in zip(preds_np, labels_np):
            total += 1
            label_int = int(label)
            class_total[label_int] += 1
            if int(pred) == label_int:
                correct += 1
                class_correct[label_int] += 1

    overall_acc = correct / max(total, 1)
    class_acc = {}
    label_names = ["interrupt", "wake", "speech", "silence", "noise"]
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

    # Load meta for config.
    meta_path = os.path.join(DATA_DIR, "meta.json")
    with open(meta_path) as f:
        meta = json.load(f)

    num_classes = meta["num_classes"]
    input_features = meta["n_mels"]

    print(f"Training {num_classes}-class keyword classifier...")
    model = KeywordClassifier(num_classes=num_classes, input_features=input_features)

    # Count parameters.
    num_params = sum(p.size for p in model.parameters().values() if isinstance(p, mx.array))
    # For nested structures, flatten.
    def count_params(params_dict: dict) -> int:
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

    num_params = count_params(model.parameters())
    print(f"  Parameters: {num_params:,}")

    optimizer = optim.Adam(learning_rate=learning_rate)

    def loss_fn(model: KeywordClassifier, mels: mx.array, labels: mx.array) -> mx.array:
        logits = model(mels)
        return mx.mean(nn.losses.cross_entropy(logits, labels))

    loss_and_grad_fn = nn.value_and_grad(model, loss_fn)

    num_train = train_mels.shape[0]
    start_time = time.time()

    for epoch in range(epochs):
        # Shuffle training data each epoch.
        indices = mx.array(np.random.permutation(num_train))
        shuffled_mels = train_mels[indices]
        shuffled_labels = train_labels[indices]

        epoch_loss = 0.0
        num_batches = 0

        for i in range(0, num_train, batch_size):
            batch_mels = shuffled_mels[i : i + batch_size]
            batch_labels = shuffled_labels[i : i + batch_size]

            loss, grads = loss_and_grad_fn(model, batch_mels, batch_labels)
            optimizer.update(model, grads)
            mx.eval(model.parameters(), optimizer.state)

            epoch_loss += loss.item()
            num_batches += 1

        avg_loss = epoch_loss / max(num_batches, 1)

        if (epoch + 1) % 5 == 0 or epoch == 0:
            val_metrics = evaluate(model, valid_mels, valid_labels, batch_size)
            elapsed = time.time() - start_time
            print(
                f"  Epoch {epoch + 1:3d}/{epochs} | "
                f"loss={avg_loss:.4f} | "
                f"val_acc={val_metrics['overall']:.4f} | "
                f"interrupt={val_metrics['per_class']['interrupt']:.4f} | "
                f"wake={val_metrics['per_class']['wake']:.4f} | "
                f"time={elapsed:.1f}s"
            )

    # Final evaluation.
    final_metrics = evaluate(model, valid_mels, valid_labels, batch_size)
    print(f"\nFinal validation accuracy: {final_metrics['overall']:.4f}")
    for cls_name, acc in final_metrics["per_class"].items():
        print(f"  {cls_name}: {acc:.4f}")

    # Save model.
    os.makedirs(MODEL_DIR, exist_ok=True)

    weights = dict(model.parameters())
    flat_weights = {}
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
        "model_type": "keyword_classifier",
        "num_classes": num_classes,
        "input_features": input_features,
        "target_frames": meta["target_frames"],
        "sample_rate": meta["sample_rate"],
        "n_fft": meta["n_fft"],
        "hop_length": meta["hop_length"],
        "n_mels": meta["n_mels"],
        "label_names": meta["label_names"],
        "num_params": num_params,
        "validation_accuracy": final_metrics["overall"],
        "per_class_accuracy": final_metrics["per_class"],
    }

    with open(os.path.join(MODEL_DIR, "config.json"), "w") as f:
        json.dump(config, f, indent=2)

    print(f"\nModel saved to {MODEL_DIR}")

    # JSON-RPC response.
    result = {
        "jsonrpc": "2.0",
        "id": None,
        "result": {
            "status": "success",
            "model_dir": MODEL_DIR,
            "num_params": num_params,
            "validation_accuracy": final_metrics["overall"],
            "per_class_accuracy": final_metrics["per_class"],
        },
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()

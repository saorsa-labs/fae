---
license: mit
tags:
- coreml
- speaker-embedding
- speaker-verification
- speaker-diarization
- wespeaker
- neural-engine
base_model: pyannote/wespeaker-voxceleb-resnet34-LM
pipeline_tag: audio-classification
---

# WeSpeaker-ResNet34-LM — CoreML

CoreML conversion of [WeSpeaker ResNet34-LM](https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM) for Apple Neural Engine.

Produces 256-dimensional L2-normalized speaker embeddings from audio.

## Model Details

| Detail | Value |
|--------|-------|
| Architecture | ResNet34 with statistics pooling |
| Parameters | ~6.6M |
| Input | 80-bin log-mel spectrogram (16kHz) |
| Output | 256-dim L2-normalized speaker embedding |
| BatchNorm | Fused into Conv2d at conversion time |

## Usage

```swift
let model = try await WeSpeakerModel.fromPretrained(backend: .coreML)
let embedding = model.embed(audio: samples, sampleRate: 16000)
let similarity = WeSpeakerModel.cosineSimilarity(embeddingA, embeddingB)
```

## Variants

| Variant | Backend | Model ID |
|---------|---------|----------|
| MLX | GPU | [aufklarer/WeSpeaker-ResNet34-LM-MLX](https://huggingface.co/aufklarer/WeSpeaker-ResNet34-LM-MLX) |
| **CoreML** | **Neural Engine** | **aufklarer/WeSpeaker-ResNet34-LM-CoreML** |

## Links

- **Swift library**: [soniqo/speech-swift](https://github.com/soniqo/speech-swift)
- **Original model**: [pyannote/wespeaker-voxceleb-resnet34-LM](https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM)

---

## Links

- **Blog**: [blog.ivan.digital](https://blog.ivan.digital)
- **Library Docs**: [soniqo.audio](https://soniqo.audio)

# Voice Enrollment & Speaker Recognition Research

**Date**: 2026-03-21  
**Purpose**: Deep research into voice biometrics for Fae — enrollment, verification, and security

---

## Executive Summary

Fae already has a **mature voice identity system** with enrollment, verification, liveness detection, and role-based access control. This research identifies opportunities to upgrade the speaker embedding model from the current mel-spectral fallback to a **neural speaker encoder**, add **anti-spoofing** capabilities, and improve enrollment UX.

### Key Findings

1. **Current Fae implementation is solid** — CoreML-ready, actor-isolated, with fallback mode
2. **WeSpeaker ResNet34-LM** is the gold-standard model (14M downloads), with ready-made CoreML conversion
3. **Anti-spoofing** (deepfake/replay detection) models are emerging but not yet CoreML-ready
4. **Enrollment best practices** suggest 5-10 samples across varied conditions

---

## Current Fae Implementation

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Fae Voice Identity                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐    ┌───────────────────┐                  │
│  │ AudioCapture     │───▶│ CoreMLSpeaker     │                  │
│  │ Manager (16kHz)  │    │ Encoder (640-dim) │                  │
│  └──────────────────┘    └─────────┬─────────┘                  │
│                                    │                            │
│                          ┌─────────▼─────────┐                  │
│                          │ SpeakerProfile    │                  │
│                          │ Store (cosine)    │                  │
│                          └─────────┬─────────┘                  │
│                                    │                            │
│  ┌──────────────────┐    ┌─────────▼─────────┐                  │
│  │ VoiceIdentity    │◀───│ SpeakerGate       │                  │
│  │ Policy (ACL)     │    │ State             │                  │
│  └──────────────────┘    └───────────────────┘                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | File | Description |
|-----------|------|-------------|
| `CoreMLSpeakerEncoder` | `ML/CoreMLSpeakerEncoder.swift` | Embedding engine with mel-spectral fallback (640-dim) |
| `SpeakerProfileStore` | `ML/SpeakerProfileStore.swift` | Profile storage, matching, roles (owner/trusted/guest/fae_self) |
| `SpeakerEnrollmentView` | `SpeakerEnrollmentView.swift` | Guided 3-sample enrollment UI |
| `VoiceIdentityTool` | `Tools/VoiceIdentityTool.swift` | Programmatic enrollment/matching |
| `VoiceIdentityPolicy` | `Core/VoiceIdentityPolicy.swift` | Risk-based access control |
| `SpeakerGateState` | `Pipeline/SpeakerGateState.swift` | Streaming verification state |
| `SettingsSpeakerTab` | `SettingsSpeakerTab.swift` | Settings UI for voice identity |

### Current Capabilities

1. **Enrollment**: Guided 3-sample flow with quality checks
2. **Roles**: Owner, Trusted, Guest, Fae Self (echo rejection)
3. **Matching**: Cosine similarity with configurable thresholds
4. **Liveness**: Spectral variance, high-freq ratio, F0 variance, proximity ratio
5. **Echo Rejection**: Detects Fae's own TTS output
6. **Progressive Enrollment**: Auto-strengthens profiles up to cap
7. **Stale Pruning**: Removes old embeddings (180-day default)

### Current Limitation

The `CoreMLSpeakerEncoder` uses a **mel-spectral fallback** (640-dim) when no neural model is found:
- Can distinguish TTS from human speech ✓
- **Cannot** reliably discriminate between different humans ✗
- Requires `SpeakerEncoder.mlmodelc` for full speaker verification

---

## HuggingFace Model Survey

### Top Speaker Embedding Models

| Model | Downloads | Format | Dims | Notes |
|-------|-----------|--------|------|-------|
| [pyannote/wespeaker-voxceleb-resnet34-LM](https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM) | 14M | PyTorch | 256 | Gold standard, used by pyannote diarization |
| [aufklarer/WeSpeaker-ResNet34-LM-CoreML](https://huggingface.co/aufklarer/WeSpeaker-ResNet34-LM-CoreML) | 650 | CoreML | 256 | **Ready to use**, 13MB, Neural Engine |
| [aufklarer/WeSpeaker-ResNet34-LM-MLX](https://huggingface.co/aufklarer/WeSpeaker-ResNet34-LM-MLX) | 28K | MLX | 256 | Apple Silicon GPU, 26MB |
| [nvidia/speakerverification_en_titanet_large](https://huggingface.co/nvidia/speakerverification_en_titanet_large) | 129K | NeMo | 192 | TitaNet, requires conversion |
| [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) | 6.9K | CoreML | 256 | Full diarization pipeline |

### Anti-Spoofing / Deepfake Detection

| Model | Downloads | Notes |
|-------|-----------|-------|
| [Gustking/wav2vec2-large-xlsr-deepfake](https://huggingface.co/Gustking/wav2vec2-large-xlsr-deepfake-detection) | 35K | Wav2Vec2-based, needs conversion |
| [MelodyMachine/Deepfake-audio-detection](https://huggingface.co/MelodyMachine/Deepfake-audio-detection-model-2) | 3.9K | Wav2Vec2, 15 likes |
| [MTUCI/AASIST3](https://huggingface.co/MTUCI/AASIST3) | 610 | AASIST architecture |
| [ash56/ssl-aasist](https://huggingface.co/ash56/ssl-aasist) | 47 | Self-supervised AASIST |

### Recommended Model: WeSpeaker-ResNet34-LM-CoreML

**Why this model:**
1. **Production-ready**: Pre-compiled `.mlmodelc`, no conversion needed
2. **Neural Engine**: Runs on Apple Neural Engine, ~5ms inference
3. **Proven**: Based on pyannote/wespeaker with 14M downloads
4. **Compatible dimensions**: 256-dim vs current 640-dim (Fae handles both)
5. **MIT licensed**: No usage restrictions

**Download:**
```bash
hf download aufklarer/WeSpeaker-ResNet34-LM-CoreML --local-dir Models/SpeakerEncoder
```

**Expected files:**
- `wespeaker.mlmodelc/` — Compiled CoreML model (~13MB)
- `config.json` — Model configuration

---

## Enrollment Best Practices

### Industry Standards

| Parameter | Recommended | Fae Current | Notes |
|-----------|-------------|-------------|-------|
| Minimum samples | 3 | 3 | ✓ Matches |
| Optimal samples | 5-10 | 3 | Could increase |
| Sample duration | 3-5 seconds | 4 seconds | ✓ Good |
| Voice quality check | Required | ✓ | `hasUsableSpeech` |
| Varied conditions | Recommended | ✗ | Single session |
| Text-independent | Preferred | ✓ | User chooses phrase |

### Enrollment Quality Metrics

Fae's `SpeakerProfileStore.consistencyScore()` computes pairwise cosine similarity — this is correct.

**Additional metrics to consider:**
1. **Intra-speaker variance**: std(cosine(embeddings[i], centroid))
2. **SNR estimation**: From audio quality analysis
3. **Phonetic coverage**: Different phonemes represented

### Recommended Enrollment Flow (Enhanced)

```
Phase 1: Quick Enrollment (current)
├── 3 samples × 4 seconds
├── Quality gating per sample
└── Consistency check ≥ 0.70

Phase 2: Progressive Strengthening (current)
├── Auto-enroll on confident matches
├── Cap at 10 embeddings
└── Prune stale (>180 days)

Phase 3: Multi-condition Enrollment (NEW)
├── Prompt for varied conditions
│   ├── "Try speaking a bit louder"
│   ├── "Try from further away"
│   └── "Try in the morning/evening"
├── Background noise resilience
└── Suggested over days, not sessions
```

---

## Security Analysis

### Threat Model

| Threat | Current Mitigation | Gap |
|--------|-------------------|-----|
| **Replay attack** (recorded voice) | Liveness heuristics | ML anti-spoofing would be stronger |
| **Deepfake/TTS synthesis** | Echo rejection (fae_self) | No general deepfake detection |
| **Far-field capture** | Proximity ratio check | Could add acoustic analysis |
| **Multi-speaker confusion** | Threshold gating | Enrollment sample diversity |
| **Ambient noise injection** | Quality gating | Could add noise estimation |

### Liveness Detection (Current)

`CoreMLSpeakerEncoder.checkLiveness()` combines:

1. **Spectral variance** (30% weight): Dynamic formant variation
2. **High-frequency ratio** (30%): Codec compression artifacts
3. **F0 variance** (25%): Pitch contour dynamics via autocorrelation
4. **Proximity ratio** (15%): Direct-to-reverberant energy (crest factor)

**Threshold**: `score < 0.3` → suspicious

### Recommended Enhancements

1. **Neural anti-spoofing**: Add a dedicated model for deepfake/replay detection
2. **Cross-session enrollment**: Encourage enrollment across different times/conditions
3. **Acoustic environment profiling**: Learn typical room characteristics
4. **Confidence calibration**: Adjust thresholds based on enrollment depth

---

## Implementation Recommendations

### Phase 1: Drop-in Model Upgrade (Low Effort)

Replace mel-spectral fallback with WeSpeaker CoreML:

```swift
// In CoreMLSpeakerEncoder.load()
// Download and extract wespeaker.mlmodelc to:
// Bundle.main.url(forResource: "wespeaker", withExtension: "mlmodelc", subdirectory: "Models")
```

**Changes:**
- Rename/symlink `wespeaker.mlmodelc` → `SpeakerEncoder.mlmodelc`
- Update mel-spec pipeline to 80-bin (WeSpeaker expects 80 vs current 128)
- Update embedding dimension handling (256 vs 640)

### Phase 2: Enrollment UX Improvements (Medium Effort)

1. **Multi-day enrollment prompts**:
   ```swift
   // After 24h, if enrollmentCount < 5
   "Your voice profile is building — want to add another sample?"
   ```

2. **Condition variation**:
   ```swift
   // Prompt different scenarios
   ["Speak naturally", "A bit louder please", "Try from across the room"]
   ```

3. **Enrollment health dashboard**:
   - Consistency score visualization
   - Sample diversity indicator
   - Suggested improvements

### Phase 3: Anti-Spoofing (Higher Effort)

Convert and integrate a deepfake detection model:

1. **Convert wav2vec2 model to CoreML**:
   ```bash
   coremltools.convert(model, inputs=[...], minimum_deployment_target=coremltools.target.macOS13)
   ```

2. **Add `DeepfakeDetector` actor**:
   ```swift
   actor DeepfakeDetector {
       func checkAuthenticity(audio: [Float], sampleRate: Int) async throws -> (isReal: Bool, confidence: Float)
   }
   ```

3. **Integrate into liveness pipeline**:
   ```swift
   let liveness = checkLiveness(mel: mel, numFrames: numFrames, audio: audio24k)
   let authenticity = try await deepfakeDetector.checkAuthenticity(audio: audio, sampleRate: sampleRate)
   // Combine scores
   ```

---

## Model Comparison Matrix

| Feature | Mel-Spectral (Current) | WeSpeaker CoreML | WeSpeaker MLX |
|---------|------------------------|------------------|---------------|
| Embedding dim | 640 | 256 | 256 |
| Human discrimination | Poor | Excellent | Excellent |
| TTS rejection | Good | Good | Good |
| Inference time | ~2ms | ~5ms | ~3ms |
| Memory | ~0MB | ~13MB | ~26MB |
| Neural Engine | No | Yes | No (GPU) |
| Dependencies | None | CoreML | MLX |

---

## Action Items

### Immediate (This Week)
- [ ] Download `aufklarer/WeSpeaker-ResNet34-LM-CoreML`
- [ ] Test model loading in `CoreMLSpeakerEncoder`
- [ ] Verify embedding dimension compatibility with `SpeakerProfileStore`
- [ ] Update mel-spec pipeline (128→80 bins, if needed)

### Short-term (This Month)
- [ ] Integrate as primary encoder with fallback preserved
- [ ] Add enrollment sample diversity prompts
- [ ] Improve SettingsSpeakerTab with enrollment health metrics
- [ ] Document migration path for existing profiles (re-enroll on dimension mismatch)

### Medium-term (Next Quarter)
- [ ] Convert deepfake detection model to CoreML
- [ ] Implement multi-session enrollment prompts
- [ ] Add acoustic environment profiling
- [ ] Evaluate AASIST for anti-spoofing

---

## References

1. [pyannote-audio speaker embedding](https://github.com/pyannote/pyannote-audio)
2. [WeSpeaker: Production-ready Speaker Recognition](https://github.com/wenet-e2e/wespeaker)
3. [ASVspoof 2021: Audio Deepfake Detection](https://www.asvspoof.org/)
4. [AASIST: Audio Anti-Spoofing using SSL](https://arxiv.org/abs/2110.01200)
5. [VoxCeleb Speaker Recognition Dataset](https://www.robots.ox.ac.uk/~vgg/data/voxceleb/)

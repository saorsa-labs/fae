# Voice Identity — Speaker Verification for Fae

Fae can recognize who is speaking using voice biometrics. This enables:

- **Owner verification** — Fae knows it's you, not a stranger or a YouTube video
- **Tool gating** — sensitive operations (bash, file write, desktop automation) only execute for the owner's voice
- **Progressive enrollment** — your voice profile strengthens over time with every conversation

## How It Works

### Speaker Embedding

Fae uses an ECAPA-TDNN speaker encoder (extracted from Qwen3-TTS) running via Core ML on Apple's Neural Engine. Each speech segment is converted to a 1024-dimensional mathematical vector (an "x-vector") that captures the unique characteristics of the speaker's voice.

**Processing pipeline per speech segment:**

1. **Resample** 16 kHz capture audio → 24 kHz (model input rate)
2. **Log-mel spectrogram** — 128 mel bands, 1024-point FFT, 256-sample hop (Accelerate vDSP)
3. **Core ML inference** — ECAPA-TDNN on Neural Engine → 1024-dim embedding
4. **L2 normalize** the embedding vector
5. **Cosine similarity** match against enrolled profiles

### Cosine Similarity

Two voice embeddings are compared using cosine similarity (range: -1 to +1). Same speaker typically scores 0.7–0.95; different speakers score 0.1–0.5.

### Thresholds

| Threshold | Default | Purpose |
|-----------|---------|---------|
| `threshold` | 0.70 | General speaker matching |
| `ownerThreshold` | 0.75 | Stricter owner verification for tool gating |

## Owner Enrollment

### Automatic First-Launch Enrollment

The first person to speak to Fae after installation is automatically enrolled as the **owner**. This happens during the onboarding flow — no explicit enrollment step is needed.

### Progressive Enrollment

Each time Fae recognizes the owner's voice, the embedding from that interaction is added to the owner's profile (up to `maxEnrollments`, default 50). The profile's centroid (average embedding) is recomputed, making recognition more robust over time.

This handles natural voice variation — morning voice, tired voice, different microphones, background noise levels.

## Tool Gating

When `requireOwnerForTools` is enabled (default: true), Fae strips tool schemas from the LLM system prompt for unrecognized voices. This means:

- **Owner voice** → full tool access (bash, file write, web search, etc.)
- **Unknown voice** → conversational responses only, no tool execution
- **Text input** → always trusted (typed by someone physically at the device)

This prevents a scenario where someone else's voice (or audio from a speaker/TV) triggers Fae to execute commands.

## Configuration

Settings are in `~/Library/Application Support/fae/config.toml` under the `[speaker]` section:

```toml
[speaker]
enabled = true
threshold = 0.70
ownerThreshold = 0.75
requireOwnerForTools = true
progressiveEnrollment = true
maxEnrollments = 50
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Master toggle for voice identity |
| `threshold` | float | `0.70` | Cosine similarity threshold for speaker matching |
| `ownerThreshold` | float | `0.75` | Stricter threshold for owner verification |
| `requireOwnerForTools` | bool | `true` | Gate tool execution behind owner voice |
| `progressiveEnrollment` | bool | `true` | Add new embeddings to known profiles over time |
| `maxEnrollments` | int | `50` | Maximum stored embeddings per speaker profile |

## Privacy

- **No audio is stored** — only mathematical vectors (1024 floats per embedding)
- **Everything is local** — embeddings never leave the device
- **No cloud processing** — Core ML runs entirely on-device (Neural Engine preferred)
- **Profiles stored as JSON** — `~/Library/Application Support/fae/speakers.json`
- **Embeddings are not reversible** — you cannot reconstruct audio from an embedding

## Model Details

| Property | Value |
|----------|-------|
| Architecture | ECAPA-TDNN (speaker encoder from Qwen3-TTS) |
| Source | `marksverdhei/Qwen3-Voice-Embedding-12Hz-0.6B-onnx` |
| Format | Core ML (.mlmodelc, converted from ONNX fp16) |
| Size | ~18 MB compiled |
| Embedding dimension | 1024 |
| Input | Log-mel spectrogram (128 bins, 24 kHz) |
| Compute | Apple Neural Engine (CPU fallback) |
| Latency | ~5-15 ms per segment on M-series chips |

## Building the Model

The Core ML model must be converted from ONNX before building:

```bash
pip install coremltools onnx huggingface_hub
python3 scripts/convert_speaker_model.py
```

This downloads the ONNX model, converts to Core ML, and compiles to `.mlmodelc` in the bundle resources directory. The conversion is a one-time step.

## Troubleshooting

### Fae doesn't recognize me

- Check logs for "speaker not recognized" — the similarity score may be below threshold
- Lower `threshold` in config (e.g., 0.60) for more lenient matching
- Try re-enrolling: delete `speakers.json` and restart — the next voice becomes owner
- Ensure you're speaking clearly with consistent microphone positioning

### Tools don't work for me

- Check if `requireOwnerForTools` is `true` and your voice isn't matching as owner
- Verify owner enrollment: check `speakers.json` for an "owner" profile
- Text injection always bypasses voice gating — use the text input as a fallback

### Model not loading

- Check that `SpeakerEncoder.mlmodelc` exists in `Resources/Models/`
- Run the conversion script: `python3 scripts/convert_speaker_model.py`
- Check logs for "Speaker encoder load failed" — Fae continues without voice identity

### Re-enrollment

To start fresh with voice identity:

```bash
rm ~/Library/Application\ Support/fae/speakers.json
```

On next launch, the first speaker will be enrolled as owner.

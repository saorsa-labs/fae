# fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

---

A real-time voice conversation system in Rust. Fae is a calm, helpful Scottish voice assistant that runs entirely on-device — no cloud services required.

## Pipeline

```
Mic (16kHz) ──> AEC ──┬──> VAD ──> STT ──> Identity Gate ──> Conversation Gate ──> LLM ──> TTS ──> Speaker (24kHz)
                      │                                            ^                                    │
                      └──> Wakeword ───────────────────────────────┘                                    │
                                                                                                        │
                      AEC Reference Buffer <────────────────────────────────────────────────────────────┘
```

### Stage Details

| Stage | Description | Implementation |
|-------|-------------|----------------|
| **Capture** | Records 16kHz mono from the default microphone | `cpal` |
| **AEC** | Removes speaker echo from mic signal via adaptive filter | `fdaf-aec` (FDAF/NLMS) |
| **Wakeword** | MFCC+DTW keyword detection on raw audio, runs in parallel with VAD | Custom (`rustfft`) |
| **VAD** | Detects speech boundaries with energy-based analysis + dynamic silence threshold | Custom |
| **STT** | Transcribes speech segments to text | `parakeet-rs` (NVIDIA Parakeet ONNX) |
| **Identity Gate** | Primary user enrollment + best-effort speaker matching via voiceprint | Custom |
| **Conversation Gate** | Wake word / stop phrase gating, name-gated barge-in, auto-idle | Custom |
| **LLM** | Generates responses with streaming token output | `mistralrs` (GGUF, Metal GPU) |
| **TTS** | Synthesizes speech from text | Kokoro-82M (ONNX, misaki-rs G2P) |
| **Playback** | Plays 24kHz audio, feeds reference buffer for AEC | `cpal` |

### Key Features

- **Acoustic Echo Cancellation**: DSP-based FDAF adaptive filter removes speaker output from the mic signal, enabling natural barge-in
- **Wake Word Detection**: MFCC feature extraction + DTW matching against reference WAV recordings — no external ML model needed
- **Name-Gated Barge-In**: During assistant speech, only interrupts when user says "Fae" (not on background noise)
- **Dynamic Silence Threshold**: Shorter silence gap (300ms) during assistant speech for faster barge-in, normal (700ms) otherwise
- **Conversation Gate**: Wake phrase ("hi Fae") activates, stop phrase ("that will do Fae") deactivates, auto-idle on timeout
- **Voice Identity**: Voiceprint-based speaker matching so Fae responds primarily to the registered user
- **Agent Mode**: Optional tool-capable agent via `saorsa-agent` + `saorsa-ai`

## Canvas Integration

Fae includes a visual canvas pane powered by [saorsa-canvas](https://github.com/saorsa-labs/saorsa-canvas) that displays rich content alongside voice conversations.

### What It Does

- **Charts**: Bar, line, pie, and scatter plots rendered via plotters
- **Images**: Display images from URLs or base64 data
- **Formatted text**: Markdown, code blocks with syntax highlighting, tables
- **Export**: Save canvas content as PNG, JPEG, SVG, or PDF

### MCP Tools

The AI agent has access to canvas tools via the Model Context Protocol:

| Tool | Description |
|------|-------------|
| `canvas_render` | Push charts, images, or text to the canvas |
| `canvas_interact` | Report user interactions (touch, voice) |
| `canvas_export` | Export session to image/document format |

### Remote Canvas Server

Fae can connect to a remote `canvas-server` instance via WebSocket for multi-device scenarios. Set the server URL in Settings or in `config.toml`:

```toml
[canvas]
server_url = "ws://localhost:9473/ws/sync"
```

When connected, all canvas operations sync in real-time between the local pane and the server.

## Configuration

Config file: `~/.config/fae/config.toml`

```toml
[audio]
input_sample_rate = 16000
output_sample_rate = 24000

[aec]
enabled = true
fft_size = 1024
step_size = 0.05

[wakeword]
enabled = false          # Set to true + provide reference WAVs to enable
references_dir = "~/.fae/wakeword"
threshold = 0.5
num_mfcc = 13

[vad]
threshold = 0.01
min_silence_duration_ms = 700

[stt]
model_id = "istupakov/parakeet-tdt-0.6b-v3-onnx"

[llm]
backend = "local"
model_id = "unsloth/Qwen3-4B-Instruct-2507-GGUF"

[tts]
model_dtype = "q4f16"

[conversation]
wake_word = "hi fae"
stop_phrase = "that will do fae"
idle_timeout_s = 30

[barge_in]
enabled = true
barge_in_silence_ms = 300
```

### Wake Word Setup

1. Create the references directory: `mkdir -p ~/.fae/wakeword`
2. Record 3-5 WAV files of yourself saying "Fae" (16kHz, mono, 16-bit)
3. Place them in `~/.fae/wakeword/`
4. Set `wakeword.enabled = true` in config

The spotter extracts MFCC features from each reference and uses DTW to match against live audio. More reference recordings improve robustness across different speaking styles and volumes.

## Building

```bash
# Debug build (GUI, default features)
cargo build

# Release build with Metal GPU acceleration (macOS)
cargo build --release
```

Requires:
- Rust 1.85+
- Metal Toolchain (macOS): `xcodebuild -downloadComponent MetalToolchain`
- cmake (for espeak-ng build via misaki-rs)

Canvas dependencies (`canvas-core`, `canvas-mcp`, `canvas-renderer`) are published on [crates.io](https://crates.io/crates/canvas-core). For local development against a saorsa-canvas checkout, `[patch.crates-io]` overrides are configured in `Cargo.toml`.

## License

AGPL-3.0

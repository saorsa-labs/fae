# fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

---

A real-time voice conversation system in Rust. Fae is a calm, helpful Scottish voice assistant that runs entirely on-device — no cloud services required.

## Installation

### For Users (Installer / Release Package)

Fae should be installed from GitHub Releases, not built from source.

1. Open the [latest release](https://github.com/saorsa-labs/fae/releases/latest)
2. Download the installer/package for your platform
3. Open it and launch Fae
4. Grant microphone permissions on first run

No terminal commands are required for normal user installs.

### For Developers (CLI / Source Builds)

If you are running `cargo`/`just` commands, you are in the developer setup path.
Use the "Developer Setup (CLI / Source Builds)" section near the end of this README.

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
- **Pi Coding Agent**: Delegates coding, file editing, and research tasks to [Pi](https://github.com/badlogic/pi-mono)
- **Self-Update**: Automatic update checks for both Fae and Pi from GitHub releases
- **Task Scheduler**: Background periodic tasks (update checks, future user-defined tasks)
- **Runtime Model Switching**: Switch between cloud models (Claude, GPT-4) and local models mid-conversation using voice commands

## Runtime Model Switching

Fae can switch between different LLM models during a conversation using voice commands. No restart needed.

### Quick Start

**Switching models:**
```
You: "Fae, switch to Claude"
Fae: "Switching to Claude Opus 4."

You: "use the local model"
Fae: "Switching to fae-qwen3."
```

**Finding out what's available:**
```
You: "list models"
Fae: "I have access to claude-opus-4, gpt-4o, fae-qwen3. Currently using claude-opus-4."
```

### How It Works

1. **Tier-based auto-selection** — At startup, Fae selects the highest-tier available model (Claude Opus 4 > GPT-4o > Gemini 2.0 Flash > local Qwen3)
2. **User priority override** — Set a `priority` field in `~/.pi/agent/models.json` to prefer a specific model
3. **Interactive picker** — If multiple top-tier models exist, Fae shows a list and asks you to choose
4. **Voice commands** — Switch models mid-conversation, query the active model, list all available models

### Supported Commands

| Voice Command | What It Does |
|---------------|--------------|
| `"switch to Claude"` | Switches to best available Anthropic model |
| `"use the local model"` | Switches to on-device model (fae-qwen3) |
| `"list models"` | Lists all available models |
| `"what model are you using?"` | Tells you the current active model |
| `"help"` | Lists all available voice commands |

The GUI topbar shows the active model: **🤖 anthropic/claude-opus-4**

**Full documentation:** [docs/model-switching.md](docs/model-switching.md)

## Memory

Fae includes an automated memory system designed for long-running conversations.

- Human-readable guide: [`docs/Memory.md`](docs/Memory.md)
- Technical architecture plan: [`docs/memory-architecture-plan.md`](docs/memory-architecture-plan.md)

## Pi Integration

Fae integrates with the [Pi coding agent](https://github.com/badlogic/pi-mono) to handle coding tasks, file editing, shell commands, and research — all triggered by voice.

### How It Works

```
User speaks "fix the login bug in my website"
  → STT → LLM (Qwen 3) reads Pi skill → decides to delegate to Pi
  → Pi uses Fae's local LLM for reasoning
  → Pi executes: read files, edit code, run tests
  → Fae narrates progress via TTS
```

### Pi Detection & Installation

Fae automatically manages Pi:

1. **Bundled**: Release archives include a Pi binary — works offline on first run
2. **PATH detection**: If Pi is already installed, Fae uses it
3. **Auto-install**: Downloads the latest Pi from GitHub releases if not found
4. **Updates**: Scheduler checks for new Pi versions daily

Pi install locations:
- **macOS / Linux**: `~/.local/bin/pi`
- **Windows**: `%LOCALAPPDATA%\pi\pi.exe`

### AI Configuration

All AI provider configuration lives in `~/.pi/agent/models.json`. Fae reads this file for both local and cloud providers — there is no separate API key configuration.

Fae automatically writes a `"fae-local"` provider entry pointing to its on-device LLM, so Pi can use Fae's brain with zero cloud dependency.

### Troubleshooting

| Issue | Solution |
|-------|----------|
| Pi not found | Check `~/.local/bin/pi` exists and is executable |
| Pi auto-install fails | Check internet connectivity; manually download from [Pi releases](https://github.com/badlogic/pi-mono/releases) |
| LLM server not responding | Restart Fae; check logs for model loading errors |
| Update check fails | Network error — Fae will retry on next scheduled check |
| macOS Gatekeeper blocks Pi | Fae clears quarantine automatically; if blocked, run `xattr -c ~/.local/bin/pi` |

### Self-Update System

Fae checks GitHub releases for new versions of both itself and Pi:

- **Update preference**: Ask (default) / Always / Never — configurable in Settings
- **Check frequency**: Daily via the built-in scheduler
- **Update notification**: Banner appears in the GUI when updates are available

### Scheduler

The background scheduler runs periodic tasks:

| Task | Frequency | Description |
|------|-----------|-------------|
| Fae update check | Daily | Check GitHub for new Fae releases |
| Pi update check | Daily | Check GitHub for new Pi releases |

Scheduler state is persisted in `~/.config/fae/scheduler.json`.

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
context_size_tokens = 32768   # Optional override; auto-tuned from RAM if omitted

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

### Wake Word Setup (Developer / Manual)

1. Create the references directory: `mkdir -p ~/.fae/wakeword`
2. Record 3-5 WAV files of yourself saying "Fae" (16kHz, mono, 16-bit)
3. Place them in `~/.fae/wakeword/`
4. Set `wakeword.enabled = true` in config

The spotter extracts MFCC features from each reference and uses DTW to match against live audio. More reference recordings improve robustness across different speaking styles and volumes.

## Developer Setup (CLI / Source Builds)

This section is for developers. End users should use release installers/packages.

### Prerequisites

- Rust 1.85+
- `just` (recommended)
- Metal Toolchain (macOS): `xcodebuild -downloadComponent MetalToolchain`
- cmake (for espeak-ng build via misaki-rs)

### Common Developer Commands

```bash
# Build GUI binary
just build-gui

# Run app locally
just run

# Tests
just test

# Lint
just lint
```

### Raw Cargo (Advanced)

On macOS, use an SDK sysroot for bindgen-based dependencies before calling `cargo` directly:

```bash
export SDKROOT="$(xcrun --show-sdk-path)"
export BINDGEN_EXTRA_CLANG_ARGS="-isysroot $SDKROOT"
export CFLAGS="-isysroot $SDKROOT"
cargo build --features gui
```

Canvas dependencies (`canvas-core`, `canvas-mcp`, `canvas-renderer`) are published on [crates.io](https://crates.io/crates/canvas-core). For local development against a saorsa-canvas checkout, `[patch.crates-io]` overrides are configured in `Cargo.toml`.

## License

AGPL-3.0

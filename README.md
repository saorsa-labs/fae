# fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

---

A real-time voice conversation system in Rust. Fae is a calm, helpful Scottish voice assistant that runs entirely on-device — no cloud services required.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           fae Pipeline                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Mic (16kHz) ──> AEC ──┬──> VAD ──> STT ──> Identity ──> LLM ──> TTS ──> Speaker │
│                        │                                            │          │
│                        └──> Wakeword ────────────────────────────────┘          │
│                              │                                               │
│                        AEC Ref Buffer <──────────────────────────────────┘      │
│                                                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Where Does the LLM Run?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     fae_llm Agent Loop                               │
│         (our tools, tool calling, sandboxing, security)             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                      │
│    ┌─────────────────────┐       ┌─────────────────────┐              │
│    │   Local Backend    │       │    API Backend     │              │
│    │                    │       │                    │              │
│    │  ┌─────────────┐  │       │  ┌─────────────┐  │              │
│    │  │  mistralrs │  │       │  │  OpenAI    │  │              │
│    │  │  (Qwen 3)  │  │       │  │  Anthropic │  │              │
│    │  └─────────────┘  │       │  └─────────────┘  │              │
│    │     GPU/Metal    │       │    Remote API     │              │
│    └─────────────────────┘       └─────────────────────┘              │
│                                                                      │
│    Both use: SAME agent loop, SAME tools, SAME sandbox               │
│                                                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

## LLM Provider Architecture

### Core Principle

**The agent loop, tool calling, and sandboxing are the same regardless of where the model runs.** The only difference is WHERE the LLM inference happens:

| Backend | Where Model Runs | Tools/Agent | Use Case |
|---------|-----------------|--------------|----------|
| `Local` | Your machine (mistralrs/Qwen3) | ✅ Yes | Default, offline, privacy |
| `Api` | Remote (OpenAI/Anthropic/etc) | ✅ Yes | Cloud, more capable models |

### Tool Modes (Security Boundaries)

Tools are controlled by **tool mode** - a security boundary that defines what the LLM can do:

| Mode | Available Tools | Use Case |
|------|-----------------|----------|
| `read_only` | `read` | Safe browsing, file inspection |
| `full` | `read`, `bash`, `edit`, `write` | Coding, full agent tasks |

**The LLM decides** what tools to use based on your request:
- "Read that file" → uses `read` tool
- "Fix this bug" → uses `read` + `bash` + `edit` tools
- "What's in this directory?" → uses `read` tool

## Security Model

### Tool Sandboxing

All tool execution is sandboxed within the workspace root:

1. **Path Validation**: All file operations are validated against the workspace root
2. **No System Directories**: Writes to `/bin`, `/usr`, `/etc` are blocked
3. **No Directory Traversal**: `..` escaping is prevented
4. **Output Sanitization**: Binary blobs (base64, hex dumps) are removed from tool output

### Input Sanitization

Command arguments are sanitized to prevent shell injection:

```rust
// Blocked characters in commands:
- \n, \r  (command injection)
- >, <       (redirection)
- |           (pipes)
- ;, &        (command chaining)
- $           (variable expansion)
- `           (command substitution)
- \, control chars
```

### Error Message Sanitization

Error messages don't leak internal paths:
```
❌ "path /Users/dave/project/... escapes sandbox /Users/dave/..."
✅ "path escapes workspace boundary: <workspace>/src/main.rs"
```

## Pipeline Stages

| Stage | Description | Implementation |
|-------|-------------|----------------|
| **Capture** | Records 16kHz mono from mic | `cpal` |
| **AEC** | Removes speaker echo | `fdaf-aec` (FDAF/NLMS) |
| **Wakeword** | MFCC+DTW detection | Custom (`rustfft`) |
| **VAD** | Speech boundary detection | Custom |
| **STT** | Speech to text | `parakeet-rs` (Parakeet ONNX) |
| **Identity** | Speaker verification | Custom |
| **LLM** | Response generation | `fae_llm` (Local/Api) |
| **TTS** | Text to speech | Kokoro-82M (ONNX) |
| **Playback** | Audio output | `cpal` |

## Installation

### Users

Fae should be installed from GitHub Releases, not built from source.

1. Open [latest release](https://github.com/saorsa-labs/fae/releases/latest)
2. Download the installer for your platform
3. Launch and grant microphone permissions

### Developers

```bash
# Build GUI binary
just build-gui

# Run locally
just run

# Tests
just test
```

## Configuration

Config file: `~/.config/fae/config.toml`

```toml
[llm]
# Backend: local or api
backend = "local"

# Local model (when backend = local)
model_id = "unsloth/Qwen3-4B-Instruct-2507-GGUF"
context_size_tokens = 32768

# OR API model (when backend = api)
# api_url = "https://api.openai.com/v1"
# api_key = "sk-..."
# api_model = "gpt-4o"

[llm.tool_mode]
# Security mode: read_only or full
mode = "full"

[audio]
input_sample_rate = 16000
output_sample_rate = 24000

[conversation]
wake_word = "hi fae"
stop_phrase = "that will do fae"
```

## Runtime Model Switching

Switch models during conversation using voice commands:

```
You: "Fae, switch to Claude"
Fae: "Switching to Claude Opus 4."

You: "use the local model"
Fae: "Switching to fae-qwen3."

You: "list models"
Fae: "I have access to claude-opus-4, gpt-4o, fae-qwen3."
```

## Tools

### Available Tools

| Tool | Description | Mode |
|------|-------------|------|
| `read` | Read file contents with pagination | read_only, full |
| `bash` | Execute shell commands | full |
| `edit` | Apply text edits/diffs | full |
| `write` | Create/overwrite files | full |

### Canvas Tools

| Tool | Description |
|------|-------------|
| `canvas_render` | Render charts, images, text |
| `canvas_interact` | Handle user interactions |
| `canvas_export` | Export to PNG/PDF |

## Memory

Fae includes an automated memory system:

- Guide: [`docs/Memory.md`](docs/Memory.md)

## Canvas Integration

Visual canvas powered by saorsa-canvas:

- **Charts**: Bar, line, pie, scatter
- **Images**: URL or base64
- **Export**: PNG, JPEG, SVG, PDF

## Self-Update

Fae checks GitHub releases daily for updates.

## Developer Commands

```bash
just run           # Run app
just build-gui     # Build GUI
just test          # Run tests
just lint          # Lint code
just fmt           # Format code
```

## License

AGPL-3.0

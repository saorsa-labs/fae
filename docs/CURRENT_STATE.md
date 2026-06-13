# Fae — Current State

> What fae actually is today, not what was planned.
> Last updated: 2026-06-13

## Tech Stack (v0.8.189)

- **Primary runtime language**: Swift macOS app (no embedded Rust core / C ABI in the active runtime path)
- **Portable UI shell**: Rust `fae-ui-shell` for the canonical orb, whisper pill, Messages/Scheduler/Skills panels, and the new orb-owned Settings panel; Ubuntu WebKitGTK CI now proves the opaque Settings panel renders under Xvfb
- **Daemon ship gate**: Release builds embed `fae-daemon` next to the Swift host and enforce a generated `models.lock` (size + SHA-256, pinned HF revision) before Gemma loads
- **UI**: Rust orb host for new product surfaces; SwiftUI + AppKit remain as migration/legacy surfaces including Settings (legacy)
- **ML Framework**: MLX (Apple Silicon, on-device only)
- **Database**: SQLite via GRDB + sqlite-vec (ANN) + FTS5
- **Update**: Sparkle 2 (EdDSA signed)

## Voice Pipeline

**Current (Qwen fallback — active until mlx-swift-lm ships Gemma 4 support):**
```
Microphone (16kHz) → VAD (Silero v6) → Speaker ID (ECAPA-TDNN)
  → STT (Qwen3-ASR 1.7B) → LLM (Qwen3.5) → TTS (Kokoro-82M) → Speaker
```

**Target (Gemma 4 — pending [mlx-swift-lm#180](https://github.com/ml-explore/mlx-swift-lm/pull/180)):**
```
<32GB:  Mic → VAD → Speaker ID → Gemma 4 E4B/E2B (audio-direct, ASR+LLM unified)
          → TTS (Kokoro-82M) → Speaker
≥32GB:  Mic → VAD → Speaker ID → Gemma 4 E2B (ASR) → Gemma 4 26B-A4B (LLM)
          → TTS (Kokoro-82M) → Speaker
```

Auto model selection by RAM (current Qwen fallback → Gemma 4 target):

| RAM | Current (Qwen) | Target (Gemma 4) | Context |
|-----|---------------|------------------|---------|
| <8 GB | Qwen3.5-2B OptiQ | Gemma 4 E2B unified | 32K → 128K |
| 8-15 GB | Qwen3.5-4B | Gemma 4 E2B unified | 32K → 128K |
| 16-24 GB | Qwen3.5-9B Unsloth | Gemma 4 E4B unified | 32K → 128K |
| 24-31 GB | Qwen3.5-9B Unsloth | Gemma 4 E4B unified | 32K → 128K |
| ≥32 GB | Qwen3.5-9B Unsloth | E2B (ASR) + 26B-A4B (LLM) | 256K |

Gemma 4 E4B benchmarked 2026-04-02: 100% tool calling, 100% Fae capability, 100% assistant fit, 100% serialization, 90% MMLU. Matches Qwen3.5-9B at half the params with native audio input.

## Key Capabilities

- **37 built-in tools** (bash, calendar, mail, web_search, screenshot, click, etc.)
- **30 built-in skills** (forge, toolbox, channels, training-orchestrator, mail-himalaya, CalDAV/CardDAV productivity, etc.)
- **Orb-owned Settings panel** (Rust/wry): bridge-synced settings snapshot/set controls for tool access, thinking, temperature, TTS speed, awareness cadence, and privacy posture; Linux panels use `build_gtk` and have a CI screenshot artifact guard
- **Fail-closed daemon model lock**: `fae-daemon` verifies the bundled Gemma `models.lock` before mistral.rs load; tampered weights exit with structured fatal stderr and code `78`
- **~23 scheduled tasks** (memory reflection, overnight research, morning briefing, etc.)
- **Memory**: hybrid ANN (60%) + FTS5 (40%) search, entity graph (persons/orgs/locations)
- **Self-improvement**: implicit feedback → meta-optimization (directive, config, skills, memory seeds via hill-climbing) → SFT/DPO export → LoRA training → evaluation → deploy
- **Channels**: Discord, WhatsApp, iMessage
- **Agent delegation**: Claude Code, Codex, Gemini, Copilot via ACP
- **Proactive**: always-on camera presence detection, screen monitoring, overnight research

## Vision Models

Dual-VLM stack for progressive visual awareness:

| RAM | Fast VLM (always-on) | Deep VLM (on-demand) |
|-----|----------------------|----------------------|
| <16 GB | disabled | disabled |
| 16+ GB | SmolVLM2-256M (<1GB, presence detection, screen triage) | SmolVLM2-500M (1.8GB, detailed screenshot/camera analysis) |

Both VLMs load alongside STT/LLM/TTS. SmolVLM2-500M scored 73% on Fae's 15-scenario vision eval (2026-03-26); Qwen3-VL-4B is legacy.

## x0x Integration

**Status: Planned, not implemented.** "Powered by x0x" branding exists in UI but network integration is not wired. Fae currently has no Saorsa Rust dependencies. The vision is for Fae to join the x0x network as an agent — discovering other Fae instances, collaborating with AI agents, and creating applications via gossip.

## Legacy

The `legacy/rust-core/` directory contains the abandoned Rust implementation. It is not used by current Swift code. ADRs 002 and 003 document the historical Rust architecture (both marked Superseded).

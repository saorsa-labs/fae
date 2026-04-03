# Fae — Current State

> What fae actually is today, not what was planned.
> Last updated: 2026-04-03

## Tech Stack (v0.8.189)

- **Language**: Pure Swift (no Rust, no C bindings)
- **UI**: SwiftUI + AppKit
- **ML Framework**: MLX (Apple Silicon, on-device only)
- **Database**: SQLite via GRDB + sqlite-vec (ANN) + FTS5
- **Update**: Sparkle 2 (EdDSA signed)

## Voice Pipeline

```
Microphone (16kHz) → VAD (Silero v6) → Speaker ID (ECAPA-TDNN)
  → STT (Qwen3-ASR 1.7B) → LLM (Qwen3.5) → TTS (Kokoro-82M) → Speaker
```

Auto model selection by RAM:
- >=16 GB: Qwen3.5-9B Unsloth (32K context)
- >=8 GB: Qwen3.5-4B (32K context)
- <8 GB: Qwen3.5-2B OptiQ (32K context)

## Key Capabilities

- **37 built-in tools** (bash, calendar, mail, web_search, screenshot, click, etc.)
- **22 skills** (voice-identity, forge, toolbox, channels, training-orchestrator, etc.)
- **~23 scheduled tasks** (memory reflection, overnight research, morning briefing, etc.)
- **Memory**: hybrid ANN (60%) + FTS5 (40%) search, entity graph (persons/orgs/locations)
- **Self-improvement**: implicit feedback → SFT/DPO export → LoRA training → evaluation → deploy
- **Channels**: Discord, WhatsApp, iMessage
- **Agent delegation**: Claude Code, Codex, Gemini, Copilot via ACP
- **Proactive**: always-on camera presence detection, screen monitoring, overnight research

## x0x Integration

**Status: Planned, not implemented.** "Powered by x0x" branding exists in UI but network integration is not wired. Fae currently has no Saorsa Rust dependencies. The vision is for Fae to join the x0x network as an agent — discovering other Fae instances, collaborating with AI agents, and creating applications via gossip.

## Legacy

The `legacy/rust-core/` directory contains the abandoned Rust implementation. It is not used by current Swift code. ADRs 002 and 003 document the historical Rust architecture (both marked Superseded).

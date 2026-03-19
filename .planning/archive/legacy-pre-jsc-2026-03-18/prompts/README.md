# Fae Pure-Swift Rebuild — Team Prompts

## Overview

6 self-contained prompts, one per phase. Each has enough context for a team to execute independently. Phases are sequential — each depends on the prior phase being complete.

## Prompt Files

| Phase | File | Team Focus | Est. Weeks |
|-------|------|-----------|------------|
| 0 | `phase-0-foundation.md` | Package.swift, stubs, rewire UI, compile | 1 |
| 1 | `phase-1-voice-pipeline.md` | Audio I/O, VAD, STT, LLM, TTS, pipeline coordinator | 4-5 |
| 2 | `phase-2-memory.md` | SQLite (GRDB), embeddings, recall/capture, backup | 2 |
| 3 | `phase-3-tools-agent.md` | 15 tools, agent loop, approval system | 3 |
| 4 | `phase-4-background-systems.md` | Scheduler, skills, channels, intelligence, canvas, x0x | 3 |
| 5 | `phase-5-polish-ship.md` | UI updates, justfile, CI/CD, cleanup, signing, smoke test | 2 |

**Total**: ~15-17 weeks, ~16K new Swift LOC replacing 106K Rust lines.

## Dependency Chain

```
Phase 0 (Foundation)
    ↓ FaeCore stub, FaeEventBus, protocols, all UI compiles
Phase 1 (Voice Pipeline)
    ↓ Working speech-to-speech conversation
Phase 2 (Memory)
    ↓ Persistent memory with recall/capture
Phase 3 (Tools & Agent)
    ↓ Tool execution, agent loop, approval system
Phase 4 (Background Systems)
    ↓ Scheduler, skills, channels, intelligence
Phase 5 (Polish & Ship)
    ↓ Production-ready signed app bundle
```

## Branch Strategy

All work on `feature/pure-swift-rebuild` branched from `main`. Each phase team commits to this branch sequentially.

## Key Rule

**Do NOT delete the Rust `src/` directory until Phase 5.** All teams reference it to understand the logic they're porting. Phase 5 cleans up Rust artifacts after everything else works.

## Full Plan Reference

The complete monolithic plan (all phases together) is at:
`.planning/plans/pure-swift-rebuild.md`

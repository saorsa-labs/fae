# Phase 2.3: Script-Facing Typed Adapters

## Goal
Expose typed bridge helpers so JS consumes stable objects instead of legacy tool argument/result shapes.

## Tasks
- Define the initial script-safe `fae.*` surface.
- Prefer adapters such as `fae.calendar.listWeek()` over exposing raw `action` strings everywhere.
- Keep the adapter layer thin over `ToolExecutor` and structured results.
- Add tests for adapter contracts and backwards compatibility.

## Acceptance
- JS scripts can use typed helpers for core orchestration tasks.
- Bridge contracts are documented and test-covered.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```

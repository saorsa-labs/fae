# Phase 4.1: Prompting & Model Routing

## Goal
Teach the model when to emit a JS tool program versus normal tool calls.

## Tasks
- Update prompt assembly with concise JS tool-program guidance.
- Add examples for when to prefer scripts and when to prefer single tool calls.
- Keep prompt size controlled; do not bloat the main system prompt.
- Add tests or fixtures for output routing decisions where possible.

## Acceptance
- Prompting guidance is explicit and minimal.
- JS tool-program generation is opt-in for the right task shapes.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```

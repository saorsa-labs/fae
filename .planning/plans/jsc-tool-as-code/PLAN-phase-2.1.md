# Phase 2.1: Structured Tool Result Primitives

## Goal
Introduce a structured result path for scripts without breaking prose outputs.

## Tasks
- Extend `ToolResult` or add a parallel script-result envelope.
- Keep existing `output: String` behavior intact for current LLM/tool flows.
- Define serialization rules for structured results.
- Add tests for tools returning prose-only, structured-only, and both.

## Acceptance
- Existing tool callers continue to work.
- Script path can access structured data without prose parsing.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```

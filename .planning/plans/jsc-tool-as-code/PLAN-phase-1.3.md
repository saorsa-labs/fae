# Phase 1.3: Script Budgets & Cooperative Cancellation

## Goal
Prevent runaway tool programs with host-enforced budgets and cancellation.

## Tasks
- Add `ScriptBudget` for max tool invocations, max wall-clock runtime, and max concurrency.
- Enforce budgets in `JSCRuntime` and the bridge layer.
- Add cooperative cancellation on turn end and runtime timeout.
- Make budget failures explicit and auditable.
- Test timeout, over-budget, and cancellation scenarios.

## Acceptance
- A script cannot exceed configured budgets.
- Cancellation works when a turn is superseded or manually stopped.
- Budget failures return structured errors.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```

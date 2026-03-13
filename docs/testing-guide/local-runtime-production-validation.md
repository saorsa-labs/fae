# Local Runtime Production Validation

Use this checklist before shipping changes to Fae's worker-backed local runtime.

Current product path:

- single Qwen3.5 text model for conversation and tools
- on-demand Qwen3-VL for vision
- legacy dual / concierge path treated as compatibility coverage only

## Primary command

From `native/macos/Fae`:

```bash
just prod-check
```

This runs:

1. `swift build`
2. `swift test list`
3. targeted runtime diagnostics regression (`swift test --disable-swift-testing --filter ...`)
4. targeted config/runtime regression (`swift test --disable-swift-testing --filter ...`)
5. operator worker smoke check
6. concierge worker smoke check (legacy compatibility coverage)
7. `xcodebuild -resolvePackageDependencies -scheme Fae -derivedDataPath .build/xcode-derived -quiet`
8. `xcodebuild build -scheme Fae -destination 'platform=macOS' -configuration Debug -derivedDataPath .build/xcode-derived -quiet`

## Why these checks matter

### `swift build`
Confirms the SwiftPM development build still compiles with the current vendored runtime stack.

### `swift test list`
Confirms test discovery still works. This is important because filtered Swift tests previously degraded into misleading `0 tests` runs.

### Targeted runtime diagnostics regression
Validates that local stack diagnostics still report the active local model state consistently, including:

- loaded text-model state
- current route / fallback state
- worker health diagnostics

### Targeted config/runtime regression
Confirms the runtime still persists and returns config values that affect pipeline behavior.

### Worker smoke checks
Launches the app in worker mode directly for both roles:

- `operator`
- `concierge`

The `operator` smoke check is required for the current product path.
The `concierge` smoke check remains useful as compatibility coverage because the codepath still exists, but it is not the default local architecture.

These checks catch startup regressions in:

- worker argument parsing
- worker transport setup
- vendored Kokoro/Misaki packaging side effects
- basic request/ack flow

### `xcodebuild build`
Confirms the macOS app bundle still builds cleanly through the Xcode path, not just SwiftPM.

## Current expectations

At this point the production local runtime should satisfy:

- single-model Qwen3.5 local text inference is the default path
- local Cowork requests still enter the main local pipeline
- text inference remains worker-backed
- vision remains on-demand rather than startup-loaded
- tool execution remains in the app process
- diagnostics expose worker/runtime/fallback state
- if legacy dual mode is explicitly enabled, compatibility diagnostics still behave coherently

## If `xcodebuild` fails unexpectedly

Prefer an isolated DerivedData path for validation:

```bash
cd native/macos/Fae
rm -rf .build/xcode-derived
xcodebuild -resolvePackageDependencies -scheme Fae -derivedDataPath .build/xcode-derived -quiet
xcodebuild build -scheme Fae -destination 'platform=macOS' -configuration Debug -derivedDataPath .build/xcode-derived -quiet
```

This avoids stale mixed-architecture artifacts in the global Xcode DerivedData directory.

## Remaining caution

A successful `prod-check` is the minimum bar for local runtime changes. For model-loading, vision-loading, concurrency, or tool-routing changes, also do an interactive manual smoke run in the app UI.

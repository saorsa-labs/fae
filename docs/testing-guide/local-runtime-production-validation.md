# Local Runtime Production Validation

Use this checklist before shipping changes to the worker-backed local Pipeline Fae runtime.

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
6. concierge worker smoke check
7. `xcodebuild -resolvePackageDependencies -scheme Fae -derivedDataPath .build/xcode-derived -quiet`
8. `xcodebuild build -scheme Fae -destination 'platform=macOS' -configuration Debug -derivedDataPath .build/xcode-derived -quiet`

## Why these checks matter

### `swift build`
Confirms the SwiftPM development build still compiles with the current vendored runtime stack.

### `swift test list`
Confirms test discovery still works. This is important because filtered Swift tests previously degraded into misleading `0 tests` runs.

### Targeted runtime diagnostics regression
Validates that local stack diagnostics still report:

- operator loaded state
- concierge loaded state
- current route
- fallback reason

### Targeted config/runtime regression
Confirms the runtime still persists and returns config values that affect pipeline behavior.

### Worker smoke checks
Launches the app in worker mode directly for both roles:

- `operator`
- `concierge`

This catches startup regressions in:

- worker argument parsing
- worker transport setup
- vendored Kokoro/Misaki packaging side effects
- basic request/ack flow

### `xcodebuild build`
Confirms the macOS app bundle still builds cleanly through the Xcode path, not just SwiftPM.

## Current expectations

At this point the production local runtime should satisfy:

- dual-model local routing is active
- local Cowork requests still enter the main local pipeline
- operator and concierge inference are worker-backed
- tool execution remains in the app process
- inference priority is `operator > Kokoro > concierge`
- diagnostics expose worker/runtime/fallback state

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

A successful `prod-check` is the minimum bar for local runtime changes. For model-loading, concurrency, or tool-routing changes, also do an interactive manual smoke run in the app UI.

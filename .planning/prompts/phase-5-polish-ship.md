# Phase 5: Polish & Ship — Production-Ready Release

## Your Mission

Finalize the pure Swift Fae for release: update all UI files that still reference old patterns, update the build system (justfile, CI/CD), clean up the Rust artifacts, and verify the full end-to-end experience.

**Deliverable**: Signed, notarized `.app` bundle that passes the full smoke test.

---

## Prerequisites (completed by Phases 0–4)

- Pure Swift app with all features working:
  - Voice pipeline (speak → hear response)
  - Memory (recall across sessions)
  - Tools & agent (bash, files, web, Apple ecosystem, approval)
  - Scheduler (11 tasks on schedule)
  - Skills (Python subprocess)
  - Channels (Discord/WhatsApp)
  - Intelligence (morning briefing, noise budget)
  - Canvas, credentials, x0x listener, diagnostics

---

## Tasks

### 5.1 — Onboarding Flow

**Update `OnboardingController.swift`**:

Currently queries the Rust backend for onboarding state via `sendCommand(name: "onboarding.get_state")`. Replace with direct `FaeCore` calls:

```swift
// OLD:
commandSender?.sendCommand(name: "onboarding.get_state", payload: [:])
// NEW:
let isOnboarded = faeCore.getOnboardingState()

// OLD:
commandSender?.sendCommand(name: "onboarding.complete", payload: [:])
// NEW:
faeCore.completeOnboarding()
```

Also update:
- `OnboardingNativeView.swift` — if it passes `commandSender`
- `OnboardingWelcomeScreen.swift`, `OnboardingPermissionsScreen.swift`, `OnboardingReadyScreen.swift`
- `OnboardingTTSHelper.swift` — may need to use MLX TTS instead of old engine
- `OnboardingWindowController.swift`

**Onboarding flow should**:
1. Show welcome screen
2. Request microphone permission (`AVAudioSession.requestRecordPermission`)
3. Optionally test TTS voice
4. Mark onboarding complete
5. Start pipeline

### 5.2 — Settings Tabs

Update all settings tabs to use `FaeCore` directly instead of `commandSender?.sendCommand()`:

**`SettingsView.swift`**:
- Pass `faeCore` instead of `commandSender` to each tab

**`SettingsGeneralTab.swift`**:
- Listening toggle, theme, auto-update (Sparkle)
- Replace any `sendCommand` calls with `faeCore` property changes

**`SettingsModelsTab.swift`**:
- Model selection: show available MLX models
- Download progress via `FaeEventBus`
- Replace `sendCommand(name: "config.patch", payload: ["key": "llm.model_id", ...])` with `faeCore.patchConfig(key:value:)`
- Show model info: name, size, RAM requirement, download status

**`SettingsToolsTab.swift`**:
- Tool mode picker (off, read_only, read_write, full, full_no_approval)
- Replace `sendCommand(name: "config.patch", payload: ["key": "tool_mode", ...])` with `faeCore.patchConfig(key: "tool_mode", value: mode)`
- Individual tool permission toggles

**`SettingsChannelsTab.swift`**:
- Discord bot token, guild ID, channel IDs
- WhatsApp access token, phone number ID, verify token, allowed numbers
- Replace config.patch commands with direct `faeCore` calls

**`SettingsDeveloperTab.swift`**:
- Diagnostics health report from `DiagnosticsManager`
- Log viewer
- Memory database stats
- Replace any command-based diagnostics with direct calls

**`SettingsSkillsTab.swift`**:
- List installed skills
- Import new skill
- Enable/disable skills
- Wire to `SkillManager`

**`SettingsAboutTab.swift`**:
- Version info
- "Reset Onboarding" button → `faeCore.resetOnboarding()`
- Links, credits

### 5.3 — Relay Server & Handoff

**`FaeRelayServer.swift`** (if it exists in the Swift sources):
- Replace `commandSender: EmbeddedCoreSender?` with `faeCore: FaeCore`
- Replace `audioSender` references
- Update relay protocol to use `FaeCore` methods

**Handoff files**:
- `DeviceHandoff.swift`, `HandoffKVStore.swift`, `HandoffToolbarButton.swift`
- May reference old bridge types — update if needed
- Handoff uses `FaeHandoffKit` — verify integration still works

### 5.4 — ProcessCommandSender

**`ProcessCommandSender.swift`** — Review this file:
- If it wraps `EmbeddedCoreSender`, replace with `FaeCore`
- If it's used for IPC (Mode B / Unix socket), update or stub
- If it's unused after the rewrite, delete it

### 5.5 — Build System (Justfile)

Rewrite `justfile` at project root. Remove all Rust recipes. Replace with Swift-only:

```just
# Fae Pure-Swift Build System

# Show available recipes
default:
    @just --list

# --- Build ---

# Build debug
build:
    cd native/macos/Fae && swift build

# Build release
build-release:
    cd native/macos/Fae && swift build -c release

# --- Test ---

# Run tests
test:
    cd native/macos/Fae && swift test

# --- Bundle & Sign ---

# Clean Swift build artifacts
clean:
    cd native/macos/Fae && swift package clean
    rm -rf native/macos/Fae/.build

# Bundle the .app
_bundle-app:
    #!/usr/bin/env bash
    set -euo pipefail
    BUILD_DIR="native/macos/Fae/.build/arm64-apple-macosx/release"
    APP="$BUILD_DIR/Fae.app"
    # Create app bundle structure if needed
    mkdir -p "$APP/Contents/MacOS"
    mkdir -p "$APP/Contents/Resources"
    cp "$BUILD_DIR/Fae" "$APP/Contents/MacOS/Fae"
    # Copy Info.plist, entitlements, resources...

# Sign the bundle
_sign-bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    source ~/.secrets
    APP="native/macos/Fae/.build/arm64-apple-macosx/release/Fae.app"
    codesign --force --deep --sign "$MACOS_SIGNING_IDENTITY" \
        --options runtime \
        --entitlements native/macos/Fae/Fae.entitlements \
        "$APP"

# Kill any running Fae process
_kill-fae:
    @pkill -f "Fae.app/Contents/MacOS/Fae" 2>/dev/null || true
    @sleep 1

# Full bundle: clean + build + bundle + sign
bundle: clean build-release _bundle-app _sign-bundle

# --- Run ---

# Launch Fae with log capture
run: _kill-fae
    #!/usr/bin/env bash
    APP="native/macos/Fae/.build/arm64-apple-macosx/release/Fae.app"
    open "$APP" --stdout /tmp/fae-test.log --stderr /tmp/fae-test.log

# Build + bundle + sign + run
dev: bundle run

# --- Validation ---

# Full validation
check: build test

# Quick format check (SwiftFormat/SwiftLint if configured)
fmt-check:
    @echo "No Swift formatter configured yet — add SwiftFormat or SwiftLint"
```

**Important notes**:
- Signing identity comes from `~/.secrets` (MACOS_SIGNING_IDENTITY)
- Team ID: `MEGSB2GXGZ` (MaidSafe.net Ltd)
- Entitlements file: `native/macos/Fae/Fae.entitlements`
- NEVER use `$(AppIdentifierPrefix)` in entitlements — use literal `MEGSB2GXGZ.com.saorsalabs.fae`
- The `_kill-fae` step is critical — macOS `open` reactivates running processes instead of launching new ones

### 5.6 — CI Updates

**`.github/workflows/ci.yml`**:

Remove:
- Rust toolchain setup (`actions-rust-lang/setup-rust-toolchain`)
- `cargo fmt`, `cargo clippy`, `cargo test`, `cargo build`
- `cargo-nextest` installation
- Any `libfae.a` build steps

Replace with:
```yaml
jobs:
  build:
    runs-on: macos-14  # Apple Silicon runner
    steps:
      - uses: actions/checkout@v4

      - name: Build
        run: cd native/macos/Fae && swift build

      - name: Test
        run: cd native/macos/Fae && swift test

      - name: Build Release
        run: cd native/macos/Fae && swift build -c release
```

**`.github/workflows/release.yml`**:

Remove:
- All cross-compilation (Linux x86_64, Windows x86_64)
- `cargo zigbuild` steps
- Rust toolchain

Update to macOS arm64 only (MLX is Apple Silicon only):
```yaml
jobs:
  build-macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Build Release
        run: cd native/macos/Fae && swift build -c release

      - name: Bundle App
        run: just _bundle-app

      - name: Sign
        env:
          MACOS_CERTIFICATE: ${{ secrets.MACOS_CERTIFICATE }}
          MACOS_CERTIFICATE_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
          MACOS_SIGNING_IDENTITY: ${{ secrets.MACOS_SIGNING_IDENTITY }}
        run: just _sign-bundle

      - name: Notarize
        env:
          MACOS_NOTARIZATION_APPLE_ID: ${{ secrets.MACOS_NOTARIZATION_APPLE_ID }}
          MACOS_NOTARIZATION_PASSWORD: ${{ secrets.MACOS_NOTARIZATION_PASSWORD }}
          MACOS_NOTARIZATION_TEAM_ID: ${{ secrets.MACOS_NOTARIZATION_TEAM_ID }}
        run: |
          # Create ZIP for notarization
          # Submit to Apple notary service
          # Staple ticket

      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          files: Fae-*.zip
```

### 5.7 — Clean Up Rust Artifacts

**Now** that the pure Swift app is fully functional, remove:

- `src/` directory (all 217 .rs files)
- `Cargo.toml`
- `Cargo.lock`
- `.cargo/` directory (config.toml with test profile)
- `include/fae.h`
- `build.rs` (if it exists)
- `tests/` directory (Rust integration tests)
- `benches/` directory (if it exists)

**Keep**:
- `Prompts/` directory (system_prompt.md — loaded by Swift as bundle resource)
- `SOUL.md` (loaded by Swift as bundle resource)
- `docs/` directory
- `native/` directory (now the only source)
- `.github/` directory (updated workflows)
- `justfile` (updated for Swift)
- `CLAUDE.md` (update to reflect Swift-only architecture)

### 5.8 — Update CLAUDE.md

Update the project's `CLAUDE.md` to reflect the new architecture:
- Remove all Rust references (cargo, clippy, rustfmt, etc.)
- Update build commands to Swift
- Update file layout
- Remove FFI/linker anchor documentation
- Update tool references
- Keep behavioral truth sources (prompts, SOUL, memory docs)

### 5.9 — Update Info.plist

Verify `Info.plist` has:
- Correct bundle identifier: `com.saorsalabs.fae`
- Version substitution works: `__VERSION__` → actual version
- Appcast URL for Sparkle: `__APPCAST_URL__` → real URL
- Required entitlements: microphone, network, file access

---

## End-to-End Smoke Test

Run this complete test after all Phase 5 changes:

1. **Build & launch**:
   ```bash
   just dev  # clean + build + bundle + sign + run
   tail -f /tmp/fae-test.log  # in another terminal
   ```

2. **Onboarding**: Complete the onboarding flow (grant mic permission)

3. **Voice conversation**:
   - Say "Hello Fae, my name is David"
   - Fae responds with a greeting

4. **Tool execution**:
   - Say "What time is it?" → bash tool → approval → spoken time
   - Say "Search for the weather in Edinburgh" → web search → spoken result

5. **Apple ecosystem**:
   - Say "Check my calendar for today" → EventKit → spoken events

6. **Memory persistence**:
   - Quit app completely (`Cmd+Q`)
   - `just run`
   - Say "What's my name?" → Fae recalls "David"

7. **Settings**:
   - Open Settings (`Cmd+,` or menu)
   - Verify all tabs render correctly
   - Change tool mode → verify it takes effect

8. **Verify pipeline timing** in logs:
   ```bash
   grep "pipeline_timing" /tmp/fae-test.log
   ```
   All stages should show reasonable latencies.

---

## Performance Targets (Final Verification)

| Metric | Target | How to Measure |
|--------|--------|---------------|
| First audio latency | < 1.5s | Time from speech end to first TTS audio |
| LLM tokens/sec | > 60 (4B) | Pipeline timing logs |
| STT latency | < 500ms | Pipeline timing logs |
| TTS first chunk | < 200ms | Pipeline timing logs |
| Memory recall | < 50ms | Log timing around recall call |
| Cold start (cached) | < 10s | Time from app launch to pipeline ready |
| App bundle size | < 50MB | `du -sh Fae.app` (models downloaded separately) |

---

## Do NOT Do

- Do NOT change core pipeline/memory/tool/agent behavior (Phases 1-4 delivered these)
- Do NOT add new features
- Do NOT change prompt content (system_prompt.md, SOUL.md)
- Do NOT push to `main` without full smoke test passing
- Do NOT force-push or rewrite history on the feature branch

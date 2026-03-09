# fae — Real-time speech-to-speech AI conversation system (Pure Swift + MLX)

# Show available recipes
default:
    @just --list

# ── Build & Test ───────────────────────────────────────────────────────────

# Build debug (xcodebuild — compiles Metal shaders)
build:
    cd native/macos/Fae && xcodebuild build -scheme Fae -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -quiet

# Build release
build-release:
    cd native/macos/Fae && xcodebuild build -scheme Fae -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -quiet

# Run all tests (swift test — Metal not needed for unit tests)
test:
    cd native/macos/Fae && swift test

# Run tests with output visible
test-verbose:
    cd native/macos/Fae && swift test --verbose

# Clean build artifacts
clean:
    rm -rf native/macos/Fae/.build

# Guard against Rust/cargo reintroduction in active CI/default dev paths
guard-no-rust:
    ./scripts/ci/guard-no-rust-reintro.sh

# Full validation (build + test)
check: build test
    @echo "✓ All checks passed"

# ── Native App (macOS) ────────────────────────────────────────────────────

# xcodebuild output paths
_xcode_products := "native/macos/Fae/.build/xcode/Build/Products/Debug"
_app_bundle := _xcode_products / "Fae.app"
_entitlements := "Entitlements-debug.plist"

# Kill any running Fae process (prevents macOS from reactivating a stale process).
_kill-fae:
    #!/usr/bin/env bash
    if pgrep -f "Fae.app/Contents/MacOS/Fae" > /dev/null 2>&1; then
        echo "Killing existing Fae process…"
        pkill -f "Fae.app/Contents/MacOS/Fae" 2>/dev/null || true
        sleep 1
    fi

# Build, bundle, sign, and launch the native app.
run-native: build _bundle-app _sign-bundle _kill-fae
    open "{{_app_bundle}}" --stdout /tmp/fae-test.log --stderr /tmp/fae-test.log

# Build the Swift app, create .app bundle, sign, and verify it (without launching).
bundle-native: _kill-fae clean build _bundle-app _sign-bundle _verify-bundle
    @echo "✓ Signed bundle ready: {{_app_bundle}}"

# Full clean rebuild and launch.
rebuild: _kill-fae clean build _bundle-app _sign-bundle _verify-bundle
    open "{{_app_bundle}}" --stdout /tmp/fae-test.log --stderr /tmp/fae-test.log
    @echo "✓ Fae launched — logs: tail -f /tmp/fae-test.log"

# ── Test Harness ─────────────────────────────────────────────────────────

# Build, sign, and launch Fae with the test server enabled. Polls until /health responds.
test-serve: build _bundle-app _sign-bundle _kill-fae
    #!/usr/bin/env bash
    set -euo pipefail
    BUNDLE="{{_app_bundle}}"
    echo "Launching Fae with --test-server…"
    open "$BUNDLE" --stdout /tmp/fae-test.log --stderr /tmp/fae-test.log --args --test-server
    echo "Waiting for test server on 127.0.0.1:7433…"
    for i in $(seq 1 120); do
        if curl -sf http://127.0.0.1:7433/health > /dev/null 2>&1; then
            echo "✓ Test server ready (${i}s)"
            curl -s http://127.0.0.1:7433/health | python3 -m json.tool 2>/dev/null || curl -s http://127.0.0.1:7433/health
            exit 0
        fi
        sleep 1
    done
    echo "✗ Test server did not start within 120s"
    exit 1

# Inject text into Fae via test server.
test-inject text:
    curl -sf -X POST http://127.0.0.1:7433/inject \
        -H "Content-Type: application/json" \
        -d '{"text":"{{text}}"}' | python3 -m json.tool 2>/dev/null || \
    curl -s -X POST http://127.0.0.1:7433/inject \
        -H "Content-Type: application/json" \
        -d '{"text":"{{text}}"}'

# Show Fae's current status via test server.
test-status:
    curl -sf http://127.0.0.1:7433/status | python3 -m json.tool 2>/dev/null || \
    curl -s http://127.0.0.1:7433/status

# Show conversation messages via test server.
test-conversation:
    curl -sf http://127.0.0.1:7433/conversation | python3 -m json.tool 2>/dev/null || \
    curl -s http://127.0.0.1:7433/conversation

# Show debug events since sequence N (default: 0).
test-events since="0":
    curl -sf "http://127.0.0.1:7433/events?since={{since}}" | python3 -m json.tool 2>/dev/null || \
    curl -s "http://127.0.0.1:7433/events?since={{since}}"

# Cancel the current LLM generation via test server.
test-cancel:
    curl -sf -X POST http://127.0.0.1:7433/cancel | python3 -m json.tool 2>/dev/null || \
    curl -s -X POST http://127.0.0.1:7433/cancel

# ── Comprehensive Test Suite ──────────────────────────────────────────────

# Run comprehensive LLM-driven test suite (builds + launches Fae first)
test-comprehensive model="claude": test-serve
    bash scripts/test-comprehensive.sh --model {{model}}

# Run comprehensive tests (Fae already running on :7433)
test-comprehensive-quick model="claude":
    bash scripts/test-comprehensive.sh --skip-build --model {{model}}

# Run a single test phase (Fae must be running)
test-phase phase model="claude":
    bash scripts/test-comprehensive.sh --skip-build --phase {{phase}} --model {{model}}

# Run comprehensive tests with thinking sweep (each phase: thinking OFF then ON)
test-thinking-sweep model="claude":
    bash scripts/test-comprehensive.sh --skip-build --thinking-sweep --model {{model}}

# Run only deterministic tests — no LLM scoring, fast CI-friendly
test-deterministic: test-serve
    bash scripts/test-comprehensive.sh --skip-llm

# Run deterministic tests only (Fae already running)
test-deterministic-quick:
    bash scripts/test-comprehensive.sh --skip-build --skip-llm

# Run voice pipeline tests only (Fae + Chatterbox must be running)
test-voice model="claude":
    bash scripts/test-comprehensive.sh --skip-build --phase 11 --model {{model}}

# Run voice pipeline tests deterministic only (no LLM scoring)
test-voice-quick:
    bash scripts/test-comprehensive.sh --skip-build --phase 11 --skip-llm

# Run CoWork pipeline tests (Fae must be running)
test-cowork model="claude":
    bash scripts/test-comprehensive.sh --skip-build --phase 13 --model {{model}}

# Run CoWork pipeline tests deterministic only (no LLM scoring)
test-cowork-quick:
    bash scripts/test-comprehensive.sh --skip-build --phase 13 --skip-llm

# Run dual-model routing tests (Fae must be running)
test-dual-model model="claude":
    bash scripts/test-comprehensive.sh --skip-build --phase 14 --model {{model}}

# Run dual-model routing tests deterministic only (no LLM scoring)
test-dual-model-quick:
    bash scripts/test-comprehensive.sh --skip-build --phase 14 --skip-llm

# Run CoWork voice tests (Fae + Chatterbox must be running)
test-cowork-voice model="claude":
    bash scripts/test-comprehensive.sh --skip-build --phase 15 --model {{model}}

# Run full E2E suite (builds + launches Fae first)
test-e2e model="claude": test-serve
    bash scripts/test-comprehensive.sh --model {{model}}

# Run full E2E suite deterministic only (builds + launches Fae first)
test-e2e-quick: test-serve
    bash scripts/test-comprehensive.sh --skip-llm

# Run onboarding tests (Fae must be running)
test-onboarding model="claude":
    bash scripts/test-comprehensive.sh --skip-build --phase 12 --model {{model}}

# Run tests with audio recording (captures Fae's TTS for quality analysis)
test-record model="claude":
    bash scripts/test-with-recording.sh --model {{model}}

# Run deterministic tests with audio recording
test-record-quick:
    bash scripts/test-with-recording.sh --skip-llm

# Show latest comprehensive test report
test-report:
    python3 scripts/test-report-viewer.py

# List all test phases
test-phases:
    #!/usr/bin/env bash
    for f in tests/comprehensive/specs/*.yaml; do
        echo "  $(basename "$f")"
    done

# Set Fae config via test server (key=value)
test-config key value:
    curl -sf -X POST http://127.0.0.1:7433/config \
        -H "Content-Type: application/json" \
        -d '{"key":"{{key}}","value":"{{value}}"}' | python3 -m json.tool 2>/dev/null || \
    curl -s -X POST http://127.0.0.1:7433/config \
        -H "Content-Type: application/json" \
        -d '{"key":"{{key}}","value":"{{value}}"}'

# Approve pending tool request via test server
test-approve approved="true":
    curl -sf -X POST http://127.0.0.1:7433/approve \
        -H "Content-Type: application/json" \
        -d '{"approved":{{approved}}}' | python3 -m json.tool 2>/dev/null || \
    curl -s -X POST http://127.0.0.1:7433/approve \
        -H "Content-Type: application/json" \
        -d '{"approved":{{approved}}}'

# Reset Fae test state (conversation, events, history)
test-reset:
    curl -sf -X POST http://127.0.0.1:7433/reset | python3 -m json.tool 2>/dev/null || \
    curl -s -X POST http://127.0.0.1:7433/reset

# Dispatch a host command through the test server.
test-command name payload='{}':
    curl -sf -X POST http://127.0.0.1:7433/command \
        -H "Content-Type: application/json" \
        -d '{"name":"{{name}}","payload":{{payload}}}' | python3 -m json.tool 2>/dev/null || \
    curl -s -X POST http://127.0.0.1:7433/command \
        -H "Content-Type: application/json" \
        -d '{"name":"{{name}}","payload":{{payload}}}'

# Reset onboarding state and clear enrolled speaker profiles.
test-onboarding-reset:
    just test-command onboarding.reset

# Trigger the guided speaker enrollment flow.
test-start-enrollment:
    just test-command speaker.start_enrollment

# Show pending approvals via test server
test-approvals:
    curl -sf http://127.0.0.1:7433/approvals | python3 -m json.tool 2>/dev/null || \
    curl -s http://127.0.0.1:7433/approvals

# ── Code Signing ──────────────────────────────────────────────────────────

# Set up the signing keychain (idempotent — safe to run multiple times).
setup-signing-keychain:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${MACOS_CERTIFICATE:?Set MACOS_CERTIFICATE in ~/.secrets}"
    : "${MACOS_CERTIFICATE_PASSWORD:?Set MACOS_CERTIFICATE_PASSWORD in ~/.secrets}"
    : "${KEYCHAIN_PASSWORD:?Set KEYCHAIN_PASSWORD in ~/.secrets}"
    KC="$HOME/Library/Keychains/fae-signing.keychain-db"
    if security show-keychain-info "$KC" 2>/dev/null; then
        echo "✓ Signing keychain already exists"
        security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
    else
        echo "Creating signing keychain…"
        security create-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
        security set-keychain-settings -lut 21600 "$KC"
        security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
        EXISTING=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
        security list-keychains -d user -s $EXISTING "$KC"
    fi
    echo "$MACOS_CERTIFICATE" | base64 --decode > /tmp/_fae_cert.p12
    security import /tmp/_fae_cert.p12 -k "$KC" \
        -P "$MACOS_CERTIFICATE_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null || true
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$KEYCHAIN_PASSWORD" "$KC" 2>/dev/null
    rm -f /tmp/_fae_cert.p12
    if ! security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "valid"; then
        echo "Installing Apple Developer ID intermediate CA…"
        curl -sL "https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer" -o /tmp/_devid_g2.cer
        curl -sL "https://www.apple.com/certificateauthority/DeveloperIDCA.cer" -o /tmp/_devid_g1.cer
        security import /tmp/_devid_g2.cer -k "$KC" -T /usr/bin/codesign 2>/dev/null || true
        security import /tmp/_devid_g1.cer -k "$KC" -T /usr/bin/codesign 2>/dev/null || true
        security set-key-partition-list -S apple-tool:,apple:,codesign: \
            -s -k "$KEYCHAIN_PASSWORD" "$KC" 2>/dev/null
        rm -f /tmp/_devid_g2.cer /tmp/_devid_g1.cer
    fi
    echo "✓ Signing identity ready:"
    security find-identity -v -p codesigning "$KC" | head -3

# ── Internal Bundle Recipes ───────────────────────────────────────────────

# (internal) Assemble the .app bundle from the xcodebuild output.
_bundle-app:
    #!/usr/bin/env bash
    set -euo pipefail
    BUILD="{{_xcode_products}}"
    BUNDLE="{{_app_bundle}}"
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Frameworks" "$BUNDLE/Contents/Resources"

    # Copy executable
    cp "$BUILD/Fae" "$BUNDLE/Contents/MacOS/Fae"

    # Copy Sparkle framework (lives in top-level Products dir)
    cp -R "$BUILD/Sparkle.framework" "$BUNDLE/Contents/Frameworks/"

    # Copy all SPM dynamic frameworks from PackageFrameworks/ (MLX, MLXNN, KokoroSwift, etc.)
    PKG_FW="$BUILD/PackageFrameworks"
    if [ -d "$PKG_FW" ]; then
        for fw in "$PKG_FW"/*.framework; do
            [ -d "$fw" ] || continue
            FNAME=$(basename "$fw")
            [ "$FNAME" = "Sparkle.framework" ] && continue
            cp -R "$fw" "$BUNDLE/Contents/Frameworks/"
            echo "  → Embedded $FNAME"
        done
    fi

    # Copy all SPM resource bundles (Fae_Fae, mlx-swift_Cmlx, etc.)
    for bundle_dir in "$BUILD"/*.bundle "$PKG_FW"/*.bundle; do
        [ -d "$bundle_dir" ] || continue
        BNAME=$(basename "$bundle_dir")
        [ -d "$BUNDLE/Contents/Resources/$BNAME" ] && continue
        cp -R "$bundle_dir" "$BUNDLE/Contents/Resources/"
        echo "  → Copied $BNAME"
    done

    # Fix rpaths: remove absolute xcode build-dir paths baked in at compile time,
    # add @executable_path/../Frameworks so dyld finds the embedded frameworks.
    BINARY="$BUNDLE/Contents/MacOS/Fae"
    while IFS= read -r rp; do
        if [[ "$rp" == /Users/* ]] || [[ "$rp" == /var/* ]]; then
            install_name_tool -delete_rpath "$rp" "$BINARY" 2>/dev/null || true
        fi
    done < <(otool -l "$BINARY" | awk '/LC_RPATH/{found=1} found && /path /{print $2; found=0}')
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY" 2>/dev/null || true

    # Info.plist with version substitution
    VERSION=$(cat "$(git rev-parse --show-toplevel)/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "0.8.0")
    sed "s/__VERSION__/${VERSION}/g" \
        "$(git rev-parse --show-toplevel)/native/macos/Fae/Info.plist" \
        > "$BUNDLE/Contents/Info.plist"

    echo "✓ Bundle assembled: $BUNDLE (v${VERSION})"

# (internal) Sign the .app bundle with Developer ID.
_sign-bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${MACOS_SIGNING_IDENTITY:?Set MACOS_SIGNING_IDENTITY in ~/.secrets}"
    KC="$HOME/Library/Keychains/fae-signing.keychain-db"
    BUNDLE="{{_app_bundle}}"
    ENT="{{_entitlements}}"
    security unlock-keychain -p "${KEYCHAIN_PASSWORD:-password}" "$KC" 2>/dev/null || true
    # Sign Sparkle sub-components first (inside-out)
    for xpc in "$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"/*.xpc; do
        [ -d "$xpc" ] && codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$KC" "$xpc"
    done
    [ -d "$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" ] && \
        codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$KC" \
            "$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$KC" \
        "$BUNDLE/Contents/Frameworks/Sparkle.framework"
    # Sign all other embedded frameworks (MLX, MLXNN, KokoroSwift, etc.)
    for fw in "$BUNDLE/Contents/Frameworks"/*.framework; do
        [ -d "$fw" ] || continue
        FNAME=$(basename "$fw")
        [ "$FNAME" = "Sparkle.framework" ] && continue
        codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$KC" "$fw"
    done
    codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$KC" \
        --entitlements "$ENT" "$BUNDLE"
    echo "✓ Signed: $BUNDLE"
    codesign --verify --verbose "$BUNDLE" 2>&1 | tail -2

# (internal) Verify the .app bundle has all required components.
_verify-bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    BUNDLE="{{_app_bundle}}"
    ERRORS=0
    echo "Verifying bundle integrity…"
    if [ ! -f "$BUNDLE/Contents/MacOS/Fae" ]; then
        echo "  ✗ FAIL: Missing executable"
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ Executable present"
    fi
    # Check Fae's own Metal shader
    METALLIB="$BUNDLE/Contents/Resources/Fae_Fae.bundle/Contents/Resources/default.metallib"
    if [ ! -f "$METALLIB" ]; then
        echo "  ✗ FAIL: Missing Fae Metal shader (default.metallib)"
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ Fae Metal shader present ($(du -h "$METALLIB" | cut -f1))"
    fi
    # Check MLX Metal shader bundle
    MLX_METALLIB="$BUNDLE/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
    if [ ! -f "$MLX_METALLIB" ]; then
        echo "  ✗ FAIL: Missing MLX Metal shader (mlx-swift_Cmlx.bundle)"
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ MLX Metal shader present ($(du -h "$MLX_METALLIB" | cut -f1))"
    fi
    ICON="$BUNDLE/Contents/Resources/Fae_Fae.bundle/Contents/Resources/AppIconFace.jpg"
    if [ ! -f "$ICON" ]; then
        echo "  ⚠ WARNING: Missing app icon (AppIconFace.jpg)"
    else
        echo "  ✓ App icon present"
    fi
    if [ ! -d "$BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
        echo "  ✗ FAIL: Missing Sparkle.framework"
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ Sparkle framework present"
    fi
    if [ ! -f "$BUNDLE/Contents/Info.plist" ]; then
        echo "  ✗ FAIL: Missing Info.plist"
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ Info.plist present"
    fi
    if ! codesign --verify "$BUNDLE" 2>/dev/null; then
        echo "  ✗ FAIL: Code signature invalid"
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ Code signature valid"
    fi
    if [ "$ERRORS" -gt 0 ]; then
        echo "BUNDLE VERIFICATION FAILED: $ERRORS error(s)"
        exit 1
    fi
    echo "✓ Bundle verification passed"

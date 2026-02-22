# fae — Real-time speech-to-speech AI conversation system

# espeak-rs-sys needs the macOS SDK sysroot for bindgen + cmake.
# These are no-ops on Linux where the system headers are in the default search path.
export CC := env("CC", "/usr/bin/cc")
export BINDGEN_EXTRA_CLANG_ARGS := if os() == "macos" { "-isysroot " + `xcrun --show-sdk-path 2>/dev/null || echo ""` } else { "" }
export CFLAGS := if os() == "macos" { "-isysroot " + `xcrun --show-sdk-path 2>/dev/null || echo ""` } else { "" }

# Show available recipes
default:
    @just --list

# Run the headless host bridge (IPC / Mode B)
run:
    cargo run --bin fae-host

# Run the native macOS SwiftUI shell.
run-native-swift:
    cd native/macos/FaeNativeApp && swift run

# Build the native macOS SwiftUI shell.
build-native-swift:
    cd native/macos/FaeNativeApp && swift build

# Install the packaged native-device-handoff skill.
install-native-handoff-skill:
    cargo run --bin fae-skill-package -- install Skills/packages/native-device-handoff

# Install the packaged native-orb-semantics skill.
install-native-orb-skill:
    cargo run --bin fae-skill-package -- install Skills/packages/native-orb-semantics

# Slice an avatar sheet PNG into assets/avatar/*.png
slice-avatar SHEET:
    cargo run --features tools --bin fae-avatar-slicer -- {{SHEET}} assets/avatar


# Format code
fmt:
    cargo fmt --all

# Check formatting (CI mode)
fmt-check:
    cargo fmt --all -- --check

# Lint with clippy (zero warnings)
lint:
    cargo clippy --all-targets -- -D warnings

# Build debug
build:
    cargo build

# Build release
build-release:
    cargo build --release

# Build with warnings as errors (uses clippy instead of RUSTFLAGS to avoid cache invalidation)
build-strict:
    cargo clippy --all-targets -- -D warnings

# Run all tests (single integration binary — see tests/integration/main.rs)
test:
    cargo test

# Run tests with capped parallelism (CI-safe, ~14GB peak)
test-ci:
    CARGO_BUILD_JOBS=2 cargo test

# Run a specific integration test module (e.g., just test-integration memory_integration)
test-integration MOD:
    cargo test --test integration {{MOD}}::

# Run tests with output visible
test-verbose:
    cargo test -- --nocapture

# Run comprehensive tool-calling judgment eval suite
tool-judgment-eval:
    cargo test tool_judgment_ -- --nocapture

# Scan for forbidden patterns (.unwrap, .expect, panic!, etc.)
panic-scan:
    @! grep -rn '\.unwrap()\|\.expect(\|panic!(\|todo!(\|unimplemented!(' src/ --include='*.rs' | grep -v '// SAFETY:' | grep -v '#\[cfg(test)\]' || true

# Build documentation
doc:
    cargo doc --no-default-features --no-deps

# Clean build artifacts
clean:
    cargo clean

# Clean native Swift build artifacts (prevents stale code/artifacts)
clean-native:
    rm -rf native/macos/FaeNativeApp/.build

# Build libfae static library for macOS arm64 (for Swift embedding)
build-staticlib:
    cargo build --release --no-default-features --target aarch64-apple-darwin

# Build libfae static library for macOS x86_64 (Intel / CI)
build-staticlib-x86:
    cargo build --release --no-default-features --target x86_64-apple-darwin

# Create a universal (fat) libfae.a for macOS (arm64 + x86_64)
build-staticlib-universal: build-staticlib build-staticlib-x86
    mkdir -p target/universal-apple-darwin/release
    lipo -create \
        target/aarch64-apple-darwin/release/libfae.a \
        target/x86_64-apple-darwin/release/libfae.a \
        -output target/universal-apple-darwin/release/libfae.a
    @echo "Universal libfae.a: target/universal-apple-darwin/release/libfae.a"

# Check that libfae.a is large enough (subsystems not dead-stripped).
# Threshold: 50 MB. A stripped binary is typically ~9 MB.
check-binary-size target="aarch64-apple-darwin":
    #!/usr/bin/env bash
    set -euo pipefail
    LIB="target/{{target}}/release/libfae.a"
    if [ ! -f "$LIB" ]; then
        echo "ERROR: $LIB not found. Run 'just build-staticlib' first."
        exit 1
    fi
    SIZE=$(stat -f%z "$LIB" 2>/dev/null || stat -c%s "$LIB")
    MIN=$((50 * 1024 * 1024))
    echo "libfae.a size: $((SIZE / 1024 / 1024)) MB ($SIZE bytes)"
    if [ "$SIZE" -lt "$MIN" ]; then
        echo "FAIL: libfae.a is only $((SIZE / 1024 / 1024)) MB — subsystems likely dead-stripped."
        echo "Expected at least 50 MB. Check linker_anchor.rs."
        exit 1
    fi
    echo "PASS: libfae.a is large enough (subsystems retained)."

# Build libfae.a and verify subsystems are retained, then build Swift app.
build-native-and-check: build-staticlib check-binary-size build-native-swift
    @echo "Native build pipeline complete."

# Full validation (CI equivalent)
# Note: lint (clippy) already compiles + checks warnings, so build-strict is not needed here.
# Keeping the pipeline to: format → lint → test → doc → panic-scan (single compilation cache).
check: fmt-check lint test doc panic-scan

# Quick check (format + lint + test only)
quick-check: fmt-check lint test

# ── macOS Code Signing & Bundle ──────────────────────────────────────────────

# Directory paths
_build_dir := "native/macos/FaeNativeApp/.build/arm64-apple-macosx/debug"
_app_bundle := _build_dir / "FaeNativeApp.app"
_entitlements := "Entitlements-debug.plist"

# Set up the signing keychain (idempotent — safe to run multiple times).
# Requires: MACOS_CERTIFICATE, MACOS_CERTIFICATE_PASSWORD, KEYCHAIN_PASSWORD
# from env (sourced via ~/.zshrc → ~/.secrets).
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
    # Import certificate (idempotent — re-import is harmless)
    echo "$MACOS_CERTIFICATE" | base64 --decode > /tmp/_fae_cert.p12
    security import /tmp/_fae_cert.p12 -k "$KC" \
        -P "$MACOS_CERTIFICATE_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null || true
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$KEYCHAIN_PASSWORD" "$KC" 2>/dev/null
    rm -f /tmp/_fae_cert.p12
    # Fetch Apple intermediate CA if not present
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

# Build, bundle, sign, and launch the native app.
# Requires: MACOS_SIGNING_IDENTITY from env (sourced via ~/.zshrc → ~/.secrets).
run-native: build-native-swift _bundle-app _sign-bundle
    open "{{_app_bundle}}"

# Build the Swift app, create .app bundle, sign, and verify it (without launching).
# Always cleans the Swift build first to prevent stale artifacts.
bundle-native: clean-native build-native-swift _bundle-app _sign-bundle _verify-bundle
    @echo "✓ Signed bundle ready: {{_app_bundle}}"

# (internal) Assemble the .app bundle from the SPM debug build.
_bundle-app:
    #!/usr/bin/env bash
    set -euo pipefail
    BUILD="{{_build_dir}}"
    BUNDLE="{{_app_bundle}}"
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Frameworks" "$BUNDLE/Contents/Resources"
    cp "$BUILD/FaeNativeApp" "$BUNDLE/Contents/MacOS/FaeNativeApp"
    cp -R "$BUILD/Sparkle.framework" "$BUNDLE/Contents/Frameworks/"
    # Copy SPM resource bundle (contains Metal shaders, icons, help HTML).
    # Without this, the frosted-glass orb shader fails to load and the window is solid black.
    RESOURCE_BUNDLE="$BUILD/FaeNativeApp_FaeNativeApp.bundle"
    if [ -d "$RESOURCE_BUNDLE" ]; then
        cp -R "$RESOURCE_BUNDLE" "$BUNDLE/Contents/Resources/"
        echo "  → Copied resource bundle (metallib, icons, help)"
    else
        echo "WARNING: Resource bundle not found at $RESOURCE_BUNDLE"
        echo "         Metal shaders will not load — window will be black."
    fi
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$BUNDLE/Contents/MacOS/FaeNativeApp" 2>/dev/null || true
    cat > "$BUNDLE/Contents/Info.plist" << 'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>com.saorsalabs.fae</string>
        <key>CFBundleName</key>
        <string>Fae</string>
        <key>CFBundleDisplayName</key>
        <string>Fae</string>
        <key>CFBundleExecutable</key>
        <string>FaeNativeApp</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleVersion</key>
        <string>0.7.1</string>
        <key>CFBundleShortVersionString</key>
        <string>0.7.1</string>
        <key>LSMinimumSystemVersion</key>
        <string>14.0</string>
        <key>NSMicrophoneUsageDescription</key>
        <string>Fae needs microphone access for voice conversations.</string>
        <key>NSContactsUsageDescription</key>
        <string>Fae can access your contacts to help you communicate.</string>
        <key>NSCalendarsUsageDescription</key>
        <string>Fae can access your calendar to help manage your schedule.</string>
        <key>NSHighResolutionCapable</key>
        <true/>
    </dict>
    </plist>
    PLIST
    echo "✓ Bundle assembled: $BUNDLE"

# (internal) Sign the .app bundle with Developer ID.
_sign-bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${MACOS_SIGNING_IDENTITY:?Set MACOS_SIGNING_IDENTITY in ~/.secrets}"
    KC="$HOME/Library/Keychains/fae-signing.keychain-db"
    BUNDLE="{{_app_bundle}}"
    ENT="{{_entitlements}}"
    # Ensure keychain is unlocked
    security unlock-keychain -p "${KEYCHAIN_PASSWORD:-password}" "$KC" 2>/dev/null || true
    # Sign deepest components first
    for xpc in "$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"/*.xpc; do
        [ -d "$xpc" ] && codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$KC" "$xpc"
    done
    [ -d "$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" ] && \
        codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$KC" \
            "$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$KC" \
        "$BUNDLE/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign "$MACOS_SIGNING_IDENTITY" --keychain "$KC" \
        --entitlements "$ENT" "$BUNDLE"
    echo "✓ Signed: $BUNDLE"
    codesign --verify --verbose "$BUNDLE" 2>&1 | tail -2

# (internal) Verify the .app bundle has all required components.
# Prevents regressions like missing Metal shaders causing black window.
_verify-bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    BUNDLE="{{_app_bundle}}"
    ERRORS=0
    echo "Verifying bundle integrity…"
    # 1. Executable exists
    if [ ! -f "$BUNDLE/Contents/MacOS/FaeNativeApp" ]; then
        echo "  ✗ FAIL: Missing executable"
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ Executable present"
    fi
    # 2. Resource bundle with Metal shader
    METALLIB="$BUNDLE/Contents/Resources/FaeNativeApp_FaeNativeApp.bundle/default.metallib"
    if [ ! -f "$METALLIB" ]; then
        echo "  ✗ FAIL: Missing Metal shader (default.metallib)"
        echo "         Window will show solid black without this."
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ Metal shader present ($(du -h "$METALLIB" | cut -f1))"
    fi
    # 3. App icon
    ICON="$BUNDLE/Contents/Resources/FaeNativeApp_FaeNativeApp.bundle/AppIconFace.jpg"
    if [ ! -f "$ICON" ]; then
        echo "  ⚠ WARNING: Missing app icon (AppIconFace.jpg)"
    else
        echo "  ✓ App icon present"
    fi
    # 4. Sparkle framework
    if [ ! -d "$BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
        echo "  ✗ FAIL: Missing Sparkle.framework"
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ Sparkle framework present"
    fi
    # 5. Info.plist
    if [ ! -f "$BUNDLE/Contents/Info.plist" ]; then
        echo "  ✗ FAIL: Missing Info.plist"
        ERRORS=$((ERRORS+1))
    else
        echo "  ✓ Info.plist present"
    fi
    # 6. Code signature valid
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

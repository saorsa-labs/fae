# fae — Real-time speech-to-speech AI conversation system

# espeak-rs-sys needs the macOS SDK sysroot for bindgen + cmake.
# These are no-ops on Linux where the system headers are in the default search path.
export CC := env("CC", "/usr/bin/cc")
export BINDGEN_EXTRA_CLANG_ARGS := if os() == "macos" { "-isysroot " + `xcrun --show-sdk-path 2>/dev/null || echo ""` } else { "" }
export CFLAGS := if os() == "macos" { "-isysroot " + `xcrun --show-sdk-path 2>/dev/null || echo ""` } else { "" }

# Show available recipes
default:
    @just --list

# Run the GUI app (Metal GPU auto-enabled on macOS)
run:
    cargo run --bin fae

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

# Lint with clippy (zero warnings) — default features only (no gui)
lint:
    cargo clippy --no-default-features --all-targets -- -D warnings

# Build debug (CLI only, no gui feature)
build:
    cargo build --no-default-features

# Build release
build-release:
    cargo build --release --no-default-features

# Build with warnings as errors
build-strict:
    RUSTFLAGS="-D warnings" cargo build --no-default-features

# Build GUI (requires dioxus)
build-gui:
    cargo build --features gui

# Run all tests
test:
    cargo test --all-features

# Run tests with output visible
test-verbose:
    cargo test --all-features -- --nocapture

# Run comprehensive tool-calling judgment eval suite
tool-judgment-eval:
    cargo test --all-features tool_judgment_ -- --nocapture

# Scan for forbidden patterns (.unwrap, .expect, panic!, etc.)
panic-scan:
    @! grep -rn '\.unwrap()\|\.expect(\|panic!(\|todo!(\|unimplemented!(' src/ --include='*.rs' | grep -v '// SAFETY:' | grep -v '#\[cfg(test)\]' || true

# Build documentation
doc:
    cargo doc --no-default-features --no-deps

# Clean build artifacts
clean:
    cargo clean

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
check: fmt-check lint build-strict test doc panic-scan

# Quick check (format + lint + test only)
quick-check: fmt-check lint test

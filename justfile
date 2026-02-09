# fae — Real-time speech-to-speech AI conversation system

# Show available recipes
default:
    @just --list

# Run the GUI app (Metal GPU auto-enabled on macOS)
run:
    cargo run --bin fae

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

# Scan for forbidden patterns (.unwrap, .expect, panic!, etc.)
panic-scan:
    @! grep -rn '\.unwrap()\|\.expect(\|panic!(\|todo!(\|unimplemented!(' src/ --include='*.rs' | grep -v '// SAFETY:' | grep -v '#\[cfg(test)\]' || true

# Build documentation
doc:
    cargo doc --no-default-features --no-deps

# Clean build artifacts
clean:
    cargo clean

# Full validation (CI equivalent)
check: fmt-check lint build-strict test doc panic-scan

# Quick check (format + lint + test only)
quick-check: fmt-check lint test

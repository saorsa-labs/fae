# Linker Anchor (Historical)

> Historical note: this document describes the old embedded-Rust `libfae` dead-strip workaround.
> Fae now runs as a Swift-native runtime (`native/macos/Fae`) and this guide is archival context only.

If you are working on current production code, use:

- `native/macos/Fae/Package.swift`
- `native/macos/Fae/Sources/Fae/*`

For Rust-era rollback/reference material, see:

- `legacy/rust-core/README.md`
- `legacy/rust-core/ROLLBACK.md`

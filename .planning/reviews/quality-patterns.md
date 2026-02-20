# Quality Patterns Review
**Date**: 2026-02-20
**Mode**: gsd-task
**Scope**: src/host/handler.rs, src/skills/builtins.rs, native/macos/*.swift

## Good Patterns Found

- Uses `thiserror`/`anyhow` error propagation via `?` consistently throughout new code.
- `get_or_insert_with(T::default)` is idiomatic Rust for optional config initialization.
- `CredentialRef::Plaintext` wraps tokens in a typed credential enum rather than raw `String`.
- `@AppStorage` used for persistent UI state — correct SwiftUI pattern.
- `SecureField` for sensitive inputs — correct security-conscious UI pattern.
- Conditional rendering (`if channelsEnabled`) to hide irrelevant sections — good UX pattern.
- `MARK: -` comments in Swift separating Discord/WhatsApp sections — good code organization.
- Test counts updated atomically with implementation changes — no drift.

## Anti-Patterns Found

- [LOW] The `Err(_)` at handler.rs:1512 discards error context. Minor — could use `Err(e)` with `warn!(error = ?e, ...)` for better observability.
- [LOW] `saveDiscordSettings()` and `saveWhatsAppSettings()` skip empty strings but cannot clear previously set values. This is a UX limitation, not a code quality anti-pattern per se, but worth noting.
- [OK] No string error types introduced.
- [OK] No new `impl Error` without proper `thiserror` usage.
- [OK] No raw `HashMap<String, String>` for config — proper typed structs used throughout.

## Grade: A

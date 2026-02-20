# Security Review
**Date**: 2026-02-20
**Mode**: gsd-task
**Scope**: src/host/handler.rs, src/skills/builtins.rs, native/macos/.../SettingsChannelsTab.swift, native/macos/.../SettingsToolsTab.swift

## Findings

- [MEDIUM] src/host/handler.rs:238 - `CredentialRef::Plaintext(s.to_owned())` stores Discord bot_token as plaintext in config. This is an accepted design decision (user is warned in UI: "stored in your local config only"), but secrets are not encrypted at rest. This is pre-existing design per `CredentialRef` type design — not a regression introduced by this task.
- [MEDIUM] src/host/handler.rs:273/291 - Same plaintext credential storage for WhatsApp access_token and verify_token.
- [LOW] native/macos/.../SettingsChannelsTab.swift:48 - `SecureField` used for Discord bot token — correct. Tokens will not appear in UI.
- [LOW] native/macos/.../SettingsChannelsTab.swift:73/77 - `SecureField` used for WhatsApp access token and verify token — correct.
- [OK] native/macos/.../SettingsChannelsTab.swift:63 - Footnote warns user that tokens are "stored in your local config only" — appropriate disclosure.
- [OK] No hardcoded credentials found in any changed file.
- [OK] No new `unsafe` blocks introduced.
- [OK] No HTTP URLs introduced (no network calls in this diff).
- [OK] No command injection vectors (no `Command::new` in changed code).
- [OK] Tool mode values are validated via `serde_json::from_value::<AgentToolMode>` — no injection possible.
- [OK] CameraSkill removal has no security impact (reduces attack surface slightly).
- [OK] `PermissionKind::Camera` remains in permissions.rs for future use — not a security issue.

## Summary
No new security vulnerabilities. The plaintext credential storage is a known pre-existing design tradeoff documented in the UI footnotes. `SecureField` is correctly used for all sensitive inputs.

## Grade: B+

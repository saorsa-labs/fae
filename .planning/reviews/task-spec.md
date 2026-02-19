# Task Specification Review
**Date**: 2026-02-19
**Mode**: gsd (task 3, Phase 3.3)
**Task**: Task 3 — UnregisteredMailStore + global_mail_store() in ffi_bridge.rs
**Phase**: 3.3 Mail Tool & Tool Registration

## Spec Compliance

### Task 3 Requirements (from PLAN-phase-3.3.md):
- [x] Add `UnregisteredMailStore` struct implementing MailStore
- [x] All methods return `MailStoreError::PermissionDenied("Apple Mail store not initialized...")`
- [x] Add `global_mail_store() -> Arc<dyn MailStore>`
- [x] Add 4 unit tests (list_messages, get_message, compose, global accessor)
- [x] Follow exact pattern used for UnregisteredNoteStore
- [x] Wire ComposeMailTool, SearchMailTool, GetMailTool into build_registry() in agent/mod.rs
- [x] MockMailStore in mock_stores.rs (Task 4 also completed in this commit)

### Bonus: Tasks also covered in this diff:
- [x] Formatting cleanup in src/host/handler.rs (cargo fmt compliance)
- [x] Formatting cleanup in tests/phase_1_3_wired_commands.rs (cargo fmt compliance)

## Scope Concerns
- [OK] No scope creep detected — all changes are on the critical path for Task 3
- [OK] handler.rs and wired_commands.rs changes are pure rustfmt reformatting, no logic changes

## Grade: A

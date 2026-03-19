# Phase 3.3: Mail Tool & Tool Registration

## Overview

Implement the MailTool (compose, search, read email via AppleScript/NSSharingService),
register all Apple tools with dynamic availability gating, add LLM-facing descriptions,
rate limiting, and integration tests for the full tool registration flow.

Architecture follows existing pattern:
- `MailStore` trait in `src/fae_llm/tools/apple/mail.rs`
- `UnregisteredMailStore` stub in `src/fae_llm/tools/apple/ffi_bridge.rs`
- `MockMailStore` in `src/fae_llm/tools/apple/mock_stores.rs`
- Tools registered in `src/agent/mod.rs` `build_registry()`
- `PermissionKind::Mail` is already defined in `src/permissions.rs`

---

## Task 1: MailStore trait + domain types + ComposeMailTool

**Files:**
- `src/fae_llm/tools/apple/mail.rs` (new)

**Description:**
Create domain types (Mail, MailQuery, NewMail, MailStoreError) and the MailStore trait
with `list_messages`, `get_message`, and `compose` methods. Implement ComposeMailTool
that calls `store.compose()`. Tool is write-only (Full mode only). Requires Mail permission.
Add module doc comment.

---

## Task 2: SearchMailTool + GetMailTool

**Files:**
- `src/fae_llm/tools/apple/mail.rs` (extend)

**Description:**
Add SearchMailTool (search by query string, returns list of mail summaries) and
GetMailTool (get full message by identifier). Both are read-only (ReadOnly mode OK).
Both require Mail permission. Include unit tests using MockMailStore (not yet written,
can use a stub inline for now, or define trait first so tests can compile).

---

## Task 3: UnregisteredMailStore + global_mail_store() in ffi_bridge.rs

**Files:**
- `src/fae_llm/tools/apple/ffi_bridge.rs` (extend)

**Description:**
Add `UnregisteredMailStore` struct that implements MailStore with all methods returning
`MailStoreError::PermissionDenied("Apple Mail store not initialized...")`. Add
`global_mail_store() -> Arc<dyn MailStore>`. Add 4 unit tests (list_messages, get_message,
compose, global accessor). Follow exact pattern used for UnregisteredNoteStore.

---

## Task 4: MockMailStore in mock_stores.rs

**Files:**
- `src/fae_llm/tools/apple/mock_stores.rs` (extend)

**Description:**
Add `MockMailStore` with in-memory Vec<Mail>, Mutex for thread safety. Implements
MailStore: `list_messages` filters by search query, `get_message` by identifier,
`compose` appends a new Mail with deterministic identifier. Follow MockNoteStore pattern.

---

## Task 5: Wire mail module into mod.rs + agent build_registry()

**Files:**
- `src/fae_llm/tools/apple/mod.rs` (extend)
- `src/agent/mod.rs` (extend build_registry)

**Description:**
Add `pub mod mail;` to mod.rs, re-export all mail types and tools. Add `global_mail_store`
to re-exports. In `build_registry()`, register `ComposeMailTool`, `SearchMailTool`,
`GetMailTool` using `global_mail_store()` when `!AgentToolMode::Off`.

---

## Task 6: Dynamic tool availability — AvailabilityGatedTool wrapper

**Files:**
- `src/fae_llm/tools/apple/availability_gate.rs` (new)
- `src/fae_llm/tools/apple/mod.rs` (add pub mod)
- `src/agent/mod.rs` (wrap Apple tools)

**Description:**
Create `AvailabilityGatedTool` wrapper implementing `Tool` that holds an inner
`Arc<dyn AppleEcosystemTool>` and a `Arc<PermissionStore>`. Its `execute()` checks
`is_available()` before delegating; if unavailable returns a graceful error:
"Permission not granted: {kind}. Please grant {kind} permission to use this tool."
Its `name()`, `description()`, `schema()`, `allowed_in_mode()` delegate to inner.
Add unit tests. Wrap all Apple tool registrations in `build_registry()`.

---

## Task 7: Rate limiting for Apple ecosystem API calls

**Files:**
- `src/fae_llm/tools/apple/rate_limiter.rs` (new)
- `src/fae_llm/tools/apple/mod.rs` (add pub mod)
- `src/fae_llm/tools/apple/contacts.rs` (add rate limit to read ops)
- `src/fae_llm/tools/apple/reminders.rs` (add rate limit to read ops)
- `src/fae_llm/tools/apple/notes.rs` (add rate limit to read ops)
- `src/fae_llm/tools/apple/mail.rs` (add rate limit to read ops)

**Description:**
Create `AppleRateLimiter` using a token-bucket approach with `std::time::Instant`.
Config: 10 calls/second max per category. `RateLimitedStore<T>` wrapper delegates to
inner store but checks rate limit first, returning `Err(StoreError::RateLimited)` when
exceeded. Wire into global store accessors in ffi_bridge.rs. Add unit tests for
rate limiter behavior.

---

## Task 8: Integration tests for full tool registration flow

**Files:**
- `tests/apple_tool_registration.rs` (new)

**Description:**
Integration tests covering:
1. All Apple tools appear in registry when tool mode is not Off
2. Mail tools registered (ComposeMailTool, SearchMailTool, GetMailTool)
3. Unregistered stores return PermissionDenied errors (not panics)
4. AvailabilityGatedTool blocks execution when permission not granted
5. AvailabilityGatedTool allows execution when permission granted
6. Rate limiter blocks after burst threshold
7. Tool names and descriptions are non-empty (LLM-facing contract)
8. All 17 Apple tools have valid JSON schemas

---

## Summary

8 tasks: MailStore trait + tools, FFI stub, MockMailStore, mod wiring + agent registry,
AvailabilityGatedTool wrapper, rate limiter, integration tests.

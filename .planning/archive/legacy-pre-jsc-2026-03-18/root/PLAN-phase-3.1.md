# Phase 3.1: Contacts & Calendar Tools — Task Plan

## Overview

Milestone 3 Phase 3.1: Add Rust-side LLM tools for Contacts and Calendar access on macOS.
CNContactStore and EventKit are Apple/Swift frameworks, so the Rust layer implements a
trait-based store abstraction. Production implementations call out via `extern "C"` bridge
functions registered by Swift at startup; mock implementations enable unit testing in Rust.

## Architecture

```
Tool trait (fae_llm)
    └─ AppleEcosystemTool trait (extends Tool + permission gating)
         └─ ContactsTool (uses Arc<dyn ContactStore>)
         └─ CalendarTool (uses Arc<dyn CalendarStore>)

ContactStore trait ← FfiContactStore (calls C bridge) | MockContactStore (tests)
CalendarStore trait ← FfiCalendarStore (calls C bridge) | MockCalendarStore (tests)
```

## Files to Create

- `src/fae_llm/tools/apple/mod.rs` — module entry, re-exports
- `src/fae_llm/tools/apple/trait_def.rs` — `AppleEcosystemTool` trait
- `src/fae_llm/tools/apple/contacts.rs` — `ContactsTool` + `ContactStore` trait + all contact tools
- `src/fae_llm/tools/apple/calendar.rs` — `CalendarTool` + `CalendarStore` trait + all calendar tools
- `src/fae_llm/tools/apple/ffi_bridge.rs` — `extern "C"` bridge stubs + unregistered impls
- `src/fae_llm/tools/apple/mock_stores.rs` — `MockContactStore`, `MockCalendarStore` for tests

## Files to Modify

- `src/fae_llm/tools/mod.rs` — add `pub mod apple;` and re-exports
- `src/agent/mod.rs` — register Apple tools in `build_registry()` when permissions granted

---

## Task 1: Create apple module with `AppleEcosystemTool` trait

**Files**: `src/fae_llm/tools/apple/mod.rs`, `src/fae_llm/tools/apple/trait_def.rs`
**Modify**: `src/fae_llm/tools/mod.rs`

`AppleEcosystemTool` trait in `trait_def.rs`:
```rust
pub trait AppleEcosystemTool: Tool {
    fn required_permission(&self) -> PermissionKind;
    fn is_available(&self, store: &PermissionStore) -> bool {
        store.is_granted(self.required_permission())
    }
}
```

`mod.rs` declares submodules, re-exports `AppleEcosystemTool`.
Add `pub mod apple;` to `src/fae_llm/tools/mod.rs`.

Tests: trait is object-safe, `is_available` returns false without permission,
returns true after grant.

---

## Task 2: `ContactStore` trait + `SearchContactsTool`

**File**: `src/fae_llm/tools/apple/contacts.rs` (new)

Define `Contact`, `ContactQuery`, `ContactStoreError`, and `ContactStore` trait:
```rust
pub trait ContactStore: Send + Sync {
    fn search(&self, query: &ContactQuery) -> Result<Vec<Contact>, ContactStoreError>;
    fn get(&self, identifier: &str) -> Result<Option<Contact>, ContactStoreError>;
    fn create(&self, contact: &NewContact) -> Result<Contact, ContactStoreError>;
}
```

Implement `SearchContactsTool { store: Arc<dyn ContactStore> }`:
- `name()` → `"search_contacts"`, `allowed_in_mode()` → always true (read-only)
- `schema()` → `query` (string), `limit` (integer optional, default 10)
- `execute()` → call `store.search()`, format results as text

Tests (with MockContactStore): schema valid, no results returns helpful message,
results formatted with name/email/phone.

---

## Task 3: `GetContactTool` — read contact details

**File**: `src/fae_llm/tools/apple/contacts.rs` (extend)

Add `GetContactTool { store: Arc<dyn ContactStore> }`:
- `name()` → `"get_contact"`, `allowed_in_mode()` → always true (read-only)
- `schema()` → `identifier` (string, required)
- `execute()` → call `store.get()`, format all fields (name, phones, emails,
  addresses, birthday, organization, note)

`ContactStoreError` implements `Display` + `std::error::Error` + converts to `FaeLlmError`.

Tests: get existing contact returns all fields, missing identifier → failure message,
not-found → success with "no contact found" message.

---

## Task 4: `CreateContactTool`

**File**: `src/fae_llm/tools/apple/contacts.rs` (extend)

Define `NewContact` struct. Add `CreateContactTool { store: Arc<dyn ContactStore> }`:
- `name()` → `"create_contact"`, `allowed_in_mode()` → only `ToolMode::Full` (mutation)
- `schema()` → `given_name` (required), `family_name`, `email`, `phone`, `organization`, `note`
- `execute()` → parse args, call `store.create()`, return confirmation summary

Tests: create with minimal fields, create with all fields, missing given_name →
`ToolResult::failure`.

---

## Task 5: `CalendarStore` trait + `ListCalendarsTool` + `ListEventsTool`

**File**: `src/fae_llm/tools/apple/calendar.rs` (new)

Define `CalendarInfo`, `CalendarEvent`, `EventQuery`, `CalendarStoreError`, and trait:
```rust
pub trait CalendarStore: Send + Sync {
    fn list_calendars(&self) -> Result<Vec<CalendarInfo>, CalendarStoreError>;
    fn list_events(&self, query: &EventQuery) -> Result<Vec<CalendarEvent>, CalendarStoreError>;
    fn create_event(&self, event: &NewCalendarEvent) -> Result<CalendarEvent, CalendarStoreError>;
    fn update_event(&self, id: &str, patch: &EventPatch) -> Result<CalendarEvent, CalendarStoreError>;
    fn delete_event(&self, id: &str) -> Result<(), CalendarStoreError>;
}
```

Implement `ListCalendarsTool` and `ListEventsTool` (both read-only):
- `list_calendars`: no args, returns formatted calendar list
- `list_events`: `days_ahead` (integer, default 7), `calendar_id` (optional), `limit` (default 20)

Tests: empty stores return helpful messages, formatted output includes titles/dates.

---

## Task 6: `CreateEventTool`

**File**: `src/fae_llm/tools/apple/calendar.rs` (extend)

Define `NewCalendarEvent`. Add `CreateEventTool { store }`:
- `name()` → `"create_calendar_event"`, `allowed_in_mode()` → only `ToolMode::Full`
- `schema()` → `title` (required), `start` (required, ISO-8601), `end` (optional),
  `calendar_id`, `location`, `notes`, `all_day` (bool), `reminders` (integer array)
- `execute()` → parse, call `store.create_event()`, return confirmation

Tests: create with required fields, all fields, missing title → failure,
invalid date format → failure.

---

## Task 7: `UpdateEventTool` + `DeleteEventTool`

**File**: `src/fae_llm/tools/apple/calendar.rs` (extend)

Define `EventPatch`. Add `UpdateEventTool` and `DeleteEventTool`:
- Update: `identifier` (required) + optional field patches, `ToolMode::Full` only
- Delete: `identifier` (required) + `confirm: true` guard, `ToolMode::Full` only

Tests: update only specified fields, delete without confirm → failure, delete
confirmed → success.

---

## Task 8: FFI bridge stubs + `MockContactStore` + `MockCalendarStore` + integration tests

**Files**: `src/fae_llm/tools/apple/ffi_bridge.rs`, `src/fae_llm/tools/apple/mock_stores.rs`
**Modify**: `src/fae_llm/tools/apple/mod.rs` (comprehensive tests)
**Modify**: `src/agent/mod.rs` (register Apple tools)

### FFI bridge stubs (`ffi_bridge.rs`)

`UnregisteredContactStore` and `UnregisteredCalendarStore` return
`ContactStoreError::PermissionDenied` with message
"Apple store not initialized — ensure app is running on macOS".

### Mock stores (`mock_stores.rs`)

`MockContactStore::new(contacts)` — search by substring, get by id, create appends.
`MockCalendarStore::new(calendars, events)` — list/create/update/delete on in-memory vecs.

### Comprehensive integration tests

In `src/fae_llm/tools/apple/mod.rs` `#[cfg(test)] mod tests`:
- search_by_name, search_by_email, get_by_id, create_contact
- list_calendars_empty, list_events_upcoming, create_event, update_event
- delete_requires_confirm, delete_confirmed
- unregistered_store_returns_permission_denied_error
- all_tool_schemas_valid
- mutation_tools_require_full_mode
- read_tools_allow_all_modes

### Wire into agent

In `src/agent/mod.rs` `build_registry()`, add Apple tool registration
(guarded by feature flag check or always registered — store decides on permission):
```rust
// Apple ecosystem tools (macOS only; store checks permission internally)
use crate::fae_llm::tools::apple::contacts::{SearchContactsTool, GetContactTool, CreateContactTool};
use crate::fae_llm::tools::apple::calendar::{ListCalendarsTool, ListEventsTool, CreateEventTool, UpdateEventTool, DeleteEventTool};
use crate::fae_llm::tools::apple::ffi_bridge::{global_contact_store, global_calendar_store};
// Register with approval for mutation tools, direct for read-only tools.
```

# Phase 3.2: Reminders & Notes Tools

## Goal

Add RemindersTool (list, create, complete) and NotesTool (list, read, create/append)
following the same store-trait / FFI-bridge-stub / mock-store pattern established in Phase 3.1.
Also add permission guard verification (Task 7) and full unit tests (Task 8).

## Architecture

Follow Phase 3.1 patterns exactly:
- Store trait + domain types in `src/fae_llm/tools/apple/reminders.rs`
- Store trait + domain types in `src/fae_llm/tools/apple/notes.rs`
- Add `UnregisteredReminderStore` / `UnregisteredNoteStore` to `ffi_bridge.rs`
- Add `MockReminderStore` / `MockNoteStore` to `mock_stores.rs`
- Wire tools in `src/agent/mod.rs` `build_registry()`
- Update `src/fae_llm/tools/apple/mod.rs` exports
- PermissionKind::Reminders already exists; notes use PermissionKind::DesktopAutomation

## Task List

### Task 1: RemindersTool — domain types + ReminderStore trait + ListReminderListsTool + ListRemindersTool

File: `src/fae_llm/tools/apple/reminders.rs` (NEW)

Domain types:
- `ReminderList { identifier: String, title: String, item_count: usize }`
- `Reminder { identifier: String, list_id: String, title: String, notes: Option<String>, due_date: Option<String>, priority: u8, is_completed: bool, completion_date: Option<String> }`
- `ReminderQuery { list_id: Option<String>, include_completed: bool, limit: usize }`
- `ReminderStoreError { PermissionDenied(String), NotFound, InvalidInput(String), Backend(String) }` + Display + Error + From<ReminderStoreError> for FaeLlmError

`ReminderStore` trait (Send + Sync):
- `fn list_reminder_lists(&self) -> Result<Vec<ReminderList>, ReminderStoreError>`
- `fn list_reminders(&self, query: &ReminderQuery) -> Result<Vec<Reminder>, ReminderStoreError>`
- `fn get_reminder(&self, identifier: &str) -> Result<Option<Reminder>, ReminderStoreError>`
- `fn create_reminder(&self, reminder: &NewReminder) -> Result<Reminder, ReminderStoreError>`
- `fn set_completed(&self, identifier: &str, completed: bool) -> Result<Reminder, ReminderStoreError>`

`NewReminder { title: String, list_id: Option<String>, notes: Option<String>, due_date: Option<String>, priority: Option<u8> }`

`Reminder::format_summary(&self) -> String` — shows title, due date, priority, completion status

`ListReminderListsTool { store: Arc<dyn ReminderStore> }`:
- name: "list_reminder_lists"
- description: "List all reminder lists in the user's Reminders app."
- schema: empty object (no args needed)
- execute: calls store.list_reminder_lists(), formats as bulleted list
- allowed_in_mode: all modes
- AppleEcosystemTool: required_permission = PermissionKind::Reminders

`ListRemindersTool { store: Arc<dyn ReminderStore> }`:
- name: "list_reminders"
- description: "List reminders from the user's Reminders app, optionally filtered by list."
- schema: `{ list_id?: string, include_completed?: bool, limit?: integer(1..100, default 20) }`
- execute: builds ReminderQuery, calls store.list_reminders()
- allowed_in_mode: all modes
- AppleEcosystemTool: required_permission = PermissionKind::Reminders

### Task 2: RemindersTool — CreateReminderTool + SetReminderCompletedTool

Add to `src/fae_llm/tools/apple/reminders.rs`:

`CreateReminderTool { store: Arc<dyn ReminderStore> }`:
- name: "create_reminder"
- description: "Create a new reminder in the user's Reminders app."
- schema: `{ title: string (required), list_id?: string, notes?: string, due_date?: string (ISO-8601), priority?: integer(0..9) }`
- execute: validates title non-empty, builds NewReminder, calls store.create_reminder()
- allowed_in_mode: Full only
- AppleEcosystemTool: required_permission = PermissionKind::Reminders

`SetReminderCompletedTool { store: Arc<dyn ReminderStore> }`:
- name: "set_reminder_completed"
- description: "Mark a reminder as completed or uncompleted."
- schema: `{ identifier: string (required), completed: bool (required) }`
- execute: validates identifier non-empty, calls store.set_completed()
- allowed_in_mode: Full only
- AppleEcosystemTool: required_permission = PermissionKind::Reminders

### Task 3: NotesTool — domain types + NoteStore trait + ListNotesTool + GetNoteTool

File: `src/fae_llm/tools/apple/notes.rs` (NEW)

Domain types:
- `Note { identifier: String, title: String, body: String, folder: Option<String>, created_at: Option<String>, modified_at: Option<String> }`
- `NoteQuery { folder: Option<String>, search: Option<String>, limit: usize }`
- `NoteStoreError { PermissionDenied(String), NotFound, InvalidInput(String), Backend(String) }` + Display + Error + From<NoteStoreError> for FaeLlmError

`NoteStore` trait (Send + Sync):
- `fn list_notes(&self, query: &NoteQuery) -> Result<Vec<Note>, NoteStoreError>`
- `fn get_note(&self, identifier: &str) -> Result<Option<Note>, NoteStoreError>`
- `fn create_note(&self, note: &NewNote) -> Result<Note, NoteStoreError>`
- `fn append_to_note(&self, identifier: &str, content: &str) -> Result<Note, NoteStoreError>`

`NewNote { title: String, body: String, folder: Option<String> }`

`Note::format_summary(&self) -> String` — title, folder, dates, body snippet (80 chars)
`Note::format_full(&self) -> String` — full body

`ListNotesTool { store: Arc<dyn NoteStore> }`:
- name: "list_notes"
- description: "List notes from the user's Notes app, optionally filtered by folder or search term."
- schema: `{ folder?: string, search?: string, limit?: integer(1..50, default 10) }`
- execute: builds NoteQuery, calls store.list_notes(), formats summaries
- allowed_in_mode: all modes
- AppleEcosystemTool: required_permission = PermissionKind::DesktopAutomation

`GetNoteTool { store: Arc<dyn NoteStore> }`:
- name: "get_note"
- description: "Read the full content of a note by its identifier."
- schema: `{ identifier: string (required) }`
- execute: validates identifier, calls store.get_note(), returns format_full()
- allowed_in_mode: all modes
- AppleEcosystemTool: required_permission = PermissionKind::DesktopAutomation

### Task 4: NotesTool — CreateNoteTool + AppendToNoteTool

Add to `src/fae_llm/tools/apple/notes.rs`:

`CreateNoteTool { store: Arc<dyn NoteStore> }`:
- name: "create_note"
- description: "Create a new note in the user's Notes app."
- schema: `{ title: string (required), body: string (required), folder?: string }`
- execute: validates title+body non-empty, builds NewNote, calls store.create_note()
- allowed_in_mode: Full only
- AppleEcosystemTool: required_permission = PermissionKind::DesktopAutomation

`AppendToNoteTool { store: Arc<dyn NoteStore> }`:
- name: "append_to_note"
- description: "Append content to an existing note."
- schema: `{ identifier: string (required), content: string (required) }`
- execute: validates both fields non-empty, calls store.append_to_note()
- allowed_in_mode: Full only
- AppleEcosystemTool: required_permission = PermissionKind::DesktopAutomation

### Task 5: FFI bridge stubs

Add to `src/fae_llm/tools/apple/ffi_bridge.rs`:

`UnregisteredReminderStore` implementing `ReminderStore`:
- All methods return `ReminderStoreError::PermissionDenied("Apple Reminders store not initialized...")`

`UnregisteredNoteStore` implementing `NoteStore`:
- All methods return `NoteStoreError::PermissionDenied("Apple Notes store not initialized...")`

`pub fn global_reminder_store() -> Arc<dyn ReminderStore>` → returns `Arc::new(UnregisteredReminderStore)`
`pub fn global_note_store() -> Arc<dyn NoteStore>` → returns `Arc::new(UnregisteredNoteStore)`

Add tests: `unregistered_reminder_store_*` + `unregistered_note_store_*` (4 tests each)

### Task 6: Mock stores

Add to `src/fae_llm/tools/apple/mock_stores.rs`:

`MockReminderStore { lists: Vec<ReminderList>, reminders: Mutex<Vec<Reminder>>, next_id: Mutex<u64> }`:
- `new(lists, reminders)` constructor
- `list_reminder_lists`: returns cloned lists
- `list_reminders`: filters by list_id if Some, filters completed based on include_completed, takes limit
- `get_reminder`: finds by identifier
- `create_reminder`: assigns `"mock-reminder-{id}"`, appends
- `set_completed`: finds by id, sets is_completed + completion_date ("now" string)

`MockNoteStore { notes: Mutex<Vec<Note>>, next_id: Mutex<u64> }`:
- `new(notes)` constructor
- `list_notes`: filters by folder (if Some), search (substring on title+body), takes limit
- `get_note`: finds by identifier
- `create_note`: assigns `"mock-note-{id}"`, appends
- `append_to_note`: finds by id, appends "\n{content}" to body

### Task 7: Permission guard integration tests in tool unit tests

In the `#[cfg(test)]` sections of `reminders.rs` and `notes.rs`, add:
- `list_reminder_lists_requires_reminders_permission` — assert !is_available without grant, assert is_available after grant
- `list_reminders_requires_reminders_permission`
- `create_reminder_requires_reminders_permission`
- `set_completed_requires_reminders_permission`
- `list_notes_requires_desktop_automation_permission`
- `get_note_requires_desktop_automation_permission`
- `create_note_requires_desktop_automation_permission`
- `append_to_note_requires_desktop_automation_permission`

### Task 8: Agent wiring + mod.rs exports + full unit tests

**mod.rs** — add to `src/fae_llm/tools/apple/mod.rs`:
```rust
pub mod notes;
pub mod reminders;

pub use notes::{
    AppendToNoteTool, CreateNoteTool, GetNoteTool, ListNotesTool, Note, NoteQuery, NoteStore,
    NoteStoreError, NewNote,
};
pub use reminders::{
    CreateReminderTool, ListReminderListsTool, ListRemindersTool, NewReminder, Reminder,
    ReminderList, ReminderQuery, ReminderStore, ReminderStoreError, SetReminderCompletedTool,
};
pub use ffi_bridge::{global_reminder_store, global_note_store};
```

**agent/mod.rs** — in `build_registry()`, extend the apple block:
```rust
use crate::fae_llm::tools::apple::{
    // existing imports...
    // add:
    AppendToNoteTool, CreateNoteTool, CreateReminderTool, GetNoteTool, ListNotesTool,
    ListReminderListsTool, ListRemindersTool, SetReminderCompletedTool,
    global_note_store, global_reminder_store,
};
let reminders = global_reminder_store();
let notes = global_note_store();
registry.register(Arc::new(ListReminderListsTool::new(Arc::clone(&reminders))));
registry.register(Arc::new(ListRemindersTool::new(Arc::clone(&reminders))));
registry.register(Arc::new(CreateReminderTool::new(Arc::clone(&reminders))));
registry.register(Arc::new(SetReminderCompletedTool::new(reminders)));
registry.register(Arc::new(ListNotesTool::new(Arc::clone(&notes))));
registry.register(Arc::new(GetNoteTool::new(Arc::clone(&notes))));
registry.register(Arc::new(CreateNoteTool::new(Arc::clone(&notes))));
registry.register(Arc::new(AppendToNoteTool::new(notes)));
```

**Unit tests** in `reminders.rs` — comprehensive test coverage:
Reminders:
- `list_reminder_lists_returns_all_lists`
- `list_reminders_no_filter_returns_all`
- `list_reminders_filter_by_list_id`
- `list_reminders_excludes_completed_by_default`
- `list_reminders_includes_completed_when_requested`
- `list_reminders_respects_limit`
- `create_reminder_minimal_succeeds`
- `create_reminder_all_fields_populates_correctly`
- `create_reminder_empty_title_returns_failure`
- `create_reminder_only_full_mode`
- `set_completed_marks_reminder_done`
- `set_completed_can_uncomplete`
- `set_completed_missing_id_returns_failure`

Notes:
- `list_notes_returns_all_up_to_limit`
- `list_notes_filter_by_folder`
- `list_notes_search_term_matches`
- `get_note_returns_full_content`
- `get_note_missing_returns_not_found_message`
- `get_note_missing_identifier_returns_failure`
- `create_note_minimal_succeeds`
- `create_note_with_folder_populates`
- `create_note_empty_title_returns_failure`
- `create_note_only_full_mode`
- `append_to_note_adds_content`
- `append_to_note_missing_id_returns_not_found`
- `append_to_note_empty_content_returns_failure`

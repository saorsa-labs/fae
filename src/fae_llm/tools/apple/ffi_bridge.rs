//! FFI bridge stubs for Apple ecosystem stores.
//!
//! In production, the macOS Swift application registers real store implementations
//! at startup.  Before registration, all operations return a `PermissionDenied`
//! error with a clear diagnostic message.
//!
//! # Design
//!
//! - `global_contact_store()` returns an `Arc<dyn ContactStore>`.
//! - `global_calendar_store()` returns an `Arc<dyn CalendarStore>`.
//! - `global_reminder_store()` returns an `Arc<dyn ReminderStore>`.
//! - `global_note_store()` returns an `Arc<dyn NoteStore>`.
//!
//! All return their respective `Unregistered*` stubs until a real implementation
//! is injected by the host platform (Phase 3.4).
//! For now the unregistered stores provide clear error messages that guide
//! diagnostics without panicking.

use std::sync::Arc;

use super::calendar::{
    CalendarEvent, CalendarInfo, CalendarStore, CalendarStoreError, EventPatch, EventQuery,
    NewCalendarEvent,
};
use super::contacts::{Contact, ContactQuery, ContactStore, ContactStoreError, NewContact};
use super::notes::{NewNote, Note, NoteQuery, NoteStore, NoteStoreError};
use super::reminders::{
    NewReminder, Reminder, ReminderList, ReminderQuery, ReminderStore, ReminderStoreError,
};

// ─── Unregistered store implementations ──────────────────────────────────────

/// A no-op [`ContactStore`] used before the Swift bridge registers a real
/// implementation.
///
/// All operations return [`ContactStoreError::PermissionDenied`] with a
/// diagnostic message.
pub struct UnregisteredContactStore;

impl ContactStore for UnregisteredContactStore {
    fn search(&self, _query: &ContactQuery) -> Result<Vec<Contact>, ContactStoreError> {
        Err(ContactStoreError::PermissionDenied(
            "Apple Contacts store not initialized. \
             The app must be running on macOS with Contacts permission granted."
                .to_owned(),
        ))
    }

    fn get(&self, _identifier: &str) -> Result<Option<Contact>, ContactStoreError> {
        Err(ContactStoreError::PermissionDenied(
            "Apple Contacts store not initialized. \
             The app must be running on macOS with Contacts permission granted."
                .to_owned(),
        ))
    }

    fn create(&self, _contact: &NewContact) -> Result<Contact, ContactStoreError> {
        Err(ContactStoreError::PermissionDenied(
            "Apple Contacts store not initialized. \
             The app must be running on macOS with Contacts permission granted."
                .to_owned(),
        ))
    }
}

/// A no-op [`CalendarStore`] used before the Swift bridge registers a real
/// implementation.
///
/// All operations return [`CalendarStoreError::PermissionDenied`] with a
/// diagnostic message.
pub struct UnregisteredCalendarStore;

impl CalendarStore for UnregisteredCalendarStore {
    fn list_calendars(&self) -> Result<Vec<CalendarInfo>, CalendarStoreError> {
        Err(CalendarStoreError::PermissionDenied(
            "Apple Calendar store not initialized. \
             The app must be running on macOS with Calendar permission granted."
                .to_owned(),
        ))
    }

    fn list_events(&self, _query: &EventQuery) -> Result<Vec<CalendarEvent>, CalendarStoreError> {
        Err(CalendarStoreError::PermissionDenied(
            "Apple Calendar store not initialized. \
             The app must be running on macOS with Calendar permission granted."
                .to_owned(),
        ))
    }

    fn create_event(&self, _event: &NewCalendarEvent) -> Result<CalendarEvent, CalendarStoreError> {
        Err(CalendarStoreError::PermissionDenied(
            "Apple Calendar store not initialized. \
             The app must be running on macOS with Calendar permission granted."
                .to_owned(),
        ))
    }

    fn update_event(
        &self,
        _id: &str,
        _patch: &EventPatch,
    ) -> Result<CalendarEvent, CalendarStoreError> {
        Err(CalendarStoreError::PermissionDenied(
            "Apple Calendar store not initialized. \
             The app must be running on macOS with Calendar permission granted."
                .to_owned(),
        ))
    }

    fn delete_event(&self, _id: &str) -> Result<(), CalendarStoreError> {
        Err(CalendarStoreError::PermissionDenied(
            "Apple Calendar store not initialized. \
             The app must be running on macOS with Calendar permission granted."
                .to_owned(),
        ))
    }
}

// ─── Global store accessors ───────────────────────────────────────────────────

/// Returns the global contact store.
///
/// Currently always returns `UnregisteredContactStore`.  When the Swift
/// application starts and the user grants Contacts permission, the host will
/// replace this with a real store (Phase 3.4).
pub fn global_contact_store() -> Arc<dyn ContactStore> {
    Arc::new(UnregisteredContactStore)
}

/// Returns the global calendar store.
///
/// Currently always returns `UnregisteredCalendarStore`.  When the Swift
/// application starts and the user grants Calendar permission, the host will
/// replace this with a real store (Phase 3.4).
pub fn global_calendar_store() -> Arc<dyn CalendarStore> {
    Arc::new(UnregisteredCalendarStore)
}

// ─── UnregisteredReminderStore ────────────────────────────────────────────────

/// A no-op [`ReminderStore`] used before the Swift bridge registers a real
/// implementation.
///
/// All operations return [`ReminderStoreError::PermissionDenied`] with a
/// diagnostic message.
pub struct UnregisteredReminderStore;

impl ReminderStore for UnregisteredReminderStore {
    fn list_reminder_lists(&self) -> Result<Vec<ReminderList>, ReminderStoreError> {
        Err(ReminderStoreError::PermissionDenied(
            "Apple Reminders store not initialized. \
             The app must be running on macOS with Reminders permission granted."
                .to_owned(),
        ))
    }

    fn list_reminders(&self, _query: &ReminderQuery) -> Result<Vec<Reminder>, ReminderStoreError> {
        Err(ReminderStoreError::PermissionDenied(
            "Apple Reminders store not initialized. \
             The app must be running on macOS with Reminders permission granted."
                .to_owned(),
        ))
    }

    fn get_reminder(&self, _identifier: &str) -> Result<Option<Reminder>, ReminderStoreError> {
        Err(ReminderStoreError::PermissionDenied(
            "Apple Reminders store not initialized. \
             The app must be running on macOS with Reminders permission granted."
                .to_owned(),
        ))
    }

    fn create_reminder(&self, _reminder: &NewReminder) -> Result<Reminder, ReminderStoreError> {
        Err(ReminderStoreError::PermissionDenied(
            "Apple Reminders store not initialized. \
             The app must be running on macOS with Reminders permission granted."
                .to_owned(),
        ))
    }

    fn set_completed(
        &self,
        _identifier: &str,
        _completed: bool,
    ) -> Result<Reminder, ReminderStoreError> {
        Err(ReminderStoreError::PermissionDenied(
            "Apple Reminders store not initialized. \
             The app must be running on macOS with Reminders permission granted."
                .to_owned(),
        ))
    }
}

/// Returns the global reminder store.
///
/// Currently always returns `UnregisteredReminderStore`.  When the Swift
/// application starts and the user grants Reminders permission, the host will
/// replace this with a real store (Phase 3.4).
pub fn global_reminder_store() -> Arc<dyn ReminderStore> {
    Arc::new(UnregisteredReminderStore)
}

// ─── UnregisteredNoteStore ────────────────────────────────────────────────────

/// A no-op [`NoteStore`] used before the Swift bridge registers a real
/// implementation.
///
/// All operations return [`NoteStoreError::PermissionDenied`] with a
/// diagnostic message.
pub struct UnregisteredNoteStore;

impl NoteStore for UnregisteredNoteStore {
    fn list_notes(&self, _query: &NoteQuery) -> Result<Vec<Note>, NoteStoreError> {
        Err(NoteStoreError::PermissionDenied(
            "Apple Notes store not initialized. \
             The app must be running on macOS with Desktop Automation permission granted."
                .to_owned(),
        ))
    }

    fn get_note(&self, _identifier: &str) -> Result<Option<Note>, NoteStoreError> {
        Err(NoteStoreError::PermissionDenied(
            "Apple Notes store not initialized. \
             The app must be running on macOS with Desktop Automation permission granted."
                .to_owned(),
        ))
    }

    fn create_note(&self, _note: &NewNote) -> Result<Note, NoteStoreError> {
        Err(NoteStoreError::PermissionDenied(
            "Apple Notes store not initialized. \
             The app must be running on macOS with Desktop Automation permission granted."
                .to_owned(),
        ))
    }

    fn append_to_note(&self, _identifier: &str, _content: &str) -> Result<Note, NoteStoreError> {
        Err(NoteStoreError::PermissionDenied(
            "Apple Notes store not initialized. \
             The app must be running on macOS with Desktop Automation permission granted."
                .to_owned(),
        ))
    }
}

/// Returns the global note store.
///
/// Currently always returns `UnregisteredNoteStore`.  When the Swift
/// application starts and the user grants Desktop Automation permission, the
/// host will replace this with a real store (Phase 3.4).
pub fn global_note_store() -> Arc<dyn NoteStore> {
    Arc::new(UnregisteredNoteStore)
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn unregistered_contact_store_search_returns_permission_denied() {
        let store = UnregisteredContactStore;
        let query = ContactQuery {
            query: Some("Alice".to_owned()),
            limit: 10,
        };
        let err = store.search(&query);
        assert!(
            err.is_err(),
            "expected error from unregistered contact store"
        );
        let err_msg = err.err().unwrap().to_string();
        assert!(
            err_msg.contains("not initialized"),
            "expected helpful message, got: {err_msg}"
        );
    }

    #[test]
    fn unregistered_contact_store_get_returns_permission_denied() {
        let store = UnregisteredContactStore;
        let err = store.get("some-id");
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_contact_store_create_returns_permission_denied() {
        let store = UnregisteredContactStore;
        let contact = NewContact {
            given_name: "Test".to_owned(),
            family_name: None,
            email: None,
            phone: None,
            organization: None,
            note: None,
        };
        let err = store.create(&contact);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_calendar_store_list_calendars_returns_permission_denied() {
        let store = UnregisteredCalendarStore;
        let err = store.list_calendars();
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_calendar_store_list_events_returns_permission_denied() {
        let store = UnregisteredCalendarStore;
        let query = EventQuery {
            calendar_ids: vec![],
            start_after: None,
            end_before: None,
            limit: 10,
        };
        let err = store.list_events(&query);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_calendar_store_create_event_returns_permission_denied() {
        let store = UnregisteredCalendarStore;
        let event = NewCalendarEvent {
            title: "Test".to_owned(),
            start: "2026-01-01T10:00:00".to_owned(),
            end: None,
            calendar_id: None,
            location: None,
            notes: None,
            is_all_day: false,
            alarms: vec![],
        };
        let err = store.create_event(&event);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_calendar_store_update_returns_permission_denied() {
        let store = UnregisteredCalendarStore;
        let patch = EventPatch {
            title: None,
            start: None,
            end: None,
            location: None,
            notes: None,
            alarms: None,
        };
        let err = store.update_event("evt-001", &patch);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_calendar_store_delete_returns_permission_denied() {
        let store = UnregisteredCalendarStore;
        let err = store.delete_event("evt-001");
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn global_contact_store_returns_unregistered() {
        let store = global_contact_store();
        let query = ContactQuery {
            query: None,
            limit: 5,
        };
        // Should return an error (unregistered), not panic
        let result = store.search(&query);
        assert!(result.is_err());
    }

    #[test]
    fn global_calendar_store_returns_unregistered() {
        let store = global_calendar_store();
        let result = store.list_calendars();
        assert!(result.is_err());
    }

    // ── UnregisteredReminderStore ─────────────────────────────────────────────

    #[test]
    fn unregistered_reminder_store_list_lists_returns_permission_denied() {
        let store = UnregisteredReminderStore;
        let err = store.list_reminder_lists();
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_reminder_store_list_reminders_returns_permission_denied() {
        let store = UnregisteredReminderStore;
        let query = ReminderQuery {
            list_id: None,
            include_completed: false,
            limit: 10,
        };
        let err = store.list_reminders(&query);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_reminder_store_create_returns_permission_denied() {
        let store = UnregisteredReminderStore;
        let reminder = NewReminder {
            title: "Test".to_owned(),
            list_id: None,
            notes: None,
            due_date: None,
            priority: None,
        };
        let err = store.create_reminder(&reminder);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_reminder_store_set_completed_returns_permission_denied() {
        let store = UnregisteredReminderStore;
        let err = store.set_completed("rem-001", true);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn global_reminder_store_returns_unregistered() {
        let store = global_reminder_store();
        let result = store.list_reminder_lists();
        assert!(result.is_err());
    }

    // ── UnregisteredNoteStore ─────────────────────────────────────────────────

    #[test]
    fn unregistered_note_store_list_notes_returns_permission_denied() {
        let store = UnregisteredNoteStore;
        let query = NoteQuery {
            folder: None,
            search: None,
            limit: 10,
        };
        let err = store.list_notes(&query);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_note_store_get_returns_permission_denied() {
        let store = UnregisteredNoteStore;
        let err = store.get_note("note-001");
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_note_store_create_returns_permission_denied() {
        let store = UnregisteredNoteStore;
        let note = NewNote {
            title: "Test".to_owned(),
            body: "Content".to_owned(),
            folder: None,
        };
        let err = store.create_note(&note);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_note_store_append_returns_permission_denied() {
        let store = UnregisteredNoteStore;
        let err = store.append_to_note("note-001", "extra text");
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn global_note_store_returns_unregistered() {
        let store = global_note_store();
        let result = store.list_notes(&NoteQuery {
            folder: None,
            search: None,
            limit: 5,
        });
        assert!(result.is_err());
    }
}

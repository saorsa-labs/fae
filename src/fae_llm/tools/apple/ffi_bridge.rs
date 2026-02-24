//! FFI bridge for Apple ecosystem stores.
//!
//! Uses [`OnceLock`]-backed statics for each store.  Real implementations
//! (e.g. [`ApplescriptContactStore`]) are registered once at startup.
//! Before registration, the `global_*_store()` accessors return the
//! `Unregistered*` stubs which return clear `PermissionDenied` errors.
//!
//! # Usage
//!
//! ```ignore
//! // At startup (e.g. in host/handler.rs):
//! register_contact_store(Arc::new(ApplescriptContactStore));
//! register_calendar_store(Arc::new(ApplescriptCalendarStore));
//! // ...
//!
//! // Tool code (unchanged):
//! let contacts = global_contact_store();
//! ```

use std::sync::{Arc, OnceLock};

// ─── OnceLock statics ────────────────────────────────────────────────────────

static CONTACT_STORE: OnceLock<Arc<dyn ContactStore>> = OnceLock::new();
static CALENDAR_STORE: OnceLock<Arc<dyn CalendarStore>> = OnceLock::new();
static REMINDER_STORE: OnceLock<Arc<dyn ReminderStore>> = OnceLock::new();
static NOTE_STORE: OnceLock<Arc<dyn NoteStore>> = OnceLock::new();
static MAIL_STORE: OnceLock<Arc<dyn MailStore>> = OnceLock::new();

// ─── Registration functions ──────────────────────────────────────────────────

/// Register the global contact store implementation.
///
/// Called once at startup. Subsequent calls are no-ops (first writer wins).
pub fn register_contact_store(store: Arc<dyn ContactStore>) {
    let _ = CONTACT_STORE.set(store);
}

/// Register the global calendar store implementation.
pub fn register_calendar_store(store: Arc<dyn CalendarStore>) {
    let _ = CALENDAR_STORE.set(store);
}

/// Register the global reminder store implementation.
pub fn register_reminder_store(store: Arc<dyn ReminderStore>) {
    let _ = REMINDER_STORE.set(store);
}

/// Register the global note store implementation.
pub fn register_note_store(store: Arc<dyn NoteStore>) {
    let _ = NOTE_STORE.set(store);
}

/// Register the global mail store implementation.
pub fn register_mail_store(store: Arc<dyn MailStore>) {
    let _ = MAIL_STORE.set(store);
}

use super::calendar::{
    CalendarEvent, CalendarInfo, CalendarStore, CalendarStoreError, EventPatch, EventQuery,
    NewCalendarEvent,
};
use super::contacts::{Contact, ContactQuery, ContactStore, ContactStoreError, NewContact};
use super::mail::{Mail, MailQuery, MailStore, MailStoreError, NewMail};
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
/// Returns the registered implementation if `register_contact_store()` was
/// called, otherwise falls back to `UnregisteredContactStore`.
pub fn global_contact_store() -> Arc<dyn ContactStore> {
    CONTACT_STORE
        .get()
        .cloned()
        .unwrap_or_else(|| Arc::new(UnregisteredContactStore))
}

/// Returns the global calendar store.
///
/// Returns the registered implementation if `register_calendar_store()` was
/// called, otherwise falls back to `UnregisteredCalendarStore`.
pub fn global_calendar_store() -> Arc<dyn CalendarStore> {
    CALENDAR_STORE
        .get()
        .cloned()
        .unwrap_or_else(|| Arc::new(UnregisteredCalendarStore))
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
/// Returns the registered implementation if `register_reminder_store()` was
/// called, otherwise falls back to `UnregisteredReminderStore`.
pub fn global_reminder_store() -> Arc<dyn ReminderStore> {
    REMINDER_STORE
        .get()
        .cloned()
        .unwrap_or_else(|| Arc::new(UnregisteredReminderStore))
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
/// Returns the registered implementation if `register_note_store()` was
/// called, otherwise falls back to `UnregisteredNoteStore`.
pub fn global_note_store() -> Arc<dyn NoteStore> {
    NOTE_STORE
        .get()
        .cloned()
        .unwrap_or_else(|| Arc::new(UnregisteredNoteStore))
}

// ─── UnregisteredMailStore ────────────────────────────────────────────────────

/// A no-op [`MailStore`] used before the Swift bridge registers a real
/// implementation.
///
/// All operations return [`MailStoreError::PermissionDenied`] with a
/// diagnostic message.
pub struct UnregisteredMailStore;

impl MailStore for UnregisteredMailStore {
    fn list_messages(&self, _query: &MailQuery) -> Result<Vec<Mail>, MailStoreError> {
        Err(MailStoreError::PermissionDenied(
            "Apple Mail store not initialized. \
             The app must be running on macOS with Mail permission granted."
                .to_owned(),
        ))
    }

    fn get_message(&self, _identifier: &str) -> Result<Option<Mail>, MailStoreError> {
        Err(MailStoreError::PermissionDenied(
            "Apple Mail store not initialized. \
             The app must be running on macOS with Mail permission granted."
                .to_owned(),
        ))
    }

    fn compose(&self, _mail: &NewMail) -> Result<Mail, MailStoreError> {
        Err(MailStoreError::PermissionDenied(
            "Apple Mail store not initialized. \
             The app must be running on macOS with Mail permission granted."
                .to_owned(),
        ))
    }
}

/// Returns the global mail store.
///
/// Returns the registered implementation if `register_mail_store()` was
/// called, otherwise falls back to `UnregisteredMailStore`.
pub fn global_mail_store() -> Arc<dyn MailStore> {
    MAIL_STORE
        .get()
        .cloned()
        .unwrap_or_else(|| Arc::new(UnregisteredMailStore))
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

    // ── UnregisteredMailStore ─────────────────────────────────────────────────

    #[test]
    fn unregistered_mail_store_list_messages_returns_permission_denied() {
        let store = UnregisteredMailStore;
        let query = MailQuery {
            search: None,
            mailbox: None,
            unread_only: false,
            limit: 10,
        };
        let err = store.list_messages(&query);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_mail_store_get_message_returns_permission_denied() {
        let store = UnregisteredMailStore;
        let err = store.get_message("mail-001");
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn unregistered_mail_store_compose_returns_permission_denied() {
        let store = UnregisteredMailStore;
        let new_mail = NewMail {
            to: "alice@example.com".to_owned(),
            subject: "Test".to_owned(),
            body: "Hello.".to_owned(),
            cc: None,
        };
        let err = store.compose(&new_mail);
        assert!(err.is_err());
        assert!(err.err().unwrap().to_string().contains("not initialized"));
    }

    #[test]
    fn global_mail_store_returns_unregistered() {
        let store = global_mail_store();
        let query = MailQuery {
            search: None,
            mailbox: None,
            unread_only: false,
            limit: 5,
        };
        let result = store.list_messages(&query);
        assert!(result.is_err());
    }
}

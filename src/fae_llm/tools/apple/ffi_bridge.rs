//! FFI bridge stubs for Apple ecosystem stores.
//!
//! In production, the macOS Swift application registers real contact and
//! calendar store implementations at startup via `fae_register_contact_store`
//! and `fae_register_calendar_store`.  Before registration, all operations
//! return a `PermissionDenied` error with a clear diagnostic message.
//!
//! # Design
//!
//! - `global_contact_store()` returns an `Arc<dyn ContactStore>` that is safe
//!   to pass to tool constructors.
//! - `global_calendar_store()` returns an `Arc<dyn CalendarStore>`.
//! - Both return `UnregisteredContactStore` / `UnregisteredCalendarStore`
//!   until a real implementation is injected by the host platform.
//!
//! The registration functions are intentionally not yet implemented: they
//! will be added in Phase 3.4 when the JIT permission flow is wired.
//! For now the unregistered stores provide clear error messages that guide
//! diagnostics without panicking.

use std::sync::Arc;

use super::calendar::{
    CalendarEvent, CalendarInfo, CalendarStore, CalendarStoreError, EventPatch, EventQuery,
    NewCalendarEvent,
};
use super::contacts::{Contact, ContactQuery, ContactStore, ContactStoreError, NewContact};

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
}

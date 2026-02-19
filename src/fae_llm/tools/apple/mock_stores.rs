//! In-memory mock implementations of [`ContactStore`] and [`CalendarStore`].
//!
//! These are used exclusively in tests to exercise the tool layer without
//! requiring a macOS runtime or Apple framework access.

use std::sync::Mutex;

use super::calendar::{
    CalendarEvent, CalendarInfo, CalendarStore, CalendarStoreError, EventPatch, EventQuery,
    NewCalendarEvent,
};
use super::contacts::{Contact, ContactQuery, ContactStore, ContactStoreError, NewContact};

// ─── MockContactStore ─────────────────────────────────────────────────────────

/// An in-memory contact store for unit testing.
///
/// Supports substring search across name, email, and phone fields.
/// The `create` operation appends a new contact with a deterministic identifier.
pub struct MockContactStore {
    contacts: Mutex<Vec<Contact>>,
    next_id: Mutex<u64>,
}

impl MockContactStore {
    /// Create a mock store seeded with `contacts`.
    pub fn new(contacts: Vec<Contact>) -> Self {
        Self {
            contacts: Mutex::new(contacts),
            next_id: Mutex::new(1000),
        }
    }
}

impl ContactStore for MockContactStore {
    fn search(&self, query: &ContactQuery) -> Result<Vec<Contact>, ContactStoreError> {
        let contacts = self
            .contacts
            .lock()
            .map_err(|_| ContactStoreError::Backend("mock lock poisoned".to_owned()))?;

        let q_lower = query
            .query
            .as_deref()
            .map(|q| q.to_ascii_lowercase())
            .unwrap_or_default();

        let results: Vec<Contact> = contacts
            .iter()
            .filter(|c| {
                if q_lower.is_empty() {
                    return true;
                }
                let full_name = format!("{} {}", c.given_name, c.family_name).to_ascii_lowercase();
                if full_name.contains(&q_lower) {
                    return true;
                }
                if c.emails
                    .iter()
                    .any(|e| e.to_ascii_lowercase().contains(&q_lower))
                {
                    return true;
                }
                if c.phones.iter().any(|p| p.contains(&q_lower)) {
                    return true;
                }
                false
            })
            .take(query.limit)
            .cloned()
            .collect();

        Ok(results)
    }

    fn get(&self, identifier: &str) -> Result<Option<Contact>, ContactStoreError> {
        let contacts = self
            .contacts
            .lock()
            .map_err(|_| ContactStoreError::Backend("mock lock poisoned".to_owned()))?;

        Ok(contacts
            .iter()
            .find(|c| c.identifier == identifier)
            .cloned())
    }

    fn create(&self, contact: &NewContact) -> Result<Contact, ContactStoreError> {
        let mut contacts = self
            .contacts
            .lock()
            .map_err(|_| ContactStoreError::Backend("mock lock poisoned".to_owned()))?;
        let mut next_id = self
            .next_id
            .lock()
            .map_err(|_| ContactStoreError::Backend("mock lock poisoned".to_owned()))?;

        let id = format!("mock-contact-{}", *next_id);
        *next_id += 1;

        let new = Contact {
            identifier: id,
            given_name: contact.given_name.clone(),
            family_name: contact.family_name.clone().unwrap_or_default(),
            emails: contact
                .email
                .as_ref()
                .map(|e| vec![e.clone()])
                .unwrap_or_default(),
            phones: contact
                .phone
                .as_ref()
                .map(|p| vec![p.clone()])
                .unwrap_or_default(),
            addresses: vec![],
            birthday: None,
            organization: contact.organization.clone(),
            note: contact.note.clone(),
        };

        contacts.push(new.clone());
        Ok(new)
    }
}

// ─── MockCalendarStore ────────────────────────────────────────────────────────

/// An in-memory calendar store for unit testing.
///
/// All mutations operate on cloned in-memory state.
pub struct MockCalendarStore {
    calendars: Vec<CalendarInfo>,
    events: Mutex<Vec<CalendarEvent>>,
    next_id: Mutex<u64>,
}

impl MockCalendarStore {
    /// Create a mock store seeded with `calendars` and `events`.
    pub fn new(calendars: Vec<CalendarInfo>, events: Vec<CalendarEvent>) -> Self {
        Self {
            calendars,
            events: Mutex::new(events),
            next_id: Mutex::new(2000),
        }
    }
}

impl CalendarStore for MockCalendarStore {
    fn list_calendars(&self) -> Result<Vec<CalendarInfo>, CalendarStoreError> {
        Ok(self.calendars.clone())
    }

    fn list_events(&self, query: &EventQuery) -> Result<Vec<CalendarEvent>, CalendarStoreError> {
        let events = self
            .events
            .lock()
            .map_err(|_| CalendarStoreError::Backend("mock lock poisoned".to_owned()))?;

        let results: Vec<CalendarEvent> = events
            .iter()
            .filter(|e| {
                if query.calendar_ids.is_empty() {
                    return true;
                }
                query.calendar_ids.contains(&e.calendar_id)
            })
            .take(query.limit)
            .cloned()
            .collect();

        Ok(results)
    }

    fn create_event(&self, event: &NewCalendarEvent) -> Result<CalendarEvent, CalendarStoreError> {
        let mut events = self
            .events
            .lock()
            .map_err(|_| CalendarStoreError::Backend("mock lock poisoned".to_owned()))?;
        let mut next_id = self
            .next_id
            .lock()
            .map_err(|_| CalendarStoreError::Backend("mock lock poisoned".to_owned()))?;

        let id = format!("mock-event-{}", *next_id);
        *next_id += 1;

        // Pick the first writable calendar if no calendar_id specified
        let calendar_id = event.calendar_id.clone().unwrap_or_else(|| {
            self.calendars
                .iter()
                .find(|c| c.is_writable)
                .map(|c| c.identifier.clone())
                .unwrap_or_else(|| "default".to_owned())
        });

        let end = event
            .end
            .clone()
            .unwrap_or_else(|| format!("{}+01:00", event.start.trim_end_matches('Z')));

        let new_event = CalendarEvent {
            identifier: id,
            calendar_id,
            title: event.title.clone(),
            start: event.start.clone(),
            end,
            location: event.location.clone(),
            notes: event.notes.clone(),
            is_all_day: event.is_all_day,
            alarms: event.alarms.clone(),
        };

        events.push(new_event.clone());
        Ok(new_event)
    }

    fn update_event(
        &self,
        id: &str,
        patch: &EventPatch,
    ) -> Result<CalendarEvent, CalendarStoreError> {
        let mut events = self
            .events
            .lock()
            .map_err(|_| CalendarStoreError::Backend("mock lock poisoned".to_owned()))?;

        let event = events
            .iter_mut()
            .find(|e| e.identifier == id)
            .ok_or(CalendarStoreError::NotFound)?;

        if let Some(ref title) = patch.title {
            event.title = title.clone();
        }
        if let Some(ref start) = patch.start {
            event.start = start.clone();
        }
        if let Some(ref end) = patch.end {
            event.end = end.clone();
        }
        if let Some(ref location_opt) = patch.location {
            event.location = location_opt.clone();
        }
        if let Some(ref notes_opt) = patch.notes {
            event.notes = notes_opt.clone();
        }
        if let Some(ref alarms) = patch.alarms {
            event.alarms = alarms.clone();
        }

        Ok(event.clone())
    }

    fn delete_event(&self, id: &str) -> Result<(), CalendarStoreError> {
        let mut events = self
            .events
            .lock()
            .map_err(|_| CalendarStoreError::Backend("mock lock poisoned".to_owned()))?;

        let pos = events
            .iter()
            .position(|e| e.identifier == id)
            .ok_or(CalendarStoreError::NotFound)?;

        events.remove(pos);
        Ok(())
    }
}

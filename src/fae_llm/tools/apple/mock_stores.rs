//! In-memory mock implementations of [`ContactStore`], [`CalendarStore`],
//! [`ReminderStore`], and [`NoteStore`].
//!
//! These are used exclusively in tests to exercise the tool layer without
//! requiring a macOS runtime or Apple framework access.

use std::sync::Mutex;

use super::calendar::{
    CalendarEvent, CalendarInfo, CalendarStore, CalendarStoreError, EventPatch, EventQuery,
    NewCalendarEvent,
};
use super::contacts::{Contact, ContactQuery, ContactStore, ContactStoreError, NewContact};
use super::notes::{NewNote, Note, NoteQuery, NoteStore, NoteStoreError};
use super::reminders::{
    NewReminder, Reminder, ReminderList, ReminderQuery, ReminderStore, ReminderStoreError,
};

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

// ─── MockReminderStore ────────────────────────────────────────────────────────

/// An in-memory reminder store for unit testing.
///
/// Supports filtering by list ID, completed state, and limit.
/// The `create_reminder` and `set_completed` operations mutate in-memory state.
pub struct MockReminderStore {
    lists: Vec<ReminderList>,
    reminders: Mutex<Vec<Reminder>>,
    next_id: Mutex<u64>,
}

impl MockReminderStore {
    /// Create a mock store seeded with `lists` and `reminders`.
    pub fn new(lists: Vec<ReminderList>, reminders: Vec<Reminder>) -> Self {
        Self {
            lists,
            reminders: Mutex::new(reminders),
            next_id: Mutex::new(3000),
        }
    }
}

impl ReminderStore for MockReminderStore {
    fn list_reminder_lists(&self) -> Result<Vec<ReminderList>, ReminderStoreError> {
        Ok(self.lists.clone())
    }

    fn list_reminders(&self, query: &ReminderQuery) -> Result<Vec<Reminder>, ReminderStoreError> {
        let reminders = self
            .reminders
            .lock()
            .map_err(|_| ReminderStoreError::Backend("mock lock poisoned".to_owned()))?;

        let results: Vec<Reminder> = reminders
            .iter()
            .filter(|r| {
                if let Some(ref list_id) = query.list_id
                    && &r.list_id != list_id
                {
                    return false;
                }
                if !query.include_completed && r.is_completed {
                    return false;
                }
                true
            })
            .take(query.limit)
            .cloned()
            .collect();

        Ok(results)
    }

    fn get_reminder(&self, identifier: &str) -> Result<Option<Reminder>, ReminderStoreError> {
        let reminders = self
            .reminders
            .lock()
            .map_err(|_| ReminderStoreError::Backend("mock lock poisoned".to_owned()))?;

        Ok(reminders
            .iter()
            .find(|r| r.identifier == identifier)
            .cloned())
    }

    fn create_reminder(&self, reminder: &NewReminder) -> Result<Reminder, ReminderStoreError> {
        let mut reminders = self
            .reminders
            .lock()
            .map_err(|_| ReminderStoreError::Backend("mock lock poisoned".to_owned()))?;
        let mut next_id = self
            .next_id
            .lock()
            .map_err(|_| ReminderStoreError::Backend("mock lock poisoned".to_owned()))?;

        let id = format!("mock-reminder-{}", *next_id);
        *next_id += 1;

        // Use the first list if no list_id specified
        let list_id = reminder.list_id.clone().unwrap_or_else(|| {
            self.lists
                .first()
                .map(|l| l.identifier.clone())
                .unwrap_or_else(|| "default".to_owned())
        });

        let new_reminder = Reminder {
            identifier: id,
            list_id,
            title: reminder.title.clone(),
            notes: reminder.notes.clone(),
            due_date: reminder.due_date.clone(),
            priority: reminder.priority.unwrap_or(0),
            is_completed: false,
            completion_date: None,
        };

        reminders.push(new_reminder.clone());
        Ok(new_reminder)
    }

    fn set_completed(
        &self,
        identifier: &str,
        completed: bool,
    ) -> Result<Reminder, ReminderStoreError> {
        let mut reminders = self
            .reminders
            .lock()
            .map_err(|_| ReminderStoreError::Backend("mock lock poisoned".to_owned()))?;

        let reminder = reminders
            .iter_mut()
            .find(|r| r.identifier == identifier)
            .ok_or(ReminderStoreError::NotFound)?;

        reminder.is_completed = completed;
        reminder.completion_date = if completed {
            Some("2026-02-19T12:00:00".to_owned())
        } else {
            None
        };

        Ok(reminder.clone())
    }
}

// ─── MockNoteStore ────────────────────────────────────────────────────────────

/// An in-memory note store for unit testing.
///
/// Supports filtering by folder, substring search across title and body,
/// and limit. The `create_note` and `append_to_note` operations mutate
/// in-memory state.
pub struct MockNoteStore {
    notes: Mutex<Vec<Note>>,
    next_id: Mutex<u64>,
}

impl MockNoteStore {
    /// Create a mock store seeded with `notes`.
    pub fn new(notes: Vec<Note>) -> Self {
        Self {
            notes: Mutex::new(notes),
            next_id: Mutex::new(4000),
        }
    }
}

impl NoteStore for MockNoteStore {
    fn list_notes(&self, query: &NoteQuery) -> Result<Vec<Note>, NoteStoreError> {
        let notes = self
            .notes
            .lock()
            .map_err(|_| NoteStoreError::Backend("mock lock poisoned".to_owned()))?;

        let search_lower = query
            .search
            .as_deref()
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();

        let results: Vec<Note> = notes
            .iter()
            .filter(|n| {
                if let Some(ref folder) = query.folder
                    && n.folder.as_deref() != Some(folder.as_str())
                {
                    return false;
                }
                if !search_lower.is_empty() {
                    let title_lower = n.title.to_ascii_lowercase();
                    let body_lower = n.body.to_ascii_lowercase();
                    if !title_lower.contains(&search_lower) && !body_lower.contains(&search_lower) {
                        return false;
                    }
                }
                true
            })
            .take(query.limit)
            .cloned()
            .collect();

        Ok(results)
    }

    fn get_note(&self, identifier: &str) -> Result<Option<Note>, NoteStoreError> {
        let notes = self
            .notes
            .lock()
            .map_err(|_| NoteStoreError::Backend("mock lock poisoned".to_owned()))?;

        Ok(notes.iter().find(|n| n.identifier == identifier).cloned())
    }

    fn create_note(&self, note: &NewNote) -> Result<Note, NoteStoreError> {
        let mut notes = self
            .notes
            .lock()
            .map_err(|_| NoteStoreError::Backend("mock lock poisoned".to_owned()))?;
        let mut next_id = self
            .next_id
            .lock()
            .map_err(|_| NoteStoreError::Backend("mock lock poisoned".to_owned()))?;

        let id = format!("mock-note-{}", *next_id);
        *next_id += 1;

        let new_note = Note {
            identifier: id,
            title: note.title.clone(),
            body: note.body.clone(),
            folder: note.folder.clone(),
            created_at: Some("2026-02-19T12:00:00".to_owned()),
            modified_at: Some("2026-02-19T12:00:00".to_owned()),
        };

        notes.push(new_note.clone());
        Ok(new_note)
    }

    fn append_to_note(&self, identifier: &str, content: &str) -> Result<Note, NoteStoreError> {
        let mut notes = self
            .notes
            .lock()
            .map_err(|_| NoteStoreError::Backend("mock lock poisoned".to_owned()))?;

        let note = notes
            .iter_mut()
            .find(|n| n.identifier == identifier)
            .ok_or(NoteStoreError::NotFound)?;

        note.body = format!("{}\n{}", note.body, content);
        note.modified_at = Some("2026-02-19T12:00:00".to_owned());

        Ok(note.clone())
    }
}

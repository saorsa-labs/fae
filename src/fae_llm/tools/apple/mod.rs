//! Apple ecosystem tools — permission-gated LLM tools for macOS system data.
//!
//! This module provides tools that give Fae's LLM access to native macOS data:
//!
//! - **Contacts** — search, read, and create contacts via `CNContactStore`
//! - **Calendar** — list, create, update, and delete calendar events via `EventKit`
//! - **Reminders** — list, create, and complete reminders via `EventKit`
//! - **Notes** — list, read, create, and append to notes via AppleScript
//! - **Mail** — search inbox, read messages, and compose email via AppleScript
//!
//! # Architecture
//!
//! All tools depend on store traits ([`ContactStore`], [`CalendarStore`],
//! [`ReminderStore`], [`NoteStore`], [`MailStore`]) that abstract over the actual
//! Apple-framework implementation.  The store implementations live in [`ffi_bridge`]
//! (production, bridged through the Swift/C ABI) and in [`mock_stores`] (in-process
//! mocks used for unit tests).
//!
//! # Permission gating
//!
//! Every tool implements [`AppleEcosystemTool`], which adds a default
//! `is_available` method backed by the [`PermissionStore`].  The tool
//! registry in `src/agent/mod.rs` checks this before registering tools.
//!
//! [`ContactStore`]: contacts::ContactStore
//! [`CalendarStore`]: calendar::CalendarStore
//! [`ReminderStore`]: reminders::ReminderStore
//! [`NoteStore`]: notes::NoteStore
//! [`MailStore`]: mail::MailStore
//! [`PermissionStore`]: crate::permissions::PermissionStore

pub mod availability_gate;
pub mod calendar;
pub mod contacts;
pub mod ffi_bridge;
pub mod mail;
pub mod mock_stores;
pub mod notes;
pub mod rate_limiter;
pub mod reminders;
pub mod trait_def;

pub use calendar::{
    CalendarEvent, CalendarInfo, CalendarStore, CalendarStoreError, CreateEventTool,
    DeleteEventTool, EventPatch, EventQuery, ListCalendarsTool, ListEventsTool, NewCalendarEvent,
    UpdateEventTool,
};
pub use contacts::{
    Contact, ContactQuery, ContactStore, ContactStoreError, CreateContactTool, GetContactTool,
    NewContact, SearchContactsTool,
};
pub use ffi_bridge::{
    global_calendar_store, global_contact_store, global_mail_store, global_note_store,
    global_reminder_store,
};
pub use mail::{
    ComposeMailTool, GetMailTool, Mail, MailQuery, MailStore, MailStoreError, NewMail,
    SearchMailTool,
};
pub use notes::{
    AppendToNoteTool, CreateNoteTool, GetNoteTool, ListNotesTool, NewNote, Note, NoteQuery,
    NoteStore, NoteStoreError,
};
pub use reminders::{
    CreateReminderTool, ListReminderListsTool, ListRemindersTool, NewReminder, Reminder,
    ReminderList, ReminderQuery, ReminderStore, ReminderStoreError, SetReminderCompletedTool,
};
pub use availability_gate::AvailabilityGatedTool;
pub use rate_limiter::AppleRateLimiter;
pub use trait_def::AppleEcosystemTool;

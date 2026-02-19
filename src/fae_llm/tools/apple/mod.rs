//! Apple ecosystem tools — permission-gated LLM tools for macOS system data.
//!
//! This module provides tools that give Fae's LLM access to native macOS data:
//!
//! - **Contacts** — search, read, and create contacts via `CNContactStore`
//! - **Calendar** — list, create, update, and delete calendar events via `EventKit`
//!
//! # Architecture
//!
//! All tools depend on store traits ([`ContactStore`], [`CalendarStore`]) that abstract
//! over the actual Apple-framework implementation.  The store implementations live in
//! [`ffi_bridge`] (production, bridged through the Swift/C ABI) and in [`mock_stores`]
//! (in-process mocks used for unit tests).
//!
//! # Permission gating
//!
//! Every tool implements [`AppleEcosystemTool`], which adds a default
//! `is_available` method backed by the [`PermissionStore`].  The tool
//! registry in `src/agent/mod.rs` checks this before registering tools.
//!
//! [`ContactStore`]: contacts::ContactStore
//! [`CalendarStore`]: calendar::CalendarStore
//! [`PermissionStore`]: crate::permissions::PermissionStore

pub mod calendar;
pub mod contacts;
pub mod ffi_bridge;
pub mod mock_stores;
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
pub use ffi_bridge::{global_calendar_store, global_contact_store};
pub use trait_def::AppleEcosystemTool;

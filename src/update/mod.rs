//! Self-update system for Fae and Pi.
//!
//! Checks GitHub releases for newer versions, notifies the user, and applies
//! updates with platform-specific binary replacement. Supports both Fae and
//! Pi update channels with configurable auto-update preferences.

pub mod applier;
pub mod checker;
pub mod state;

pub use checker::{Release, UpdateChecker};
pub use state::{AutoUpdatePreference, UpdateState};

//! Self-update system for Fae and Pi.
//!
//! Checks GitHub releases for newer versions, notifies the user, and applies
//! updates with platform-specific binary replacement. Supports both Fae and
//! Pi update channels with configurable auto-update preferences.

pub mod applier;
pub mod checker;
pub mod state;

pub use applier::{
    StageResult, cleanup_old_backup, cleanup_staged_update, install_via_helper, rollback_update,
    stage_update, staging_directory, update_verification_warnings,
};
pub use checker::{Release, UpdateChecker};
pub use state::{AutoUpdatePreference, StagedUpdate, UpdateState};

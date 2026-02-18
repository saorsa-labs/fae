//! Permission registry for Fae's skill-gated capability system.
//!
//! Each system capability (microphone, contacts, calendar, etc.) is represented
//! by a [`PermissionKind`] variant. The [`PermissionStore`] tracks which
//! permissions the user has granted or denied, persisting in `config.toml`
//! under `[permissions]`.

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

/// A system capability that Fae can request access to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionKind {
    /// Microphone access for voice input (required for core functionality).
    Microphone,
    /// Apple Contacts for personalization (name, email).
    Contacts,
    /// Calendar access for scheduling skills.
    Calendar,
    /// Reminders access for task management skills.
    Reminders,
    /// Mail access for email skills.
    Mail,
    /// File system access for document skills.
    Files,
    /// Notification delivery permission.
    Notifications,
    /// Location access for weather/local skills.
    Location,
    /// Camera access for visual skills.
    Camera,
    /// Desktop automation (AppleScript, accessibility).
    DesktopAutomation,
}

impl PermissionKind {
    /// Return all permission variants.
    pub fn all() -> &'static [PermissionKind] {
        &[
            PermissionKind::Microphone,
            PermissionKind::Contacts,
            PermissionKind::Calendar,
            PermissionKind::Reminders,
            PermissionKind::Mail,
            PermissionKind::Files,
            PermissionKind::Notifications,
            PermissionKind::Location,
            PermissionKind::Camera,
            PermissionKind::DesktopAutomation,
        ]
    }
}

impl fmt::Display for PermissionKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            PermissionKind::Microphone => "microphone",
            PermissionKind::Contacts => "contacts",
            PermissionKind::Calendar => "calendar",
            PermissionKind::Reminders => "reminders",
            PermissionKind::Mail => "mail",
            PermissionKind::Files => "files",
            PermissionKind::Notifications => "notifications",
            PermissionKind::Location => "location",
            PermissionKind::Camera => "camera",
            PermissionKind::DesktopAutomation => "desktop_automation",
        };
        f.write_str(s)
    }
}

impl FromStr for PermissionKind {
    type Err = PermissionParseError;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "microphone" => Ok(PermissionKind::Microphone),
            "contacts" => Ok(PermissionKind::Contacts),
            "calendar" => Ok(PermissionKind::Calendar),
            "reminders" => Ok(PermissionKind::Reminders),
            "mail" => Ok(PermissionKind::Mail),
            "files" => Ok(PermissionKind::Files),
            "notifications" => Ok(PermissionKind::Notifications),
            "location" => Ok(PermissionKind::Location),
            "camera" => Ok(PermissionKind::Camera),
            "desktop_automation" | "desktopautomation" => Ok(PermissionKind::DesktopAutomation),
            _ => Err(PermissionParseError(s.to_owned())),
        }
    }
}

/// Error returned when parsing an unknown permission kind string.
#[derive(Debug, Clone)]
pub struct PermissionParseError(pub String);

impl fmt::Display for PermissionParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "unknown permission kind: {:?}", self.0)
    }
}

impl std::error::Error for PermissionParseError {}

/// A single permission grant record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionGrant {
    /// Which permission this grant covers.
    pub kind: PermissionKind,
    /// Whether the permission is currently granted.
    pub granted: bool,
    /// Epoch seconds when the grant was last updated.
    pub granted_at: Option<u64>,
}

/// Persistent store of permission grants.
///
/// Serializes to `config.toml` under `[permissions]`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PermissionStore {
    /// Individual permission grant records.
    #[serde(default)]
    pub grants: Vec<PermissionGrant>,
}

impl PermissionStore {
    /// Check whether a specific permission is currently granted.
    pub fn is_granted(&self, kind: PermissionKind) -> bool {
        self.grants
            .iter()
            .find(|g| g.kind == kind)
            .is_some_and(|g| g.granted)
    }

    /// Grant a permission, updating the timestamp.
    ///
    /// If the permission already exists in the store, it is updated in place.
    /// Otherwise a new record is appended.
    pub fn grant(&mut self, kind: PermissionKind) {
        let now = epoch_seconds();
        if let Some(existing) = self.grants.iter_mut().find(|g| g.kind == kind) {
            existing.granted = true;
            existing.granted_at = Some(now);
        } else {
            self.grants.push(PermissionGrant {
                kind,
                granted: true,
                granted_at: Some(now),
            });
        }
    }

    /// Deny (revoke) a permission.
    ///
    /// If the permission already exists, its `granted` flag is set to `false`.
    /// Otherwise a new denied record is appended.
    pub fn deny(&mut self, kind: PermissionKind) {
        if let Some(existing) = self.grants.iter_mut().find(|g| g.kind == kind) {
            existing.granted = false;
        } else {
            self.grants.push(PermissionGrant {
                kind,
                granted: false,
                granted_at: None,
            });
        }
    }

    /// Return all currently granted permission kinds.
    pub fn all_granted(&self) -> Vec<PermissionKind> {
        self.grants
            .iter()
            .filter(|g| g.granted)
            .map(|g| g.kind)
            .collect()
    }
}

/// Current epoch time in seconds (returns 0 on clock error).
fn epoch_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_store_is_empty() {
        let store = PermissionStore::default();
        assert!(store.grants.is_empty());
        assert!(store.all_granted().is_empty());
    }

    #[test]
    fn test_grant_and_query() {
        let mut store = PermissionStore::default();
        assert!(!store.is_granted(PermissionKind::Microphone));

        store.grant(PermissionKind::Microphone);
        assert!(store.is_granted(PermissionKind::Microphone));
        assert!(!store.is_granted(PermissionKind::Contacts));
    }

    #[test]
    fn test_deny_and_query() {
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Calendar);
        assert!(store.is_granted(PermissionKind::Calendar));

        store.deny(PermissionKind::Calendar);
        assert!(!store.is_granted(PermissionKind::Calendar));
    }

    #[test]
    fn test_grant_updates_timestamp() {
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Mail);
        let first_ts = store.grants[0].granted_at;

        // Grant again — should update timestamp (or keep same in fast test).
        store.grant(PermissionKind::Mail);
        assert_eq!(store.grants.len(), 1, "should not duplicate");
        assert!(store.grants[0].granted_at >= first_ts);
    }

    #[test]
    fn test_all_granted() {
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Microphone);
        store.grant(PermissionKind::Contacts);
        store.deny(PermissionKind::Calendar);

        let granted = store.all_granted();
        assert_eq!(granted.len(), 2);
        assert!(granted.contains(&PermissionKind::Microphone));
        assert!(granted.contains(&PermissionKind::Contacts));
        assert!(!granted.contains(&PermissionKind::Calendar));
    }

    #[test]
    fn test_permission_kind_display_fromstr_roundtrip() {
        for kind in PermissionKind::all() {
            let s = kind.to_string();
            let parsed: PermissionKind = s.parse().unwrap();
            assert_eq!(*kind, parsed, "round-trip failed for {kind}");
        }
    }

    #[test]
    fn test_double_grant_does_not_duplicate() {
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Files);
        store.grant(PermissionKind::Files);
        assert_eq!(store.grants.len(), 1);
    }

    #[test]
    fn test_deny_unknown_creates_record() {
        let mut store = PermissionStore::default();
        store.deny(PermissionKind::Camera);
        assert_eq!(store.grants.len(), 1);
        assert!(!store.is_granted(PermissionKind::Camera));
    }

    #[test]
    fn test_fromstr_case_insensitive() {
        assert_eq!(
            "MICROPHONE".parse::<PermissionKind>().unwrap(),
            PermissionKind::Microphone
        );
        assert_eq!(
            "Calendar".parse::<PermissionKind>().unwrap(),
            PermissionKind::Calendar
        );
    }

    #[test]
    fn test_fromstr_unknown_returns_error() {
        assert!("unknown_perm".parse::<PermissionKind>().is_err());
    }
}

//! Integration tests: permission grants control skill availability.

use fae::permissions::{PermissionKind, PermissionStore};
use fae::skills::builtins::builtin_skills;

#[test]
fn no_permissions_means_no_skills() {
    let set = builtin_skills();
    let store = PermissionStore::default();
    assert!(set.available(&store).is_empty());
    assert_eq!(set.unavailable(&store).len(), 9);
}

#[test]
fn granting_one_permission_activates_matching_skill() {
    let set = builtin_skills();
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Mail);

    let avail = set.available(&store);
    assert_eq!(avail.len(), 1);
    assert_eq!(avail[0].name(), "mail");
}

#[test]
fn granting_multiple_permissions_activates_multiple_skills() {
    let set = builtin_skills();
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Calendar);
    store.grant(PermissionKind::Contacts);
    store.grant(PermissionKind::Reminders);

    let avail = set.available(&store);
    assert_eq!(avail.len(), 3);

    let names: Vec<&str> = avail.iter().map(|s| s.name()).collect();
    assert!(names.contains(&"calendar"));
    assert!(names.contains(&"contacts"));
    assert!(names.contains(&"reminders"));
}

#[test]
fn revoking_permission_deactivates_skill() {
    let set = builtin_skills();
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Files);
    assert_eq!(set.available(&store).len(), 1);

    store.deny(PermissionKind::Files);
    assert!(set.available(&store).is_empty());
}

#[test]
fn prompt_fragments_only_from_available_skills() {
    let set = builtin_skills();
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Location);
    store.grant(PermissionKind::Notifications);

    let fragments = set.active_prompt_fragments(&store);

    // Available skills' fragments should be present.
    assert!(fragments.contains("location"));
    assert!(fragments.contains("notification"));

    // Unavailable skills' fragments should not.
    assert!(!fragments.contains("calendar tool"));
    assert!(!fragments.contains("email"));
    assert!(!fragments.contains("desktop automation"));
}

#[test]
fn microphone_permission_does_not_match_any_builtin_skill() {
    // Microphone is a core requirement, not a skill gate.
    let set = builtin_skills();
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Microphone);

    assert!(set.available(&store).is_empty());
}

#[test]
fn all_permissions_granted_activates_all_nine_skills() {
    let set = builtin_skills();
    let mut store = PermissionStore::default();
    for kind in PermissionKind::all() {
        store.grant(*kind);
    }

    assert_eq!(set.available(&store).len(), 9);
    assert!(set.unavailable(&store).is_empty());
}

#[test]
fn skill_set_get_finds_by_name() {
    let set = builtin_skills();
    let camera = set.get("camera");
    assert!(camera.is_some());
    assert_eq!(
        camera.map(|s| s.required_permissions()),
        Some([PermissionKind::Camera].as_slice())
    );
}

#[test]
fn permission_store_roundtrips_with_skill_availability() {
    let set = builtin_skills();
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Calendar);
    store.grant(PermissionKind::Mail);

    // Serialize and deserialize the store.
    let json = serde_json::to_string(&store).expect("serialize");
    let restored: PermissionStore = serde_json::from_str(&json).expect("deserialize");

    // Same skills should be available after round-trip.
    let before: Vec<&str> = set.available(&store).iter().map(|s| s.name()).collect();
    let after: Vec<&str> = set.available(&restored).iter().map(|s| s.name()).collect();
    assert_eq!(before, after);
}

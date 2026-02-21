//! Integration tests for the Python skill lifecycle management system.
//!
//! These tests exercise the full lifecycle pipeline end-to-end using
//! temporary directories for isolation:
//!
//! 1. Install a skill package (Pending)
//! 2. Advance to Testing
//! 3. Advance to Active
//! 4. Disable (Active → Disabled)
//! 5. Activate (Disabled → Active)
//! 6. Quarantine (Active → Quarantined)
//! 7. Rollback to last-known-good snapshot
//! 8. Verify re-install snapshots the previous version

#![allow(clippy::unwrap_used, clippy::expect_used)]

use fae::skills::python_lifecycle::{
    PythonSkillStatus, activate_python_skill_at, advance_python_skill_status_at,
    disable_python_skill_at, install_python_skill_at, list_python_skills_at,
    quarantine_python_skill_at, rollback_python_skill_at,
};
use fae::skills::SkillPaths;
use std::io::Write;
use std::path::Path;

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Returns a fresh temporary SkillPaths rooted at a unique temp directory.
fn test_paths(name: &str) -> SkillPaths {
    let root = std::env::temp_dir().join(format!("fae-lifecycle-test-{name}"));
    let _ = std::fs::remove_dir_all(&root);
    SkillPaths::for_root(root)
}

/// Writes a minimal `manifest.toml` + `skill.py` into `dir`.
fn write_package(dir: &Path, id: &str, version: &str, script_content: &str) {
    std::fs::create_dir_all(dir).expect("create pkg dir");

    let manifest = format!(
        "id = \"{id}\"\nname = \"{id}\"\nversion = \"{version}\"\nentry_file = \"skill.py\"\n"
    );
    let mut f =
        std::fs::File::create(dir.join("manifest.toml")).expect("create manifest.toml");
    f.write_all(manifest.as_bytes()).expect("write manifest");

    let mut s = std::fs::File::create(dir.join("skill.py")).expect("create skill.py");
    s.write_all(script_content.as_bytes()).expect("write skill.py");
}

// ── Install ───────────────────────────────────────────────────────────────────

#[test]
fn install_creates_pending_record() {
    let paths = test_paths("install-pending");
    let pkg = std::env::temp_dir().join("fae-pkg-install-pending");
    write_package(&pkg, "echo-bot", "1.0.0", "# echo-bot v1\nprint('hello')");

    let info = install_python_skill_at(&paths, &pkg).expect("install");

    assert_eq!(info.id, "echo-bot");
    assert_eq!(info.name, "echo-bot");
    assert_eq!(info.version, "1.0.0");
    assert_eq!(info.status, PythonSkillStatus::Pending);
    assert!(info.last_error.is_none());

    // The active script should be on disk.
    assert!(
        paths.root.join("echo-bot.py").is_file(),
        "active script should exist"
    );

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

#[test]
fn install_script_content_is_written() {
    let paths = test_paths("install-content");
    let pkg = std::env::temp_dir().join("fae-pkg-install-content");
    write_package(&pkg, "weather", "0.2.0", "# weather skill\nprint('sunny')");

    install_python_skill_at(&paths, &pkg).expect("install");

    let content = std::fs::read_to_string(paths.root.join("weather.py")).expect("read script");
    assert!(
        content.contains("weather skill"),
        "script content mismatch: {content}"
    );

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

#[test]
fn reinstall_creates_snapshot_of_previous_version() {
    let paths = test_paths("reinstall-snapshot");
    let pkg = std::env::temp_dir().join("fae-pkg-reinstall");
    write_package(&pkg, "notes", "1.0.0", "# notes v1\nprint('v1')");

    // Install v1 and advance to Active so it gets snapshotted.
    install_python_skill_at(&paths, &pkg).expect("install v1");
    advance_python_skill_status_at(&paths, "notes", PythonSkillStatus::Testing)
        .expect("advance to testing");
    advance_python_skill_status_at(&paths, "notes", PythonSkillStatus::Active)
        .expect("advance to active");

    // Install v2 — should snapshot v1.
    write_package(&pkg, "notes", "2.0.0", "# notes v2\nprint('v2')");
    let info2 = install_python_skill_at(&paths, &pkg).expect("install v2");

    assert_eq!(info2.version, "2.0.0");
    assert_eq!(info2.status, PythonSkillStatus::Pending);

    // The active script should now be v2.
    let active = std::fs::read_to_string(paths.root.join("notes.py")).expect("read active");
    assert!(active.contains("v2"), "active should be v2: {active}");

    // Snapshot dir should contain at least one file.
    let snaps: Vec<_> = std::fs::read_dir(paths.snapshots_dir)
        .expect("read snapshots")
        .flatten()
        .collect();
    assert!(!snaps.is_empty(), "expected at least one snapshot");

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

// ── Advance Status ────────────────────────────────────────────────────────────

#[test]
fn advance_pending_to_testing_to_active() {
    let paths = test_paths("advance-full");
    let pkg = std::env::temp_dir().join("fae-pkg-advance");
    write_package(&pkg, "calendar", "1.0.0", "# calendar\nprint('cal')");

    install_python_skill_at(&paths, &pkg).expect("install");

    advance_python_skill_status_at(&paths, "calendar", PythonSkillStatus::Testing)
        .expect("→ Testing");
    let skills = list_python_skills_at(&paths).expect("list");
    assert_eq!(
        skills.iter().find(|s| s.id == "calendar").map(|s| s.status),
        Some(PythonSkillStatus::Testing)
    );

    advance_python_skill_status_at(&paths, "calendar", PythonSkillStatus::Active)
        .expect("→ Active");
    let skills = list_python_skills_at(&paths).expect("list");
    assert_eq!(
        skills.iter().find(|s| s.id == "calendar").map(|s| s.status),
        Some(PythonSkillStatus::Active)
    );

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

#[test]
fn advance_invalid_transition_returns_error() {
    let paths = test_paths("advance-invalid");
    let pkg = std::env::temp_dir().join("fae-pkg-advance-invalid");
    write_package(&pkg, "bad-skill", "1.0.0", "# bad");

    install_python_skill_at(&paths, &pkg).expect("install");

    // Cannot skip Pending → Active
    let result =
        advance_python_skill_status_at(&paths, "bad-skill", PythonSkillStatus::Active);
    assert!(result.is_err(), "should reject invalid transition");

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

// ── Disable ───────────────────────────────────────────────────────────────────

#[test]
fn disable_moves_script_to_disabled_dir() {
    let paths = test_paths("disable");
    let pkg = std::env::temp_dir().join("fae-pkg-disable");
    write_package(&pkg, "reminders", "1.0.0", "# reminders");

    install_python_skill_at(&paths, &pkg).expect("install");
    advance_python_skill_status_at(&paths, "reminders", PythonSkillStatus::Testing)
        .expect("→ Testing");
    advance_python_skill_status_at(&paths, "reminders", PythonSkillStatus::Active)
        .expect("→ Active");

    disable_python_skill_at(&paths, "reminders").expect("disable");

    // Active script should be gone.
    assert!(
        !paths.root.join("reminders.py").is_file(),
        "active script should not exist after disable"
    );

    // Disabled dir should have the script.
    assert!(
        paths.disabled_dir.join("reminders.py").is_file(),
        "disabled script should exist"
    );

    let skills = list_python_skills_at(&paths).expect("list");
    assert_eq!(
        skills
            .iter()
            .find(|s| s.id == "reminders")
            .map(|s| s.status),
        Some(PythonSkillStatus::Disabled)
    );

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

// ── Activate ──────────────────────────────────────────────────────────────────

#[test]
fn activate_restores_disabled_script() {
    let paths = test_paths("activate");
    let pkg = std::env::temp_dir().join("fae-pkg-activate");
    write_package(&pkg, "mail", "1.0.0", "# mail skill");

    install_python_skill_at(&paths, &pkg).expect("install");
    advance_python_skill_status_at(&paths, "mail", PythonSkillStatus::Testing)
        .expect("→ Testing");
    advance_python_skill_status_at(&paths, "mail", PythonSkillStatus::Active)
        .expect("→ Active");
    disable_python_skill_at(&paths, "mail").expect("disable");

    // Verify disabled.
    assert!(!paths.root.join("mail.py").is_file());

    activate_python_skill_at(&paths, "mail").expect("activate");

    // Active script should be restored.
    assert!(
        paths.root.join("mail.py").is_file(),
        "active script should be restored"
    );

    let skills = list_python_skills_at(&paths).expect("list");
    assert_eq!(
        skills.iter().find(|s| s.id == "mail").map(|s| s.status),
        Some(PythonSkillStatus::Active)
    );

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

// ── Quarantine ────────────────────────────────────────────────────────────────

#[test]
fn quarantine_records_error_and_moves_script() {
    let paths = test_paths("quarantine");
    let pkg = std::env::temp_dir().join("fae-pkg-quarantine");
    write_package(&pkg, "discord", "1.0.0", "# discord");

    install_python_skill_at(&paths, &pkg).expect("install");
    advance_python_skill_status_at(&paths, "discord", PythonSkillStatus::Testing)
        .expect("→ Testing");
    advance_python_skill_status_at(&paths, "discord", PythonSkillStatus::Active)
        .expect("→ Active");

    quarantine_python_skill_at(&paths, "discord", "rate limited by Discord API").expect("quarantine");

    assert!(!paths.root.join("discord.py").is_file());

    let skills = list_python_skills_at(&paths).expect("list");
    let skill = skills.iter().find(|s| s.id == "discord").expect("skill");
    assert_eq!(skill.status, PythonSkillStatus::Quarantined);
    assert_eq!(
        skill.last_error.as_deref(),
        Some("rate limited by Discord API")
    );

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

// ── Rollback ──────────────────────────────────────────────────────────────────

#[test]
fn rollback_restores_previous_script_content() {
    let paths = test_paths("rollback");
    let pkg = std::env::temp_dir().join("fae-pkg-rollback");

    // Install v1.
    write_package(&pkg, "contacts", "1.0.0", "# contacts v1\nprint('v1')");
    install_python_skill_at(&paths, &pkg).expect("install v1");
    advance_python_skill_status_at(&paths, "contacts", PythonSkillStatus::Testing)
        .expect("→ Testing");
    advance_python_skill_status_at(&paths, "contacts", PythonSkillStatus::Active)
        .expect("→ Active");

    // Install v2 (snapshots v1).
    write_package(&pkg, "contacts", "2.0.0", "# contacts v2\nprint('v2')");
    install_python_skill_at(&paths, &pkg).expect("install v2");

    // Active should be v2.
    let content = std::fs::read_to_string(paths.root.join("contacts.py")).expect("read");
    assert!(content.contains("v2"), "active should be v2");

    // Rollback should restore v1.
    rollback_python_skill_at(&paths, "contacts").expect("rollback");

    let rolled = std::fs::read_to_string(paths.root.join("contacts.py")).expect("read rolled");
    assert!(rolled.contains("v1"), "rolled back should be v1: {rolled}");

    let skills = list_python_skills_at(&paths).expect("list");
    assert_eq!(
        skills
            .iter()
            .find(|s| s.id == "contacts")
            .map(|s| s.status),
        Some(PythonSkillStatus::Active)
    );

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

#[test]
fn rollback_with_no_snapshot_returns_error() {
    let paths = test_paths("rollback-no-snapshot");
    let pkg = std::env::temp_dir().join("fae-pkg-rollback-no-snapshot");
    write_package(&pkg, "fresh", "1.0.0", "# fresh");

    install_python_skill_at(&paths, &pkg).expect("install");

    // No prior version — no snapshot exists.
    let result = rollback_python_skill_at(&paths, "fresh");
    assert!(result.is_err(), "expected error when no snapshot");
    let msg = result.unwrap_err().to_string();
    assert!(
        msg.contains("no rollback snapshot"),
        "expected snapshot error, got: {msg}"
    );

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

// ── List ─────────────────────────────────────────────────────────────────────

#[test]
fn list_returns_all_registered_skills() {
    let paths = test_paths("list-all");
    let pkg1 = std::env::temp_dir().join("fae-pkg-list-1");
    let pkg2 = std::env::temp_dir().join("fae-pkg-list-2");

    write_package(&pkg1, "alpha", "1.0.0", "# alpha");
    write_package(&pkg2, "beta", "1.0.0", "# beta");

    install_python_skill_at(&paths, &pkg1).expect("install alpha");
    install_python_skill_at(&paths, &pkg2).expect("install beta");

    let skills = list_python_skills_at(&paths).expect("list");
    assert_eq!(skills.len(), 2);
    assert!(skills.iter().any(|s| s.id == "alpha"));
    assert!(skills.iter().any(|s| s.id == "beta"));

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg1);
    let _ = std::fs::remove_dir_all(&pkg2);
}

#[test]
fn list_empty_when_no_skills_registered() {
    let paths = test_paths("list-empty");
    let skills = list_python_skills_at(&paths).expect("list");
    assert!(skills.is_empty());
    let _ = std::fs::remove_dir_all(&paths.root);
}

// ── Install missing entry file ────────────────────────────────────────────────

#[test]
fn install_missing_entry_file_returns_error() {
    let paths = test_paths("install-missing-entry");
    let pkg = std::env::temp_dir().join("fae-pkg-missing-entry");
    std::fs::create_dir_all(&pkg).expect("create pkg dir");

    // Write manifest referencing a file that doesn't exist.
    let manifest =
        "id = \"ghost\"\nname = \"Ghost\"\nversion = \"1.0.0\"\nentry_file = \"ghost.py\"\n";
    std::fs::write(pkg.join("manifest.toml"), manifest).expect("write manifest");
    // Do NOT write ghost.py.

    let result = install_python_skill_at(&paths, &pkg);
    assert!(result.is_err());
    let msg = result.unwrap_err().to_string();
    assert!(
        msg.contains("entry file") || msg.contains("not found"),
        "expected entry file error, got: {msg}"
    );

    let _ = std::fs::remove_dir_all(&paths.root);
    let _ = std::fs::remove_dir_all(&pkg);
}

// ── Skills not found ──────────────────────────────────────────────────────────

#[test]
fn disable_nonexistent_skill_returns_error() {
    let paths = test_paths("disable-nonexistent");
    let result = disable_python_skill_at(&paths, "nonexistent");
    assert!(result.is_err());
    let _ = std::fs::remove_dir_all(&paths.root);
}

#[test]
fn activate_nonexistent_skill_returns_error() {
    let paths = test_paths("activate-nonexistent");
    let result = activate_python_skill_at(&paths, "nonexistent");
    assert!(result.is_err());
    let _ = std::fs::remove_dir_all(&paths.root);
}

#[test]
fn quarantine_nonexistent_skill_returns_error() {
    let paths = test_paths("quarantine-nonexistent");
    let result = quarantine_python_skill_at(&paths, "nonexistent", "error");
    assert!(result.is_err());
    let _ = std::fs::remove_dir_all(&paths.root);
}

#[test]
fn rollback_nonexistent_skill_returns_error() {
    let paths = test_paths("rollback-nonexistent");
    let result = rollback_python_skill_at(&paths, "nonexistent");
    assert!(result.is_err());
    let _ = std::fs::remove_dir_all(&paths.root);
}

#![allow(clippy::unwrap_used, clippy::expect_used)]

use fae::config::MemoryConfig;
use fae::memory::{MemoryOrchestrator, MemoryRepository, MemoryStatus};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn temp_root(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "fae-memory-int-{name}-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    std::fs::create_dir_all(&dir).expect("create temp test dir");
    dir
}

fn cfg_for(root: &Path) -> MemoryConfig {
    MemoryConfig {
        root_dir: root.to_path_buf(),
        ..MemoryConfig::default()
    }
}

#[test]
fn contradiction_resolution_supersedes_name_memory() {
    let root = temp_root("name-contradiction");
    let orchestrator = MemoryOrchestrator::new(&cfg_for(&root));

    orchestrator
        .capture_turn("turn-1", "My name is Alice.", "Hello Alice")
        .expect("capture first turn");
    orchestrator
        .capture_turn("turn-2", "Actually my name is Bob.", "Thanks Bob")
        .expect("capture second turn");

    let repo = MemoryRepository::new(&root);
    let name_records = repo
        .find_active_by_tag("name")
        .expect("find active name records");
    assert_eq!(name_records.len(), 1);
    assert!(name_records[0].text.contains("Bob"));

    let all = repo.list_records().expect("list records");
    let superseded = all
        .iter()
        .filter(|r| r.tags.iter().any(|t| t == "name") && r.status == MemoryStatus::Superseded)
        .count();
    assert!(superseded >= 1);

    let recall = orchestrator
        .recall_context("what is my name")
        .expect("recall")
        .unwrap_or_default();
    assert!(recall.contains("Bob"));
    assert!(!recall.contains("Alice"));

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn contradiction_resolution_supersedes_preference_memory() {
    let root = temp_root("preference-contradiction");
    let orchestrator = MemoryOrchestrator::new(&cfg_for(&root));

    orchestrator
        .capture_turn("turn-1", "I prefer tea.", "Noted")
        .expect("capture first preference");
    orchestrator
        .capture_turn("turn-2", "Actually I prefer coffee.", "Noted")
        .expect("capture second preference");

    let repo = MemoryRepository::new(&root);
    let active_pref = repo
        .find_active_by_tag("preference")
        .expect("find active preferences");

    assert_eq!(active_pref.len(), 1);
    assert!(active_pref[0].text.to_ascii_lowercase().contains("coffee"));

    let all = repo.list_records().expect("list records");
    let superseded_pref = all
        .iter()
        .filter(|r| {
            r.tags.iter().any(|t| t == "preference") && r.status == MemoryStatus::Superseded
        })
        .count();
    assert!(superseded_pref >= 1);

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn migration_rollback_restores_fixture_manifest_and_records_on_failure() {
    let root = temp_root("rollback");
    let repo = MemoryRepository::new(&root);
    repo.ensure_layout().expect("ensure layout");

    let memory_dir = root.join("memory");
    let manifest_path = memory_dir.join("manifest.toml");
    let records_path = memory_dir.join("records.jsonl");
    let failpoint_path = memory_dir.join(".fail_migration");

    let fixture_manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("memory")
        .join("manifest_v0.toml");
    let fixture_manifest_text =
        std::fs::read_to_string(&fixture_manifest).expect("read fixture manifest text");

    std::fs::copy(&fixture_manifest, &manifest_path).expect("copy fixture manifest");

    let original_records = r#"{"id":"legacy-1","kind":"fact","text":"legacy fact","created_at":1700000000,"updated_at":1700000000}
"#;
    std::fs::write(&records_path, original_records).expect("write records fixture");

    std::fs::write(&failpoint_path, "1").expect("write failpoint");

    let result = repo.migrate_if_needed(1);
    assert!(
        result.is_err(),
        "migration should fail when failpoint is present"
    );

    let manifest_after = std::fs::read_to_string(&manifest_path).expect("read manifest after fail");
    let records_after = std::fs::read_to_string(&records_path).expect("read records after fail");

    assert_eq!(manifest_after, fixture_manifest_text);
    assert_eq!(records_after, original_records);

    std::fs::remove_file(&failpoint_path).expect("remove failpoint");

    let migrated = repo
        .migrate_if_needed(1)
        .expect("migration after failpoint removed should succeed");
    assert_eq!(migrated, Some((0, 1)));

    let schema = repo.schema_version().expect("schema version");
    assert_eq!(schema, 1);

    let _ = std::fs::remove_dir_all(root);
}

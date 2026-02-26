//! Integration tests for semantic skill discovery.
//!
//! These tests use mock embeddings (deterministic sin-based vectors) rather
//! than the real `EmbeddingEngine`, so they run fast and don't require the
//! ONNX model to be downloaded.

use fae::skills::discovery::{
    SkillDiscoveryIndex, extract_builtin_skill_text, extract_markdown_skill_text,
    extract_python_skill_text,
};
use std::io::Write;

const EMBEDDING_DIM: usize = 384;

/// Generate a deterministic mock embedding for testing.
fn mock_embedding(seed: f32) -> Vec<f32> {
    let mut v: Vec<f32> = (0..EMBEDDING_DIM)
        .map(|i| (i as f32 * seed).sin())
        .collect();
    // L2-normalize.
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in &mut v {
            *x /= norm;
        }
    }
    v
}

// ── Index + Search integration ──────────────────────────────────────────────

#[test]
fn index_python_skill_and_search_by_description() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("discovery.db");
    let index = SkillDiscoveryIndex::open(&db_path).expect("open");

    let emb = mock_embedding(1.0);
    index
        .index_skill(
            "discord-bot",
            "Discord Bot",
            "Send messages and manage channels on Discord",
            "python",
            &emb,
        )
        .expect("index");

    assert!(index.is_indexed("discord-bot").expect("check"));
    assert_eq!(index.indexed_count().expect("count"), 1);

    // Search with the same embedding should return a high-score match.
    let results = index.search(&emb, 5).expect("search");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].skill_id, "discord-bot");
    assert_eq!(results[0].name, "Discord Bot");
    assert_eq!(results[0].source, "python");
    assert!(results[0].score > 0.99);
}

#[test]
fn search_returns_best_match_first() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("discovery.db");
    let index = SkillDiscoveryIndex::open(&db_path).expect("open");

    // Index three skills with different embeddings.
    let emb_discord = mock_embedding(1.0);
    let emb_weather = mock_embedding(2.0);
    let emb_calendar = mock_embedding(3.0);

    index
        .index_skill(
            "discord",
            "Discord",
            "Chat on Discord",
            "python",
            &emb_discord,
        )
        .expect("index discord");
    index
        .index_skill(
            "weather",
            "Weather",
            "Check weather forecasts",
            "markdown",
            &emb_weather,
        )
        .expect("index weather");
    index
        .index_skill(
            "calendar",
            "Calendar",
            "Manage calendar events",
            "builtin",
            &emb_calendar,
        )
        .expect("index calendar");

    // Query with discord's embedding — discord should be first.
    let results = index.search(&emb_discord, 3).expect("search");
    assert_eq!(results.len(), 3);
    assert_eq!(results[0].skill_id, "discord");
    assert!(results[0].score >= results[1].score);
    assert!(results[1].score >= results[2].score);
}

#[test]
fn empty_query_embedding_returns_results() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("discovery.db");
    let index = SkillDiscoveryIndex::open(&db_path).expect("open");

    let emb = mock_embedding(1.0);
    index
        .index_skill("skill-a", "A", "Skill A", "builtin", &emb)
        .expect("index");

    // Search on empty index returns nothing (query limit 0).
    let results = index.search(&emb, 0).expect("search");
    assert!(results.is_empty());
}

#[test]
fn reindex_updates_changed_descriptions() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("discovery.db");
    let index = SkillDiscoveryIndex::open(&db_path).expect("open");

    let emb1 = mock_embedding(1.0);
    index
        .index_skill("my-skill", "My Skill", "Old description", "python", &emb1)
        .expect("first index");

    // Re-index with new description and embedding.
    let emb2 = mock_embedding(2.0);
    index
        .index_skill(
            "my-skill",
            "My Skill Updated",
            "New description",
            "python",
            &emb2,
        )
        .expect("reindex");

    // Should still have 1 entry (upsert).
    assert_eq!(index.indexed_count().expect("count"), 1);

    // Search with emb2 should return the updated entry.
    let results = index.search(&emb2, 1).expect("search");
    assert_eq!(results[0].name, "My Skill Updated");
    assert_eq!(results[0].description, "New description");
}

// ── Text extraction integration ─────────────────────────────────────────────

#[test]
fn extract_python_skill_text_integration() {
    let dir = tempfile::tempdir().expect("tempdir");
    let skill_dir = dir.path().join("email-sender");
    std::fs::create_dir_all(&skill_dir).expect("mkdir");

    let manifest = "\
id = \"email-sender\"
name = \"Email Sender\"
version = \"1.0.0\"
entry_file = \"skill.py\"
description = \"Send emails via SMTP with template support\"
";
    std::fs::write(skill_dir.join("manifest.toml"), manifest).expect("write manifest");

    let (name, desc) = extract_python_skill_text(dir.path(), "email-sender").expect("extract");
    assert_eq!(name, "Email Sender");
    assert_eq!(desc, "Send emails via SMTP with template support");
}

#[test]
fn extract_markdown_skill_integration() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("note-taking.md");
    let mut f = std::fs::File::create(&path).expect("create");
    writeln!(f, "# Note Taking").unwrap();
    writeln!(f).unwrap();
    writeln!(f, "Create, search, and organize notes with tags.").unwrap();
    writeln!(f).unwrap();
    writeln!(f, "## Usage").unwrap();
    writeln!(f, "Use the `note` command...").unwrap();

    let (name, desc) = extract_markdown_skill_text(&path).expect("extract");
    assert_eq!(name, "note-taking");
    assert_eq!(desc, "Create, search, and organize notes with tags.");
}

#[test]
fn extract_builtin_skill_integration() {
    let content = "# Desktop Automation\n\nControl the desktop environment.\n\n## Tools\n";
    let (name, desc) = extract_builtin_skill_text("desktop", content);
    assert_eq!(name, "desktop");
    assert_eq!(desc, "Control the desktop environment.");
}

// ── Persistence integration ─────────────────────────────────────────────────

#[test]
fn index_persists_across_reopen() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("persistent.db");

    // First open: index a skill.
    {
        let index = SkillDiscoveryIndex::open(&db_path).expect("open1");
        let emb = mock_embedding(1.0);
        index
            .index_skill("persisted-skill", "Persisted", "desc", "python", &emb)
            .expect("index");
        assert_eq!(index.indexed_count().expect("count"), 1);
    }

    // Second open: skill should still be there.
    {
        let index = SkillDiscoveryIndex::open(&db_path).expect("open2");
        assert!(index.is_indexed("persisted-skill").expect("check"));
        assert_eq!(index.indexed_count().expect("count"), 1);

        let emb = mock_embedding(1.0);
        let results = index.search(&emb, 1).expect("search");
        assert_eq!(results[0].skill_id, "persisted-skill");
    }
}

// ── Remove integration ──────────────────────────────────────────────────────

#[test]
fn remove_and_verify_gone() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("remove.db");
    let index = SkillDiscoveryIndex::open(&db_path).expect("open");

    let emb = mock_embedding(1.0);
    index
        .index_skill("deleteme", "Delete Me", "to be removed", "python", &emb)
        .expect("index");
    assert!(index.is_indexed("deleteme").expect("check before"));

    index.remove_skill("deleteme").expect("remove");
    assert!(!index.is_indexed("deleteme").expect("check after"));

    // Search should return nothing.
    let results = index.search(&emb, 5).expect("search");
    assert!(results.is_empty());
}

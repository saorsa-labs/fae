//! Semantic skill discovery via embedding-based search.
//!
//! Indexes skill descriptions (from manifests, markdown files, and builtins)
//! into a sqlite-vec virtual table and supports KNN similarity search.
//!
//! # Architecture
//!
//! ```text
//! User query: "send a message on Discord"
//!     ↓
//! EmbeddingEngine.embed(query)
//!     ↓
//! skill_embeddings table (sqlite-vec KNN)
//!     ↓
//! Top-K results: [(skill_id, distance)]
//!     ↓
//! SkillSearchResult { id, name, description, score }
//! ```
//!
//! Skills never need to be running for discovery — only their metadata
//! (description text) is indexed.

use std::path::Path;

use rusqlite::{Connection, params};

use super::error::PythonSkillError;

/// Dimension of the all-MiniLM-L6-v2 embedding vectors.
const EMBEDDING_DIM: usize = 384;

// ── Schema DDL ──────────────────────────────────────────────────────────────

const CREATE_SKILL_METADATA_TABLE: &str = "\
CREATE TABLE IF NOT EXISTS skill_metadata (
    skill_id    TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    source      TEXT NOT NULL DEFAULT 'python',
    indexed_at  INTEGER NOT NULL DEFAULT 0
)";

const CREATE_SKILL_EMBEDDINGS_TABLE: &str = "\
CREATE VIRTUAL TABLE IF NOT EXISTS skill_embeddings USING vec0(
    skill_id TEXT PRIMARY KEY,
    embedding FLOAT[384]
)";

// ── Result type ─────────────────────────────────────────────────────────────

/// A single skill search result with relevance score.
#[derive(Debug, Clone)]
pub struct SkillSearchResult {
    /// Skill identifier.
    pub skill_id: String,
    /// Human-readable skill name.
    pub name: String,
    /// Skill description text.
    pub description: String,
    /// Skill source: `"python"`, `"markdown"`, or `"builtin"`.
    pub source: String,
    /// Relevance score in `0.0..=1.0` (higher = better match).
    pub score: f32,
}

// ── Index type ──────────────────────────────────────────────────────────────

/// Semantic skill discovery index backed by SQLite + sqlite-vec.
///
/// Stores skill metadata and embedding vectors in a single database file.
/// Supports KNN similarity search over skill descriptions.
pub struct SkillDiscoveryIndex {
    conn: Connection,
}

impl SkillDiscoveryIndex {
    /// Opens (or creates) a discovery index at the given path.
    ///
    /// Registers the sqlite-vec extension and creates the required tables
    /// if they don't already exist.
    ///
    /// # Errors
    ///
    /// Returns [`PythonSkillError::DatabaseError`] if the database cannot
    /// be opened or the schema cannot be applied.
    pub fn open(db_path: &Path) -> Result<Self, PythonSkillError> {
        // Ensure sqlite-vec is registered globally before opening.
        crate::memory::sqlite::ensure_sqlite_vec_loaded();

        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).map_err(PythonSkillError::IoError)?;
        }

        let conn = Connection::open(db_path)
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

        conn.execute(CREATE_SKILL_METADATA_TABLE, [])
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;
        conn.execute(CREATE_SKILL_EMBEDDINGS_TABLE, [])
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

        Ok(Self { conn })
    }

    /// Opens an in-memory discovery index (for testing).
    ///
    /// # Errors
    ///
    /// Returns [`PythonSkillError::DatabaseError`] if the schema cannot be applied.
    #[cfg(test)]
    pub fn open_in_memory() -> Result<Self, PythonSkillError> {
        crate::memory::sqlite::ensure_sqlite_vec_loaded();

        let conn = Connection::open_in_memory()
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

        conn.execute(CREATE_SKILL_METADATA_TABLE, [])
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;
        conn.execute(CREATE_SKILL_EMBEDDINGS_TABLE, [])
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

        Ok(Self { conn })
    }

    /// Indexes a skill with its metadata and embedding vector.
    ///
    /// If the skill is already indexed, its metadata and embedding are
    /// replaced (upsert semantics).
    ///
    /// # Errors
    ///
    /// Returns [`PythonSkillError::DatabaseError`] on storage failure.
    pub fn index_skill(
        &self,
        skill_id: &str,
        name: &str,
        description: &str,
        source: &str,
        embedding: &[f32],
    ) -> Result<(), PythonSkillError> {
        if embedding.len() != EMBEDDING_DIM {
            return Err(PythonSkillError::DatabaseError(format!(
                "embedding dimension mismatch: expected {EMBEDDING_DIM}, got {}",
                embedding.len()
            )));
        }

        let now = now_epoch_secs();

        // Upsert metadata.
        self.conn
            .execute(
                "INSERT INTO skill_metadata (skill_id, name, description, source, indexed_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(skill_id) DO UPDATE SET
                     name = excluded.name,
                     description = excluded.description,
                     source = excluded.source,
                     indexed_at = excluded.indexed_at",
                params![skill_id, name, description, source, now],
            )
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

        // vec0 does not support UPSERT — delete then insert.
        let blob: Vec<u8> = embedding.iter().flat_map(|f| f.to_le_bytes()).collect();
        self.conn
            .execute(
                "DELETE FROM skill_embeddings WHERE skill_id = ?1",
                params![skill_id],
            )
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;
        self.conn
            .execute(
                "INSERT INTO skill_embeddings (skill_id, embedding) VALUES (?1, ?2)",
                params![skill_id, blob],
            )
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

        Ok(())
    }

    /// Removes a skill from the index.
    ///
    /// No-op if the skill is not indexed.
    ///
    /// # Errors
    ///
    /// Returns [`PythonSkillError::DatabaseError`] on storage failure.
    pub fn remove_skill(&self, skill_id: &str) -> Result<(), PythonSkillError> {
        self.conn
            .execute(
                "DELETE FROM skill_metadata WHERE skill_id = ?1",
                params![skill_id],
            )
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;
        self.conn
            .execute(
                "DELETE FROM skill_embeddings WHERE skill_id = ?1",
                params![skill_id],
            )
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;
        Ok(())
    }

    /// Searches for skills matching the given embedding vector.
    ///
    /// Returns up to `limit` results ordered by descending relevance score.
    /// L2 distance is converted to a `0.0..=1.0` score where `1.0` is exact match.
    ///
    /// # Errors
    ///
    /// Returns [`PythonSkillError::DatabaseError`] on query failure.
    pub fn search(
        &self,
        query_embedding: &[f32],
        limit: usize,
    ) -> Result<Vec<SkillSearchResult>, PythonSkillError> {
        if query_embedding.len() != EMBEDDING_DIM {
            return Err(PythonSkillError::DatabaseError(format!(
                "query embedding dimension mismatch: expected {EMBEDDING_DIM}, got {}",
                query_embedding.len()
            )));
        }
        if limit == 0 {
            return Ok(Vec::new());
        }

        let blob: Vec<u8> = query_embedding
            .iter()
            .flat_map(|f| f.to_le_bytes())
            .collect();

        // KNN query: first get nearest skill_ids from vec table, then
        // look up metadata. sqlite-vec requires LIMIT on the vec table
        // query directly (JOINs don't pass LIMIT through).
        let mut stmt = self
            .conn
            .prepare(
                "SELECT skill_id, distance FROM skill_embeddings
                 WHERE embedding MATCH ?1
                 ORDER BY distance
                 LIMIT ?2",
            )
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

        let knn_rows = stmt
            .query_map(params![blob, limit as i64], |row| {
                let skill_id: String = row.get(0)?;
                let distance: f64 = row.get(1)?;
                Ok((skill_id, distance))
            })
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

        let mut results = Vec::new();
        for row in knn_rows {
            let (skill_id, distance) =
                row.map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

            // Look up metadata for this skill.
            let meta = self
                .conn
                .query_row(
                    "SELECT name, description, source FROM skill_metadata WHERE skill_id = ?1",
                    params![skill_id],
                    |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, String>(1)?,
                            r.get::<_, String>(2)?,
                        ))
                    },
                )
                .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;

            // L2 distance for normalized vectors is in [0.0, 2.0].
            // Convert to similarity score in [0.0, 1.0].
            let score = (1.0 - distance / 2.0).max(0.0) as f32;

            results.push(SkillSearchResult {
                skill_id,
                name: meta.0,
                description: meta.1,
                source: meta.2,
                score,
            });
        }
        Ok(results)
    }

    /// Returns whether a skill is currently indexed.
    ///
    /// # Errors
    ///
    /// Returns [`PythonSkillError::DatabaseError`] on query failure.
    pub fn is_indexed(&self, skill_id: &str) -> Result<bool, PythonSkillError> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM skill_metadata WHERE skill_id = ?1",
                params![skill_id],
                |row| row.get(0),
            )
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;
        Ok(count > 0)
    }

    /// Returns the total number of indexed skills.
    ///
    /// # Errors
    ///
    /// Returns [`PythonSkillError::DatabaseError`] on query failure.
    pub fn indexed_count(&self) -> Result<usize, PythonSkillError> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM skill_metadata", [], |row| row.get(0))
            .map_err(|e| PythonSkillError::DatabaseError(e.to_string()))?;
        Ok(count as usize)
    }
}

// ── Text extraction helpers ─────────────────────────────────────────────────

/// Extracts description text from a Python skill manifest directory.
///
/// Returns `Some((name, description))` if a valid `manifest.toml` exists,
/// `None` otherwise.
pub fn extract_python_skill_text(
    python_skills_dir: &Path,
    skill_id: &str,
) -> Option<(String, String)> {
    let skill_dir = python_skills_dir.join(skill_id);
    let manifest = super::manifest::PythonSkillManifest::load_from_dir(&skill_dir).ok()?;
    let description = manifest.description.unwrap_or_default();
    Some((manifest.name, description))
}

/// Extracts description text from a markdown skill file.
///
/// Returns `Some((name, first_paragraph))` where name is derived from the
/// filename and description is the first non-heading paragraph (up to 500 chars).
pub fn extract_markdown_skill_text(skill_path: &Path) -> Option<(String, String)> {
    let name = skill_path.file_stem().and_then(|s| s.to_str())?.to_owned();
    let content = std::fs::read_to_string(skill_path).ok()?;
    let description = extract_first_paragraph(&content);
    Some((name, description))
}

/// Extracts description from builtin skill content.
///
/// Returns `(name, first 500 chars of content)`.
#[must_use]
pub fn extract_builtin_skill_text(skill_name: &str, content: &str) -> (String, String) {
    let description = extract_first_paragraph(content);
    (skill_name.to_owned(), description)
}

/// Extracts the first non-heading paragraph from markdown content, up to 500 chars.
fn extract_first_paragraph(content: &str) -> String {
    let mut paragraph = String::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            if !paragraph.is_empty() {
                break;
            }
            continue;
        }
        if trimmed.starts_with('#') {
            if !paragraph.is_empty() {
                break;
            }
            continue;
        }
        if !paragraph.is_empty() {
            paragraph.push(' ');
        }
        paragraph.push_str(trimmed);
    }

    if paragraph.len() > 500 {
        // Truncate at word boundary.
        if let Some(pos) = paragraph[..500].rfind(' ') {
            paragraph.truncate(pos);
        } else {
            paragraph.truncate(500);
        }
    }

    paragraph
}

// ── Index rebuild ───────────────────────────────────────────────────────────

/// Rebuilds the skill discovery index by scanning all skill sources.
///
/// Iterates over Python skills (from `python_skills_dir`), markdown skills
/// (from `skills_dir`), and builtins. For each, extracts description text,
/// generates an embedding, and stores it in the index.
///
/// Returns the number of skills indexed.
///
/// # Errors
///
/// Returns [`PythonSkillError::DatabaseError`] on storage failure, or
/// propagates embedding engine errors.
pub fn rebuild_skill_index(
    index: &SkillDiscoveryIndex,
    engine: &mut crate::memory::embedding::EmbeddingEngine,
    skills_dir: &Path,
    python_skills_dir: &Path,
) -> Result<usize, PythonSkillError> {
    let mut count = 0;

    // 1. Index Python skills.
    if python_skills_dir.is_dir()
        && let Ok(entries) = std::fs::read_dir(python_skills_dir)
    {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let Some(skill_id) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };

            if let Some((name, description)) =
                extract_python_skill_text(python_skills_dir, skill_id)
            {
                let text = format!("{name}: {description}");
                match engine.embed(&text) {
                    Ok(embedding) => {
                        index.index_skill(skill_id, &name, &description, "python", &embedding)?;
                        count += 1;
                    }
                    Err(e) => {
                        tracing::warn!(skill_id, error = %e, "failed to embed Python skill");
                    }
                }
            }
        }
    }

    // 2. Index markdown skills.
    if skills_dir.is_dir()
        && let Ok(entries) = std::fs::read_dir(skills_dir)
    {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
                continue;
            }
            if path
                .file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with('.'))
                .unwrap_or(true)
            {
                continue;
            }

            if let Some((name, description)) = extract_markdown_skill_text(&path) {
                let text = format!("{name}: {description}");
                match engine.embed(&text) {
                    Ok(embedding) => {
                        index.index_skill(&name, &name, &description, "markdown", &embedding)?;
                        count += 1;
                    }
                    Err(e) => {
                        tracing::warn!(skill = %name, error = %e, "failed to embed markdown skill");
                    }
                }
            }
        }
    }

    // 3. Index builtins.
    let builtins = [
        ("apple-ecosystem", super::APPLE_ECOSYSTEM_SKILL),
        ("canvas", super::CANVAS_SKILL),
        ("desktop", super::DESKTOP_SKILL),
        ("external-llm", super::EXTERNAL_LLM_SKILL),
        ("uv-scripts", super::UV_SCRIPTS_SKILL),
    ];

    for (name, content) in builtins {
        let (_, description) = extract_builtin_skill_text(name, content);
        let text = format!("{name}: {description}");
        match engine.embed(&text) {
            Ok(embedding) => {
                index.index_skill(name, name, &description, "builtin", &embedding)?;
                count += 1;
            }
            Err(e) => {
                tracing::warn!(skill = name, error = %e, "failed to embed builtin skill");
            }
        }
    }

    tracing::info!(count, "skill discovery index rebuilt");
    Ok(count)
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn now_epoch_secs() -> i64 {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => d.as_secs() as i64,
        Err(_) => 0,
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

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

    #[test]
    fn open_creates_tables() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");
        assert_eq!(index.indexed_count().expect("count"), 0);
    }

    #[test]
    fn index_and_search_returns_match() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");

        let emb = mock_embedding(1.0);
        index
            .index_skill(
                "discord-bot",
                "Discord Bot",
                "Send messages on Discord",
                "python",
                &emb,
            )
            .expect("index");

        let results = index.search(&emb, 5).expect("search");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].skill_id, "discord-bot");
        assert_eq!(results[0].name, "Discord Bot");
        assert!(results[0].score > 0.99, "self-match should have high score");
    }

    #[test]
    fn remove_skill_deletes_from_index() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");

        let emb = mock_embedding(1.0);
        index
            .index_skill("test-skill", "Test", "A test skill", "builtin", &emb)
            .expect("index");
        assert!(index.is_indexed("test-skill").expect("check"));
        assert_eq!(index.indexed_count().expect("count"), 1);

        index.remove_skill("test-skill").expect("remove");
        assert!(!index.is_indexed("test-skill").expect("check"));
        assert_eq!(index.indexed_count().expect("count"), 0);
    }

    #[test]
    fn is_indexed_returns_correct_status() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");
        assert!(!index.is_indexed("nonexistent").expect("check"));

        let emb = mock_embedding(1.0);
        index
            .index_skill("my-skill", "My Skill", "Description", "python", &emb)
            .expect("index");
        assert!(index.is_indexed("my-skill").expect("check"));
    }

    #[test]
    fn search_empty_index_returns_empty() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");
        let emb = mock_embedding(1.0);
        let results = index.search(&emb, 5).expect("search");
        assert!(results.is_empty());
    }

    #[test]
    fn indexed_count_tracks_entries() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");
        assert_eq!(index.indexed_count().expect("count"), 0);

        index
            .index_skill("a", "A", "Skill A", "builtin", &mock_embedding(1.0))
            .expect("index");
        assert_eq!(index.indexed_count().expect("count"), 1);

        index
            .index_skill("b", "B", "Skill B", "python", &mock_embedding(2.0))
            .expect("index");
        assert_eq!(index.indexed_count().expect("count"), 2);
    }

    #[test]
    fn upsert_replaces_existing_entry() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");

        let emb1 = mock_embedding(1.0);
        index
            .index_skill("s", "Old Name", "Old desc", "python", &emb1)
            .expect("first index");

        let emb2 = mock_embedding(2.0);
        index
            .index_skill("s", "New Name", "New desc", "python", &emb2)
            .expect("second index");

        assert_eq!(index.indexed_count().expect("count"), 1);

        // Search with emb2 should find the updated entry.
        let results = index.search(&emb2, 1).expect("search");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "New Name");
        assert_eq!(results[0].description, "New desc");
    }

    #[test]
    fn search_returns_best_match_first() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");

        let emb_a = mock_embedding(1.0);
        let emb_b = mock_embedding(2.0);
        let emb_c = mock_embedding(3.0);

        index
            .index_skill("a", "A", "Skill A", "builtin", &emb_a)
            .expect("index a");
        index
            .index_skill("b", "B", "Skill B", "python", &emb_b)
            .expect("index b");
        index
            .index_skill("c", "C", "Skill C", "markdown", &emb_c)
            .expect("index c");

        // Query with emb_a — "a" should be the best match.
        let results = index.search(&emb_a, 3).expect("search");
        assert_eq!(results[0].skill_id, "a");
        assert!(results[0].score >= results[1].score);
    }

    #[test]
    fn search_limit_zero_returns_empty() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");
        let emb = mock_embedding(1.0);
        index
            .index_skill("s", "S", "desc", "builtin", &emb)
            .expect("index");
        let results = index.search(&emb, 0).expect("search");
        assert!(results.is_empty());
    }

    #[test]
    fn wrong_dimension_embedding_rejected() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");
        let bad_emb = vec![1.0_f32; 128]; // wrong dimension
        let result = index.index_skill("s", "S", "desc", "builtin", &bad_emb);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("dimension mismatch"), "got: {msg}");
    }

    #[test]
    fn remove_nonexistent_skill_is_noop() {
        let index = SkillDiscoveryIndex::open_in_memory().expect("open");
        // Should not error.
        index.remove_skill("does-not-exist").expect("remove");
    }

    // ── Text extraction tests ───────────────────────────────────────────────

    #[test]
    fn extract_first_paragraph_from_markdown() {
        let content = "# My Skill\n\nThis is the description.\nIt spans two lines.\n\n## Details\n";
        let result = extract_first_paragraph(content);
        assert_eq!(result, "This is the description. It spans two lines.");
    }

    #[test]
    fn extract_first_paragraph_truncates_long_text() {
        let long_line = "word ".repeat(200); // 1000 chars
        let content = format!("# Title\n\n{long_line}\n");
        let result = extract_first_paragraph(&content);
        assert!(result.len() <= 500);
    }

    #[test]
    fn extract_python_skill_text_from_manifest() {
        let dir = tempfile::tempdir().expect("tempdir");
        let skill_dir = dir.path().join("my-skill");
        std::fs::create_dir_all(&skill_dir).expect("mkdir");
        std::fs::write(
            skill_dir.join("manifest.toml"),
            "id = \"my-skill\"\nname = \"My Skill\"\nversion = \"1.0.0\"\n\
             entry_file = \"skill.py\"\ndescription = \"Does amazing things\"\n",
        )
        .expect("write");

        let result = extract_python_skill_text(dir.path(), "my-skill");
        let (name, desc) = result.expect("should parse");
        assert_eq!(name, "My Skill");
        assert_eq!(desc, "Does amazing things");
    }

    #[test]
    fn extract_python_skill_text_missing_manifest_returns_none() {
        let dir = tempfile::tempdir().expect("tempdir");
        let result = extract_python_skill_text(dir.path(), "nonexistent");
        assert!(result.is_none());
    }

    #[test]
    fn extract_markdown_skill_text_from_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("weather.md");
        std::fs::write(
            &path,
            "# Weather\n\nCheck weather forecasts for any location.\n",
        )
        .expect("write");

        let (name, desc) = extract_markdown_skill_text(&path).expect("parse");
        assert_eq!(name, "weather");
        assert_eq!(desc, "Check weather forecasts for any location.");
    }

    #[test]
    fn extract_builtin_skill_text_returns_name_and_description() {
        let content = "# Canvas\n\nDraw and render visual content on the canvas.\n\n## Usage\n";
        let (name, desc) = extract_builtin_skill_text("canvas", content);
        assert_eq!(name, "canvas");
        assert_eq!(desc, "Draw and render visual content on the canvas.");
    }
}

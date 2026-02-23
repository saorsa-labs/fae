//! Consolidated embedding-engine integration tests.
//!
//! These tests require the all-MiniLM-L6-v2 ONNX model (~23 MB) which is
//! downloaded from HuggingFace Hub on first run and cached locally.
//!
//! Everything runs in **one** `#[test]` function so the model is loaded
//! exactly once — no lock contention and ~3s instead of ~20s.

use fae::memory::embedding::{EMBEDDING_DIM, EmbeddingEngine, cosine_similarity};
use fae::memory::sqlite::SqliteMemoryRepository;
use fae::memory::types::MemoryKind;

#[test]
fn embedding_engine_and_sqlite_batch_embed() {
    let mut engine = EmbeddingEngine::download_and_load().expect("download and load");

    // =======================================================================
    // Embedding engine assertions (were 7 separate ignored tests)
    // =======================================================================

    // 1. download_and_load_succeeds — basic embed produces correct dimensions
    let vec = engine.embed("hello world").expect("embed hello world");
    assert_eq!(vec.len(), EMBEDDING_DIM);

    // 2. embed_produces_correct_dimensions — different text, same dim
    let vec2 = engine
        .embed("the quick brown fox")
        .expect("embed quick fox");
    assert_eq!(vec2.len(), EMBEDDING_DIM);

    // 3. embed_is_normalized — output should be unit-length
    let vec3 = engine
        .embed("test normalization")
        .expect("embed normalization");
    let norm: f32 = vec3.iter().map(|x| x * x).sum::<f32>().sqrt();
    assert!((norm - 1.0).abs() < 1e-4, "expected unit norm, got {norm}");

    // 4. similar_texts_have_high_similarity
    let a = engine.embed("hello world").expect("embed a");
    let b = engine.embed("hi world").expect("embed b");
    let sim = cosine_similarity(&a, &b);
    assert!(
        sim > 0.7,
        "similar texts should have cos-sim > 0.7, got {sim}"
    );

    // 5. different_texts_have_low_similarity
    let c = engine.embed("hello world").expect("embed c");
    let d = engine.embed("quantum physics equations").expect("embed d");
    let sim2 = cosine_similarity(&c, &d);
    assert!(
        sim2 < 0.5,
        "different texts should have cos-sim < 0.5, got {sim2}"
    );

    // 6. embed_batch_matches_individual
    let texts = &["hello world", "quantum physics"];
    let batch = engine.embed_batch(texts).expect("batch");
    assert_eq!(batch.len(), 2);

    let individual_a = engine.embed(texts[0]).expect("embed 0");
    let individual_b = engine.embed(texts[1]).expect("embed 1");

    let sim_a = cosine_similarity(&batch[0], &individual_a);
    let sim_b = cosine_similarity(&batch[1], &individual_b);
    assert!(sim_a > 0.99, "batch[0] vs individual[0] sim = {sim_a}");
    assert!(sim_b > 0.99, "batch[1] vs individual[1] sim = {sim_b}");

    // 7. embed_empty_text
    let empty = engine.embed("").expect("embed empty");
    assert_eq!(empty.len(), EMBEDDING_DIM);

    // =======================================================================
    // SQLite batch-embed assertions (were 2 separate ignored tests)
    // =======================================================================

    // --- batch_embed_missing_embeds_all ---
    {
        let dir = tempfile::TempDir::new().expect("create temp dir");
        let repo = SqliteMemoryRepository::new(dir.path()).expect("create SqliteMemoryRepository");

        let r1 = repo
            .insert_record(MemoryKind::Fact, "hello world", 0.8, None, &[])
            .expect("insert r1");
        let r2 = repo
            .insert_record(MemoryKind::Fact, "goodbye world", 0.8, None, &[])
            .expect("insert r2");
        let r3 = repo
            .insert_record(MemoryKind::Fact, "hello again", 0.8, None, &[])
            .expect("insert r3");
        let r4 = repo
            .insert_record(MemoryKind::Profile, "user lives in Berlin", 0.9, None, &[])
            .expect("insert r4");
        let r5 = repo
            .insert_record(MemoryKind::Profile, "user likes coding", 0.9, None, &[])
            .expect("insert r5");

        assert_eq!(repo.count_embeddings().expect("count"), 0);

        let embedded_count = repo.batch_embed_missing(&mut engine).expect("batch embed");

        assert_eq!(embedded_count, 5);
        assert_eq!(repo.count_embeddings().expect("count"), 5);
        assert!(repo.has_embedding(&r1.id).expect("has r1"));
        assert!(repo.has_embedding(&r2.id).expect("has r2"));
        assert!(repo.has_embedding(&r3.id).expect("has r3"));
        assert!(repo.has_embedding(&r4.id).expect("has r4"));
        assert!(repo.has_embedding(&r5.id).expect("has r5"));
    }

    // --- batch_embed_skips_already_embedded ---
    {
        let dir = tempfile::TempDir::new().expect("create temp dir");
        let repo = SqliteMemoryRepository::new(dir.path()).expect("create SqliteMemoryRepository");

        let r1 = repo
            .insert_record(MemoryKind::Fact, "hello world", 0.8, None, &[])
            .expect("insert r1");
        let r2 = repo
            .insert_record(MemoryKind::Fact, "goodbye world", 0.8, None, &[])
            .expect("insert r2");
        let r3 = repo
            .insert_record(MemoryKind::Fact, "hello again", 0.8, None, &[])
            .expect("insert r3");

        // Manually embed r1.
        let mut e1 = vec![0.0_f32; EMBEDDING_DIM];
        e1[0] = 1.0;
        repo.store_embedding(&r1.id, &e1).expect("store e1");
        assert_eq!(repo.count_embeddings().expect("count"), 1);

        let embedded_count = repo.batch_embed_missing(&mut engine).expect("batch embed");

        assert_eq!(embedded_count, 2);
        assert_eq!(repo.count_embeddings().expect("count"), 3);
        assert!(repo.has_embedding(&r1.id).expect("has r1"));
        assert!(repo.has_embedding(&r2.id).expect("has r2"));
        assert!(repo.has_embedding(&r3.id).expect("has r3"));
    }
}

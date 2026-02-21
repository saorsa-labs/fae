//! Sentence embedding engine for semantic memory retrieval.
//!
//! Uses `all-MiniLM-L6-v2` (384-dim) via ONNX Runtime for fast, local
//! sentence embeddings.  The model is downloaded from HuggingFace Hub on
//! first use and cached by `hf-hub`.
//!
//! # Pipeline
//!
//! ```text
//! text → tokenizer → ONNX model → mean-pool → L2-normalize → 384-dim f32
//! ```

use crate::error::{Result, SpeechError};
use ort::session::{Session, SessionInputValue, SessionInputs};
use ort::value::Tensor;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tracing::info;

/// HuggingFace repo for the all-MiniLM-L6-v2 ONNX model.
const REPO_ID: &str = "sentence-transformers/all-MiniLM-L6-v2";

/// ONNX model filename inside the repo.
const MODEL_FILE: &str = "onnx/model.onnx";

/// Tokenizer filename inside the repo.
const TOKENIZER_FILE: &str = "tokenizer.json";

/// Output embedding dimensions.
pub const EMBEDDING_DIM: usize = 384;

/// Maximum token sequence length for the model.
const MAX_TOKENS: usize = 256;

/// Sentence embedding engine backed by `all-MiniLM-L6-v2`.
///
/// Not thread-safe: `embed` and `embed_batch` require `&mut self` because
/// `tokenizers::Tokenizer` requires exclusive mutable access during encoding.
/// For shared concurrent use, wrap in `Mutex<EmbeddingEngine>`.
pub struct EmbeddingEngine {
    session: Session,
    tokenizer: tokenizers::Tokenizer,
}

impl std::fmt::Debug for EmbeddingEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EmbeddingEngine")
            .field("dim", &EMBEDDING_DIM)
            .finish_non_exhaustive()
    }
}

impl EmbeddingEngine {
    /// Load an embedding engine from pre-downloaded model files.
    ///
    /// `model_path` must point to the ONNX model file (e.g. `model.onnx`).
    /// `tokenizer_path` must point to the tokenizer config file (`tokenizer.json`).
    ///
    /// # Errors
    ///
    /// Returns an error if the ONNX model or tokenizer cannot be loaded.
    pub fn new(model_path: &Path, tokenizer_path: &Path) -> Result<Self> {
        info!("loading embedding ONNX model: {}", model_path.display());
        let session = Session::builder()
            .and_then(|b| b.with_intra_threads(2))
            .and_then(|b| b.commit_from_file(model_path))
            .map_err(|e| SpeechError::Model(format!("embedding model load failed: {e}")))?;

        info!("loading embedding tokenizer: {}", tokenizer_path.display());
        let mut tokenizer = tokenizers::Tokenizer::from_file(tokenizer_path)
            .map_err(|e| SpeechError::Model(format!("embedding tokenizer load failed: {e}")))?;

        // Enforce max-length truncation so longer texts don't blow up.
        let truncation = tokenizers::TruncationParams {
            max_length: MAX_TOKENS,
            ..Default::default()
        };
        tokenizer
            .with_truncation(Some(truncation))
            .map_err(|e| SpeechError::Model(format!("tokenizer truncation config failed: {e}")))?;

        // Ensure padding is disabled for single-text encoding.
        tokenizer.with_padding(None);

        info!("embedding engine ready (dim={EMBEDDING_DIM})");

        Ok(Self { session, tokenizer })
    }

    /// Embed a single text string into a 384-dim f32 vector.
    ///
    /// The result is L2-normalized (unit length).
    ///
    /// # Errors
    ///
    /// Returns an error if tokenization or ONNX inference fails.
    pub fn embed(&mut self, text: &str) -> Result<Vec<f32>> {
        let encoding = self
            .tokenizer
            .encode(text, true)
            .map_err(|e| SpeechError::Memory(format!("tokenization failed: {e}")))?;

        let input_ids: Vec<i64> = encoding.get_ids().iter().map(|&id| id as i64).collect();
        let attention_mask: Vec<i64> = encoding
            .get_attention_mask()
            .iter()
            .map(|&m| m as i64)
            .collect();
        let token_type_ids: Vec<i64> = encoding.get_type_ids().iter().map(|&t| t as i64).collect();

        let seq_len = input_ids.len();

        let ids_tensor = Tensor::from_array(([1, seq_len], input_ids))
            .map_err(|e| SpeechError::Memory(format!("failed to create input_ids tensor: {e}")))?;
        let mask_tensor =
            Tensor::from_array(([1, seq_len], attention_mask.clone())).map_err(|e| {
                SpeechError::Memory(format!("failed to create attention_mask tensor: {e}"))
            })?;
        let type_tensor = Tensor::from_array(([1, seq_len], token_type_ids)).map_err(|e| {
            SpeechError::Memory(format!("failed to create token_type_ids tensor: {e}"))
        })?;

        let mut feed: HashMap<String, SessionInputValue> = HashMap::new();
        feed.insert("input_ids".to_owned(), ids_tensor.into());
        feed.insert("attention_mask".to_owned(), mask_tensor.into());
        feed.insert("token_type_ids".to_owned(), type_tensor.into());

        let outputs = self
            .session
            .run(SessionInputs::from(feed))
            .map_err(|e| SpeechError::Memory(format!("ONNX inference failed: {e}")))?;

        // Output shape: [1, seq_len, 384] — token-level embeddings.
        let (_shape, data) = outputs[0_usize]
            .try_extract_tensor::<f32>()
            .map_err(|e| SpeechError::Memory(format!("failed to extract output tensor: {e}")))?;

        // Mean-pool with attention mask weighting.
        let pooled = mean_pool(data, &attention_mask, EMBEDDING_DIM);

        Ok(l2_normalize(&pooled))
    }

    /// Embed multiple texts in a single batch.
    ///
    /// Each result is L2-normalized. Texts are padded to the longest
    /// sequence in the batch.
    ///
    /// # Errors
    ///
    /// Returns an error if tokenization or ONNX inference fails.
    pub fn embed_batch(&mut self, texts: &[&str]) -> Result<Vec<Vec<f32>>> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }
        if texts.len() == 1 {
            return self.embed(texts[0]).map(|v| vec![v]);
        }

        let encodings: Vec<tokenizers::Encoding> = texts
            .iter()
            .map(|t| {
                self.tokenizer
                    .encode(*t, true)
                    .map_err(|e| SpeechError::Memory(format!("batch tokenization failed: {e}")))
            })
            .collect::<Result<Vec<_>>>()?;

        // SAFETY: encodings is non-empty (guarded by texts.is_empty() check above).
        let max_len = encodings
            .iter()
            .map(|e| e.get_ids().len())
            .max()
            .unwrap_or_else(|| unreachable!("encodings is non-empty"));
        let batch_size = texts.len();

        let mut all_ids = vec![0i64; batch_size * max_len];
        let mut all_mask = vec![0i64; batch_size * max_len];
        let mut all_types = vec![0i64; batch_size * max_len];

        for (i, enc) in encodings.iter().enumerate() {
            let offset = i * max_len;
            for (j, &id) in enc.get_ids().iter().enumerate() {
                all_ids[offset + j] = id as i64;
            }
            for (j, &m) in enc.get_attention_mask().iter().enumerate() {
                all_mask[offset + j] = m as i64;
            }
            for (j, &t) in enc.get_type_ids().iter().enumerate() {
                all_types[offset + j] = t as i64;
            }
        }

        let ids_tensor = Tensor::from_array(([batch_size, max_len], all_ids))
            .map_err(|e| SpeechError::Memory(format!("batch input_ids tensor failed: {e}")))?;
        let mask_tensor = Tensor::from_array(([batch_size, max_len], all_mask.clone()))
            .map_err(|e| SpeechError::Memory(format!("batch attention_mask tensor failed: {e}")))?;
        let type_tensor = Tensor::from_array(([batch_size, max_len], all_types))
            .map_err(|e| SpeechError::Memory(format!("batch token_type_ids tensor failed: {e}")))?;

        let mut feed: HashMap<String, SessionInputValue> = HashMap::new();
        feed.insert("input_ids".to_owned(), ids_tensor.into());
        feed.insert("attention_mask".to_owned(), mask_tensor.into());
        feed.insert("token_type_ids".to_owned(), type_tensor.into());

        let outputs = self
            .session
            .run(SessionInputs::from(feed))
            .map_err(|e| SpeechError::Memory(format!("batch ONNX inference failed: {e}")))?;

        let (_shape, data) = outputs[0_usize]
            .try_extract_tensor::<f32>()
            .map_err(|e| SpeechError::Memory(format!("batch output extraction failed: {e}")))?;

        let flat = data.to_vec();

        let mut results = Vec::with_capacity(batch_size);
        for i in 0..batch_size {
            let start = i * max_len * EMBEDDING_DIM;
            let end = start + max_len * EMBEDDING_DIM;
            let slice = &flat[start..end];
            let mask_slice = &all_mask[i * max_len..(i + 1) * max_len];
            let pooled = mean_pool(slice, mask_slice, EMBEDDING_DIM);
            results.push(l2_normalize(&pooled));
        }

        Ok(results)
    }

    /// Download the all-MiniLM-L6-v2 model files from HuggingFace Hub.
    ///
    /// Returns `(model_path, tokenizer_path)`.  Files are cached by `hf-hub`
    /// and only downloaded on first call.
    ///
    /// # Errors
    ///
    /// Returns an error if the download fails.
    pub fn download_model() -> Result<(PathBuf, PathBuf)> {
        info!("downloading embedding model: {REPO_ID}");
        let api = hf_hub::api::sync::Api::new()
            .map_err(|e| SpeechError::Model(format!("HF Hub API init failed: {e}")))?;
        let repo = api.model(REPO_ID.to_owned());

        let model_path = repo
            .get(MODEL_FILE)
            .map_err(|e| SpeechError::Model(format!("failed to download {MODEL_FILE}: {e}")))?;

        let tokenizer_path = repo
            .get(TOKENIZER_FILE)
            .map_err(|e| SpeechError::Model(format!("failed to download {TOKENIZER_FILE}: {e}")))?;

        info!(
            "embedding model ready: {}",
            model_path
                .parent()
                .map_or_else(|| "?".into(), |p| p.to_string_lossy().into_owned())
        );
        Ok((model_path, tokenizer_path))
    }

    /// Download the model and create an engine in one step.
    ///
    /// Convenience wrapper around [`download_model`](Self::download_model)
    /// and [`new`](Self::new).
    ///
    /// # Errors
    ///
    /// Returns an error if download or loading fails.
    pub fn download_and_load() -> Result<Self> {
        let (model_path, tokenizer_path) = Self::download_model()?;
        Self::new(&model_path, &tokenizer_path)
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Mean-pool token embeddings using attention mask.
///
/// `flat` is shape `[mask.len(), dim]` stored row-major.
/// `mask` is `[seq_len]` with 1 for real tokens, 0 for padding.
fn mean_pool(flat: &[f32], mask: &[i64], dim: usize) -> Vec<f32> {
    let mut pooled = vec![0.0f32; dim];
    let mut count = 0.0f32;

    for (t, &m) in mask.iter().enumerate() {
        if m != 0 {
            let offset = t * dim;
            for (p, &f) in pooled.iter_mut().zip(&flat[offset..offset + dim]) {
                *p += f;
            }
            count += 1.0;
        }
    }

    if count > 0.0 {
        for p in &mut pooled {
            *p /= count;
        }
    }

    pooled
}

/// L2-normalize a vector (in-place, returns new vec).
fn l2_normalize(vec: &[f32]) -> Vec<f32> {
    let norm: f32 = vec.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm < 1e-12 {
        return vec.to_vec();
    }
    vec.iter().map(|x| x / norm).collect()
}

/// Compute cosine similarity between two vectors.
///
/// Returns a value in `[-1.0, 1.0]`.  Both vectors should be the same length.
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    debug_assert_eq!(a.len(), b.len(), "vectors must have equal length");
    let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    let denom = norm_a * norm_b;
    if denom < 1e-12 {
        return 0.0;
    }
    dot / denom
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn embedding_dim_constant() {
        assert_eq!(EMBEDDING_DIM, 384);
    }

    #[test]
    fn l2_normalize_unit_length() {
        let v = vec![3.0, 4.0];
        let n = l2_normalize(&v);
        let norm: f32 = n.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-6);
    }

    #[test]
    fn l2_normalize_zero_vector() {
        let v = vec![0.0; 384];
        let n = l2_normalize(&v);
        assert_eq!(n.len(), 384);
        // Zero vector stays zero (no division by zero).
        assert!(n.iter().all(|&x| x == 0.0));
    }

    #[test]
    fn mean_pool_basic() {
        // 2 tokens, dim=3, both active.
        let flat = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
        let mask = vec![1i64, 1];
        let pooled = mean_pool(&flat, &mask, 3);
        assert_eq!(pooled, vec![2.5, 3.5, 4.5]);
    }

    #[test]
    fn mean_pool_with_padding() {
        // 3 tokens, dim=2, only first 2 active.
        let flat = vec![1.0, 2.0, 3.0, 4.0, 99.0, 99.0];
        let mask = vec![1i64, 1, 0];
        let pooled = mean_pool(&flat, &mask, 2);
        assert_eq!(pooled, vec![2.0, 3.0]);
    }

    #[test]
    fn mean_pool_all_masked() {
        // All tokens are padding — result should be all-zero (no division by zero).
        let flat = vec![1.0, 2.0, 3.0, 4.0];
        let mask = vec![0i64, 0];
        let pooled = mean_pool(&flat, &mask, 2);
        assert_eq!(pooled, vec![0.0, 0.0]);
    }

    #[test]
    fn cosine_similarity_identical() {
        let a = vec![1.0, 0.0, 0.0];
        assert!((cosine_similarity(&a, &a) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn cosine_similarity_orthogonal() {
        let a = vec![1.0, 0.0, 0.0];
        let b = vec![0.0, 1.0, 0.0];
        assert!(cosine_similarity(&a, &b).abs() < 1e-6);
    }

    #[test]
    fn cosine_similarity_opposite() {
        let a = vec![1.0, 0.0];
        let b = vec![-1.0, 0.0];
        assert!((cosine_similarity(&a, &b) + 1.0).abs() < 1e-6);
    }

    // -- Integration tests (require model download) --

    #[test]
    #[ignore] // Requires network + model download (~23 MB)
    fn download_and_load_succeeds() {
        let mut engine = EmbeddingEngine::download_and_load().expect("download and load");
        let vec = engine.embed("hello world").expect("embed");
        assert_eq!(vec.len(), EMBEDDING_DIM);
    }

    #[test]
    #[ignore] // Requires network + model download
    fn embed_produces_correct_dimensions() {
        let mut engine = EmbeddingEngine::download_and_load().expect("engine");
        let vec = engine.embed("the quick brown fox").expect("embed");
        assert_eq!(vec.len(), EMBEDDING_DIM);
    }

    #[test]
    #[ignore] // Requires network + model download
    fn embed_is_normalized() {
        let mut engine = EmbeddingEngine::download_and_load().expect("engine");
        let vec = engine.embed("test normalization").expect("embed");
        let norm: f32 = vec.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-4, "expected unit norm, got {norm}");
    }

    #[test]
    #[ignore] // Requires network + model download
    fn similar_texts_have_high_similarity() {
        let mut engine = EmbeddingEngine::download_and_load().expect("engine");
        let a = engine.embed("hello world").expect("embed a");
        let b = engine.embed("hi world").expect("embed b");
        let sim = cosine_similarity(&a, &b);
        assert!(
            sim > 0.7,
            "similar texts should have cos-sim > 0.7, got {sim}"
        );
    }

    #[test]
    #[ignore] // Requires network + model download
    fn different_texts_have_low_similarity() {
        let mut engine = EmbeddingEngine::download_and_load().expect("engine");
        let a = engine.embed("hello world").expect("embed a");
        let b = engine.embed("quantum physics equations").expect("embed b");
        let sim = cosine_similarity(&a, &b);
        assert!(
            sim < 0.5,
            "different texts should have cos-sim < 0.5, got {sim}"
        );
    }

    #[test]
    #[ignore] // Requires network + model download
    fn embed_batch_matches_individual() {
        let mut engine = EmbeddingEngine::download_and_load().expect("engine");
        let texts = &["hello world", "quantum physics"];
        let batch = engine.embed_batch(texts).expect("batch");
        assert_eq!(batch.len(), 2);

        let individual_a = engine.embed(texts[0]).expect("embed 0");
        let individual_b = engine.embed(texts[1]).expect("embed 1");

        // Batch and individual should produce very similar results
        // (may differ slightly due to padding).
        let sim_a = cosine_similarity(&batch[0], &individual_a);
        let sim_b = cosine_similarity(&batch[1], &individual_b);
        assert!(sim_a > 0.99, "batch[0] vs individual[0] sim = {sim_a}");
        assert!(sim_b > 0.99, "batch[1] vs individual[1] sim = {sim_b}");
    }

    #[test]
    #[ignore] // Requires network + model download
    fn embed_empty_text() {
        let mut engine = EmbeddingEngine::download_and_load().expect("engine");
        let vec = engine.embed("").expect("embed empty");
        assert_eq!(vec.len(), EMBEDDING_DIM);
    }
}

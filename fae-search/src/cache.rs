//! In-memory LRU cache for search results.
//!
//! Caches the final deduplicated, scored, sorted results keyed by
//! the (lowercased query, sorted engine set) pair. Uses [`moka`] for
//! async-friendly caching with configurable TTL and automatic eviction.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::OnceLock;
use std::time::Duration;

use moka::future::Cache;

use crate::types::{SearchEngine, SearchResult};

/// Maximum number of cached search result sets.
const MAX_CACHE_ENTRIES: u64 = 100;

/// Global process-wide search cache.
///
/// Lazily initialised on first access. TTL is set when first created
/// and cannot be changed after initialisation.
static CACHE: OnceLock<Cache<CacheKey, Vec<SearchResult>>> = OnceLock::new();

/// Composite cache key: normalised query + engine set hash.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CacheKey {
    /// Lowercased, trimmed query string.
    query: String,
    /// Hash of the sorted engine set, so different engine configs
    /// produce different cache entries.
    engine_hash: u64,
}

impl CacheKey {
    /// Build a deterministic cache key from a query and engine list.
    ///
    /// The query is lowercased and trimmed. The engine list is sorted
    /// and hashed so that `[Google, Bing]` and `[Bing, Google]` produce
    /// the same key.
    pub fn new(query: &str, engines: &[SearchEngine]) -> Self {
        let normalised_query = query.trim().to_lowercase();
        let engine_hash = hash_engines(engines);
        Self {
            query: normalised_query,
            engine_hash,
        }
    }
}

/// Get or initialise the global cache with the given TTL.
///
/// The TTL is only used on the **first** call; subsequent calls reuse
/// the existing cache regardless of the TTL argument.
fn get_or_init_cache(ttl_seconds: u64) -> &'static Cache<CacheKey, Vec<SearchResult>> {
    CACHE.get_or_init(|| {
        Cache::builder()
            .max_capacity(MAX_CACHE_ENTRIES)
            .time_to_live(Duration::from_secs(ttl_seconds))
            .build()
    })
}

/// Look up cached results for the given key.
///
/// Returns `Some(results)` on cache hit, `None` on miss.
pub async fn get(key: &CacheKey, ttl_seconds: u64) -> Option<Vec<SearchResult>> {
    let cache = get_or_init_cache(ttl_seconds);
    cache.get(key).await
}

/// Insert search results into the cache.
pub async fn insert(key: CacheKey, results: Vec<SearchResult>, ttl_seconds: u64) {
    let cache = get_or_init_cache(ttl_seconds);
    cache.insert(key, results).await;
}

/// Compute a deterministic hash of a set of search engines.
///
/// The engine list is sorted before hashing so that order does not
/// affect the result.
fn hash_engines(engines: &[SearchEngine]) -> u64 {
    let mut sorted: Vec<&SearchEngine> = engines.iter().collect();
    sorted.sort_by_key(|e| e.name());
    let mut hasher = DefaultHasher::new();
    for engine in sorted {
        engine.name().hash(&mut hasher);
    }
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_key_deterministic_for_same_inputs() {
        let key1 = CacheKey::new(
            "rust programming",
            &[SearchEngine::Google, SearchEngine::Bing],
        );
        let key2 = CacheKey::new(
            "rust programming",
            &[SearchEngine::Google, SearchEngine::Bing],
        );
        assert_eq!(key1, key2);
    }

    #[test]
    fn cache_key_differs_when_query_differs() {
        let key1 = CacheKey::new("rust", &[SearchEngine::Google]);
        let key2 = CacheKey::new("python", &[SearchEngine::Google]);
        assert_ne!(key1, key2);
    }

    #[test]
    fn cache_key_differs_when_engine_set_differs() {
        let key1 = CacheKey::new("test", &[SearchEngine::Google]);
        let key2 = CacheKey::new("test", &[SearchEngine::Bing]);
        assert_ne!(key1, key2);
    }

    #[test]
    fn cache_key_same_for_reordered_engines() {
        let key1 = CacheKey::new("test", &[SearchEngine::Google, SearchEngine::Bing]);
        let key2 = CacheKey::new("test", &[SearchEngine::Bing, SearchEngine::Google]);
        assert_eq!(key1, key2);
    }

    #[test]
    fn cache_key_normalises_query_case() {
        let key1 = CacheKey::new("RUST Programming", &[SearchEngine::Google]);
        let key2 = CacheKey::new("rust programming", &[SearchEngine::Google]);
        assert_eq!(key1, key2);
    }

    #[test]
    fn cache_key_trims_whitespace() {
        let key1 = CacheKey::new("  rust  ", &[SearchEngine::Google]);
        let key2 = CacheKey::new("rust", &[SearchEngine::Google]);
        assert_eq!(key1, key2);
    }

    #[tokio::test]
    async fn cache_miss_returns_none() {
        let key = CacheKey::new("nonexistent_query_xyz123", &[SearchEngine::DuckDuckGo]);
        let result = get(&key, 600).await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn cache_insert_and_retrieve() {
        let key = CacheKey::new("cache_test_insert_retrieve", &[SearchEngine::Brave]);
        let results = vec![SearchResult {
            title: "Cached".into(),
            url: "https://cached.com".into(),
            snippet: "A cached result".into(),
            engine: "Brave".into(),
            score: 1.0,
        }];

        insert(key.clone(), results.clone(), 600).await;

        let cached = get(&key, 600).await;
        assert!(cached.is_some());
        let cached = cached.expect("should be cached");
        assert_eq!(cached.len(), 1);
        assert_eq!(cached[0].title, "Cached");
    }

    #[test]
    fn engine_hash_order_independent() {
        let hash1 = hash_engines(&[SearchEngine::Google, SearchEngine::Bing]);
        let hash2 = hash_engines(&[SearchEngine::Bing, SearchEngine::Google]);
        assert_eq!(hash1, hash2);
    }

    #[test]
    fn engine_hash_differs_for_different_sets() {
        let hash1 = hash_engines(&[SearchEngine::Google]);
        let hash2 = hash_engines(&[SearchEngine::Bing]);
        assert_ne!(hash1, hash2);
    }

    // ── Additional cache edge-case tests ─────────────────────────────────

    #[tokio::test]
    async fn multiple_queries_cached_independently() {
        let key_a = CacheKey::new("cache_test_independent_a", &[SearchEngine::Google]);
        let key_b = CacheKey::new("cache_test_independent_b", &[SearchEngine::Google]);

        let results_a = vec![SearchResult {
            title: "Result A".into(),
            url: "https://a.com".into(),
            snippet: "snippet a".into(),
            engine: "Google".into(),
            score: 1.0,
        }];
        let results_b = vec![SearchResult {
            title: "Result B".into(),
            url: "https://b.com".into(),
            snippet: "snippet b".into(),
            engine: "Google".into(),
            score: 2.0,
        }];

        insert(key_a.clone(), results_a, 600).await;
        insert(key_b.clone(), results_b, 600).await;

        let cached_a = get(&key_a, 600).await.expect("a should be cached");
        let cached_b = get(&key_b, 600).await.expect("b should be cached");

        assert_eq!(cached_a[0].title, "Result A");
        assert_eq!(cached_b[0].title, "Result B");
    }

    #[tokio::test]
    async fn overwrite_same_key_updates_value() {
        let key = CacheKey::new("cache_test_overwrite", &[SearchEngine::DuckDuckGo]);

        let old_results = vec![SearchResult {
            title: "Old".into(),
            url: "https://old.com".into(),
            snippet: "old".into(),
            engine: "DuckDuckGo".into(),
            score: 1.0,
        }];
        let new_results = vec![SearchResult {
            title: "New".into(),
            url: "https://new.com".into(),
            snippet: "new".into(),
            engine: "DuckDuckGo".into(),
            score: 2.0,
        }];

        insert(key.clone(), old_results, 600).await;
        insert(key.clone(), new_results, 600).await;

        let cached = get(&key, 600).await.expect("should be cached");
        assert_eq!(cached[0].title, "New");
    }

    #[test]
    fn cache_key_empty_query_normalised() {
        let key1 = CacheKey::new("", &[SearchEngine::Google]);
        let key2 = CacheKey::new("  ", &[SearchEngine::Google]);
        assert_eq!(key1, key2);
    }

    #[test]
    fn cache_key_all_engines_same_regardless_of_order() {
        let key1 = CacheKey::new(
            "test",
            &[
                SearchEngine::DuckDuckGo,
                SearchEngine::Brave,
                SearchEngine::Google,
                SearchEngine::Bing,
            ],
        );
        let key2 = CacheKey::new(
            "test",
            &[
                SearchEngine::Bing,
                SearchEngine::Google,
                SearchEngine::Brave,
                SearchEngine::DuckDuckGo,
            ],
        );
        assert_eq!(key1, key2);
    }

    #[test]
    fn engine_hash_single_engine_deterministic() {
        let hash1 = hash_engines(&[SearchEngine::DuckDuckGo]);
        let hash2 = hash_engines(&[SearchEngine::DuckDuckGo]);
        assert_eq!(hash1, hash2);
    }

    #[test]
    fn engine_hash_empty_list() {
        // Empty engine list should produce a deterministic hash.
        let hash1 = hash_engines(&[]);
        let hash2 = hash_engines(&[]);
        assert_eq!(hash1, hash2);
    }
}

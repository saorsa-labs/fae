//! Search orchestrator: concurrent queries, dedup, scoring, ranking.
//!
//! This module fans out search queries to multiple engines concurrently,
//! deduplicates results by normalised URL, applies weighted scoring with
//! cross-engine boosting, and returns a sorted, truncated result set.

pub mod dedup;
pub mod scoring;
pub mod url_normalize;

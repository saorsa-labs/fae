//! GitHub release checker for Fae and Pi updates.
//!
//! Queries the GitHub releases API to detect newer versions, compares using
//! semver, and caches ETags for efficient conditional requests.

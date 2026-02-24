//! Shared time utilities used across the crate.

/// Returns the current Unix timestamp in seconds, or 0 on clock error.
pub(crate) fn now_epoch_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

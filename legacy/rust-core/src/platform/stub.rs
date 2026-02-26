//! No-op bookmark manager for non-macOS platforms.

use std::path::{Path, PathBuf};

use super::BookmarkManager;

/// Stub bookmark manager that does nothing.
///
/// Used on platforms where security-scoped bookmarks are not needed
/// (Linux, Windows, etc.). All bookmark operations return errors;
/// access operations are no-ops.
pub struct StubBookmarkManager;

impl BookmarkManager for StubBookmarkManager {
    fn create_bookmark(&self, _path: &Path) -> anyhow::Result<Vec<u8>> {
        anyhow::bail!("security-scoped bookmarks are not supported on this platform")
    }

    fn restore_bookmark(&self, _data: &[u8]) -> anyhow::Result<(PathBuf, bool)> {
        anyhow::bail!("security-scoped bookmarks are not supported on this platform")
    }

    fn start_accessing(&self, _path: &Path) -> anyhow::Result<()> {
        Ok(()) // no-op on non-macOS
    }

    fn stop_accessing(&self, _path: &Path) {
        // no-op on non-macOS
    }
}

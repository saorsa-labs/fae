//! Platform-specific abstractions for macOS App Sandbox support.
//!
//! Provides a cross-platform [`BookmarkManager`] trait for security-scoped
//! bookmark operations. On macOS, this uses Cocoa APIs to create, restore,
//! and manage bookmark access. On other platforms, a no-op stub is used.

use std::path::{Path, PathBuf};

#[cfg(target_os = "macos")]
mod macos;
#[cfg(not(target_os = "macos"))]
mod stub;
// Re-export stub for tests on all platforms.
#[cfg(test)]
#[cfg(target_os = "macos")]
#[path = "stub.rs"]
mod stub;

/// Manages security-scoped bookmarks for persistent file access under App Sandbox.
///
/// On macOS, user-selected files (via file pickers) are only accessible for
/// the duration of the app session. To persist access across restarts,
/// security-scoped bookmarks must be created and restored.
pub trait BookmarkManager: Send + Sync {
    /// Create a security-scoped bookmark for the given path.
    ///
    /// Returns the opaque bookmark data that can be persisted and later
    /// restored with [`restore_bookmark`](BookmarkManager::restore_bookmark).
    fn create_bookmark(&self, path: &Path) -> anyhow::Result<Vec<u8>>;

    /// Restore a previously created bookmark from its serialized data.
    ///
    /// Returns the resolved path and whether the bookmark is stale
    /// (the file may have moved or been modified). Stale bookmarks
    /// should be recreated.
    fn restore_bookmark(&self, data: &[u8]) -> anyhow::Result<(PathBuf, bool)>;

    /// Begin accessing a security-scoped resource.
    ///
    /// Must be called before reading or writing a bookmarked file.
    /// Each call must be balanced by a call to [`stop_accessing`](BookmarkManager::stop_accessing).
    fn start_accessing(&self, path: &Path) -> anyhow::Result<()>;

    /// Stop accessing a security-scoped resource.
    ///
    /// Must be called when done with a bookmarked file to release
    /// the kernel resource.
    fn stop_accessing(&self, path: &Path);
}

/// Create the platform-appropriate bookmark manager.
///
/// Returns a macOS implementation on Apple platforms,
/// or a no-op stub on all other platforms.
pub fn create_manager() -> Box<dyn BookmarkManager> {
    #[cfg(target_os = "macos")]
    {
        Box::new(macos::MacOsBookmarkManager::new())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Box::new(stub::StubBookmarkManager)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_manager_returns_valid_instance() {
        let manager = create_manager();
        // On any platform, start/stop accessing a nonexistent path should not panic.
        manager.stop_accessing(Path::new("/nonexistent"));
    }

    #[test]
    fn stub_start_accessing_is_noop() {
        let stub = stub::StubBookmarkManager;
        // start_accessing should succeed (no-op) on stub
        let result = stub.start_accessing(Path::new("/tmp/test"));
        assert!(result.is_ok());
    }

    #[test]
    fn stub_stop_accessing_is_noop() {
        let stub = stub::StubBookmarkManager;
        // stop_accessing should not panic on stub
        stub.stop_accessing(Path::new("/tmp/test"));
    }

    #[test]
    fn stub_create_bookmark_returns_error() {
        let stub = stub::StubBookmarkManager;
        let result = stub.create_bookmark(Path::new("/tmp/test"));
        assert!(result.is_err());
    }

    #[test]
    fn stub_restore_bookmark_returns_error() {
        let stub = stub::StubBookmarkManager;
        let result = stub.restore_bookmark(&[1, 2, 3]);
        assert!(result.is_err());
    }
}

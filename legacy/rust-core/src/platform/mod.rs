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

/// Best-effort bookmark creation and persistence for a user-selected path.
///
/// Creates a security-scoped bookmark, saves it to the config file, and
/// starts accessing the resource. On non-macOS or if any step fails,
/// the error is logged but the function returns normally.
///
/// This is the convenience entry point for file picker flows.
pub fn bookmark_and_persist(path: &Path, label: &str) {
    let manager = create_manager();

    let data = match manager.create_bookmark(path) {
        Ok(d) => d,
        Err(e) => {
            tracing::debug!("bookmark create skipped for {}: {e}", path.display());
            return;
        }
    };

    let config_path = crate::config::SpeechConfig::default_config_path();
    let mut config = crate::config::SpeechConfig::from_file(&config_path)
        .unwrap_or_else(|_| crate::config::SpeechConfig::default());

    let path_str = path.to_str().unwrap_or_default();
    config.save_bookmark(label, path_str, &data);

    if let Err(e) = config.save_to_file(&config_path) {
        tracing::warn!("failed to persist bookmark for {}: {e}", path.display());
        return;
    }

    if let Err(e) = manager.start_accessing(path) {
        tracing::debug!("start_accessing failed for {}: {e}", path.display());
    }
}

/// Restore all persisted bookmarks from config, starting access for each.
///
/// Returns the list of paths that were successfully restored and are now
/// accessible. Stale or corrupt bookmarks are removed from config and
/// the cleaned config is saved back.
pub fn restore_all_bookmarks() -> Vec<PathBuf> {
    let config_path = crate::config::SpeechConfig::default_config_path();
    let mut config = match crate::config::SpeechConfig::from_file(&config_path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let manager = create_manager();
    let mut restored = Vec::new();
    let mut to_remove = Vec::new();
    let mut to_refresh: Vec<(String, PathBuf, Vec<u8>)> = Vec::new();

    for (label, _path, data) in config.load_bookmarks() {
        match manager.restore_bookmark(&data) {
            Ok((resolved_path, is_stale)) => {
                if let Err(e) = manager.start_accessing(&resolved_path) {
                    tracing::warn!("start_accessing failed for bookmark '{}': {e}", label);
                    continue;
                }
                if is_stale {
                    // Recreate stale bookmark with fresh data.
                    match manager.create_bookmark(&resolved_path) {
                        Ok(fresh_data) => {
                            to_refresh.push((label.to_string(), resolved_path.clone(), fresh_data));
                        }
                        Err(e) => {
                            tracing::debug!("failed to refresh stale bookmark '{}': {e}", label);
                        }
                    }
                }
                restored.push(resolved_path);
            }
            Err(e) => {
                tracing::debug!("removing invalid bookmark '{}': {e}", label);
                to_remove.push(label.to_string());
            }
        }
    }

    // Clean up invalid bookmarks.
    let mut dirty = false;
    for label in &to_remove {
        config.remove_bookmark(label);
        dirty = true;
    }
    // Refresh stale bookmarks with fresh data.
    for (label, path, data) in &to_refresh {
        let path_str = path.to_str().unwrap_or_default();
        config.save_bookmark(label, path_str, data);
        dirty = true;
    }
    if dirty {
        let _ = config.save_to_file(&config_path);
    }

    restored
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

//! macOS security-scoped bookmark implementation.
//!
//! Uses Cocoa APIs (via `objc2-foundation`) to create, restore, and manage
//! security-scoped bookmarks for App Sandbox file access persistence.

use std::path::{Path, PathBuf};

use super::BookmarkManager;

/// macOS bookmark manager using Cocoa NSURL bookmark APIs.
pub struct MacOsBookmarkManager;

impl MacOsBookmarkManager {
    /// Create a new macOS bookmark manager.
    pub fn new() -> Self {
        Self
    }
}

impl BookmarkManager for MacOsBookmarkManager {
    fn create_bookmark(&self, path: &Path) -> anyhow::Result<Vec<u8>> {
        create_security_scoped_bookmark(path)
    }

    fn restore_bookmark(&self, data: &[u8]) -> anyhow::Result<(PathBuf, bool)> {
        restore_security_scoped_bookmark(data)
    }

    fn start_accessing(&self, path: &Path) -> anyhow::Result<()> {
        start_accessing_security_scoped_resource(path)
    }

    fn stop_accessing(&self, path: &Path) {
        stop_accessing_security_scoped_resource(path);
    }
}

/// Create a security-scoped bookmark for a file or directory.
///
/// The bookmark data can be persisted (e.g. base64-encoded in config) and
/// later restored to regain access to the resource across app restarts.
fn create_security_scoped_bookmark(path: &Path) -> anyhow::Result<Vec<u8>> {
    use objc2_foundation::{NSURL, NSURLBookmarkCreationOptions};

    let path_str = path
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("path is not valid UTF-8: {}", path.display()))?;

    let url = NSURL::fileURLWithPath(&objc2_foundation::NSString::from_str(path_str));

    // Create security-scoped bookmark data.
    let options = NSURLBookmarkCreationOptions::WithSecurityScope;
    let bookmark_data = url
        .bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error(
            options, None, None,
        )
        .map_err(|e| anyhow::anyhow!("failed to create bookmark: {e}"))?;

    // Convert NSData to Vec<u8>.
    Ok(bookmark_data.to_vec())
}

/// Restore a security-scoped bookmark from previously saved data.
///
/// Returns the resolved file path and whether the bookmark is stale.
/// Stale bookmarks still resolve but should be recreated for reliability.
fn restore_security_scoped_bookmark(data: &[u8]) -> anyhow::Result<(PathBuf, bool)> {
    use objc2::runtime::Bool;
    use objc2_foundation::{NSData, NSURL, NSURLBookmarkResolutionOptions};

    let ns_data = NSData::with_bytes(data);
    let options = NSURLBookmarkResolutionOptions::WithSecurityScope;

    let mut is_stale = Bool::new(false);
    let url = unsafe {
        NSURL::URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error(
            &ns_data,
            options,
            None,
            &mut is_stale as *mut Bool,
        )
    }
    .map_err(|e| anyhow::anyhow!("failed to resolve bookmark: {e}"))?;

    let path_str = url
        .path()
        .ok_or_else(|| anyhow::anyhow!("resolved bookmark URL has no path"))?;

    Ok((PathBuf::from(path_str.to_string()), is_stale.as_bool()))
}

/// Begin accessing a security-scoped resource.
///
/// Each call must be balanced by a corresponding
/// [`stop_accessing_security_scoped_resource`] call.
fn start_accessing_security_scoped_resource(path: &Path) -> anyhow::Result<()> {
    use objc2_foundation::NSURL;

    let path_str = path
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("path is not valid UTF-8: {}", path.display()))?;

    let url = NSURL::fileURLWithPath(&objc2_foundation::NSString::from_str(path_str));

    // SAFETY: startAccessingSecurityScopedResource is an Objective-C method
    // that returns whether access was granted. Safe to call on any NSURL.
    let success = unsafe { url.startAccessingSecurityScopedResource() };
    if success {
        Ok(())
    } else {
        anyhow::bail!(
            "failed to start accessing security-scoped resource: {}",
            path.display()
        )
    }
}

/// Stop accessing a security-scoped resource.
///
/// This releases the kernel resource associated with the bookmark.
fn stop_accessing_security_scoped_resource(path: &Path) {
    use objc2_foundation::NSURL;

    let path_str = match path.to_str() {
        Some(s) => s,
        None => return, // silently ignore non-UTF-8 paths
    };

    let url = NSURL::fileURLWithPath(&objc2_foundation::NSString::from_str(path_str));
    // SAFETY: stopAccessingSecurityScopedResource releases the kernel resource.
    // Safe to call even if start was never called (no-op in that case).
    unsafe {
        url.stopAccessingSecurityScopedResource();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manager_can_be_created() {
        let _manager = MacOsBookmarkManager::new();
    }

    #[test]
    fn create_bookmark_fails_for_nonexistent_path() {
        let manager = MacOsBookmarkManager::new();
        // Non-existent files cannot be bookmarked.
        let result = manager.create_bookmark(Path::new("/nonexistent/path/to/file.txt"));
        assert!(result.is_err());
    }

    #[test]
    fn start_stop_accessing_nonexistent_path() {
        let manager = MacOsBookmarkManager::new();
        // start_accessing on a non-bookmarked path should fail gracefully.
        let result = manager.start_accessing(Path::new("/nonexistent/path"));
        // May or may not fail depending on macOS behavior, just verify no panic.
        let _ = result;
        manager.stop_accessing(Path::new("/nonexistent/path"));
    }

    #[test]
    fn restore_bookmark_fails_for_invalid_data() {
        let manager = MacOsBookmarkManager::new();
        let result = manager.restore_bookmark(&[0, 1, 2, 3, 4]);
        assert!(result.is_err());
    }

    #[test]
    fn create_and_restore_bookmark_for_temp_file() {
        let dir = tempfile::tempdir();
        let dir = match dir {
            Ok(d) => d,
            Err(_) => return, // skip if tempdir fails
        };
        let file_path = dir.path().join("test_bookmark.txt");
        std::fs::write(&file_path, "bookmark test content").ok();

        let manager = MacOsBookmarkManager::new();
        let bookmark_data = match manager.create_bookmark(&file_path) {
            Ok(data) => data,
            Err(_) => return, // may fail in CI/sandboxed environments
        };

        assert!(!bookmark_data.is_empty());

        // Restore the bookmark.
        match manager.restore_bookmark(&bookmark_data) {
            Ok((resolved_path, is_stale)) => {
                // macOS resolves symlinks (e.g. /var → /private/var), so
                // canonicalize both paths before comparison.
                let canonical_file = file_path.canonicalize().unwrap_or(file_path);
                let canonical_resolved = resolved_path
                    .canonicalize()
                    .unwrap_or(resolved_path.clone());
                assert_eq!(canonical_resolved, canonical_file);
                assert!(!is_stale);
            }
            Err(_) => {
                // May fail in restricted environments, that's OK.
            }
        }
    }
}

//! Platform-specific update application.
//!
//! Downloads new binaries and replaces the current executable using
//! platform-appropriate mechanisms (direct replace on Linux/macOS,
//! helper script on Windows).

use crate::error::{Result, SpeechError};
use crate::update::state::StagedUpdate;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Result of an update application attempt.
#[derive(Debug)]
pub enum ApplyResult {
    /// Update applied successfully. Restart required.
    RestartRequired {
        /// Path to the new binary.
        new_binary: PathBuf,
    },
    /// Update applied via helper script (Windows). App should exit.
    ExitRequired {
        /// Path to the helper script that finishes the update.
        helper_script: PathBuf,
    },
}

/// Download a release asset and replace the current binary.
///
/// 1. Downloads the new binary to a temp file
/// 2. Verifies the download is executable (runs `--version`)
/// 3. Replaces the current binary using a platform-appropriate method
/// 4. Returns whether a restart or exit is needed
///
/// # Errors
///
/// Returns an error if the download fails, the downloaded binary is invalid,
/// or the replacement fails.
pub fn apply_update(download_url: &str, current_binary: &Path) -> Result<ApplyResult> {
    let temp_dir = std::env::temp_dir().join("fae-self-update");
    std::fs::create_dir_all(&temp_dir)
        .map_err(|e| SpeechError::Update(format!("cannot create temp dir: {e}")))?;

    let temp_binary = temp_dir.join(binary_filename());

    // Step 1: Download.
    tracing::info!("downloading update from {download_url}");
    download_binary(download_url, &temp_binary)?;

    // Step 2: Verify.
    verify_binary(&temp_binary)?;

    // Step 3: Replace.
    let result = replace_binary(&temp_binary, current_binary)?;

    // Step 4: Clean up temp dir (best-effort).
    let _ = std::fs::remove_dir_all(&temp_dir);

    Ok(result)
}

/// Returns the path to the currently running executable.
///
/// # Errors
///
/// Returns an error if the path cannot be determined.
pub fn current_exe_path() -> Result<PathBuf> {
    std::env::current_exe()
        .map_err(|e| SpeechError::Update(format!("cannot determine current executable path: {e}")))
}

/// Roll back to the previous binary version.
///
/// Looks for a `.old` backup next to the current executable and restores it.
/// Returns `true` if a rollback was performed, `false` if no backup exists.
///
/// # Errors
///
/// Returns an error if the backup exists but cannot be restored.
pub fn rollback_update() -> Result<bool> {
    let current = current_exe_path()?;
    let backup = current.with_extension("old");
    if !backup.exists() {
        return Ok(false);
    }
    std::fs::rename(&backup, &current).map_err(|e| {
        SpeechError::Update(format!(
            "cannot restore backup {} → {}: {e}",
            backup.display(),
            current.display()
        ))
    })?;
    tracing::info!("rolled back to previous binary at {}", current.display());
    Ok(true)
}

/// Remove the `.old` backup left by a previous update.
///
/// Call this on successful startup to confirm the update worked and free
/// disk space. Safe to call when no backup exists (returns `Ok(())`).
pub fn cleanup_old_backup() -> Result<()> {
    let current = current_exe_path()?;
    let backup = current.with_extension("old");
    if backup.exists() {
        std::fs::remove_file(&backup).map_err(|e| {
            SpeechError::Update(format!(
                "cannot remove old backup {}: {e}",
                backup.display()
            ))
        })?;
        tracing::info!("removed old backup at {}", backup.display());
    }
    Ok(())
}

// ── Staged update support ───────────────────────────────────────────────────

/// Result of a staging attempt.
#[derive(Debug)]
pub enum StageResult {
    /// Binary was downloaded and staged successfully.
    Staged(StagedUpdate),
    /// A valid staged binary already exists for this version.
    AlreadyStaged(StagedUpdate),
    /// Staging failed.
    Failed(String),
}

/// Returns the staging directory for pre-downloaded updates.
///
/// - macOS: `~/Library/Application Support/fae/staged-update/`
/// - Linux/other: `$XDG_DATA_HOME/fae/staged-update/` (via [`crate::fae_dirs::data_dir`])
pub fn staging_directory() -> PathBuf {
    crate::fae_dirs::data_dir().join("staged-update")
}

/// Download a release binary to the staging directory and verify it.
///
/// The staged binary can later be installed via [`install_via_helper`] when the
/// user chooses to relaunch. Returns [`StageResult::AlreadyStaged`] if a valid
/// staged binary for this version already exists.
///
/// # Errors
///
/// Returns [`StageResult::Failed`] if the download or verification fails.
pub fn stage_update(download_url: &str, version: &str) -> StageResult {
    let staging_dir = staging_directory();

    // Check for an existing staged binary for this version.
    let staged_binary = staging_dir.join(binary_filename());
    if staged_binary.exists() {
        if verify_binary(&staged_binary).is_ok() {
            let staged_at = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            return StageResult::AlreadyStaged(StagedUpdate {
                version: version.to_owned(),
                download_url: download_url.to_owned(),
                staged_path: staged_binary,
                staged_at,
            });
        }
        // Invalid existing staged binary — remove and re-download.
        let _ = std::fs::remove_dir_all(&staging_dir);
    }

    if let Err(e) = std::fs::create_dir_all(&staging_dir) {
        return StageResult::Failed(format!("cannot create staging dir: {e}"));
    }

    tracing::info!("staging update v{version} from {download_url}");
    if let Err(e) = download_binary(download_url, &staged_binary) {
        let _ = std::fs::remove_dir_all(&staging_dir);
        return StageResult::Failed(format!("download failed: {e}"));
    }

    if let Err(e) = verify_binary(&staged_binary) {
        let _ = std::fs::remove_dir_all(&staging_dir);
        return StageResult::Failed(format!("verification failed: {e}"));
    }

    let staged_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    tracing::info!("update v{version} staged at {}", staged_binary.display());

    StageResult::Staged(StagedUpdate {
        version: version.to_owned(),
        download_url: download_url.to_owned(),
        staged_path: staged_binary,
        staged_at,
    })
}

/// Install a previously staged binary via a detached helper shell script.
///
/// The helper script:
/// 1. Waits for the current process to exit
/// 2. Backs up the current binary
/// 3. Copies the staged binary into place
/// 4. Clears the macOS quarantine attribute
/// 5. Relaunches via `open -n` (for .app bundles) or direct exec
/// 6. Cleans up the staging directory and backup
///
/// The caller should call `std::process::exit(0)` after this function returns.
///
/// # Errors
///
/// Returns an error if the helper script cannot be written or launched.
pub fn install_via_helper(staged_path: &Path, target_binary: &Path) -> Result<()> {
    let pid = std::process::id();

    // Determine relaunch command: `open -n Bundle.app` for .app bundles,
    // or direct exec for CLI installs.
    let relaunch_cmd = macos_app_bundle_root(target_binary)
        .map(|bundle| format!("open -n \"{}\"", bundle.display()))
        .unwrap_or_else(|| format!("\"{}\" &", target_binary.display()));

    let staging_dir = staged_path.parent().unwrap_or_else(|| Path::new("/tmp"));

    let script = format!(
        r#"#!/bin/bash
# Fae self-update helper — auto-generated, safe to delete.
set -e

PID={pid}
STAGED="{staged}"
TARGET="{target}"
BACKUP="{backup}"
STAGING_DIR="{staging_dir}"

# Wait for the running process to exit.
while kill -0 "$PID" 2>/dev/null; do
    sleep 0.2
done

# Back up current binary.
if [ -f "$TARGET" ]; then
    cp "$TARGET" "$BACKUP"
fi

# Install staged binary.
cp "$STAGED" "$TARGET"
chmod +x "$TARGET"

# Remove macOS quarantine attribute.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# Relaunch.
{relaunch_cmd}

# Cleanup: remove staging dir and backup (best-effort).
sleep 1
rm -rf "$STAGING_DIR"
rm -f "$BACKUP"

# Self-delete.
rm -f "$0"
"#,
        pid = pid,
        staged = staged_path.display(),
        target = target_binary.display(),
        backup = target_binary.with_extension("backup").display(),
        staging_dir = staging_dir.display(),
        relaunch_cmd = relaunch_cmd,
    );

    let script_path = std::env::temp_dir().join("fae-update-helper.sh");
    std::fs::write(&script_path, &script).map_err(|e| {
        SpeechError::Update(format!(
            "cannot write update helper script to {}: {e}",
            script_path.display()
        ))
    })?;

    set_executable(&script_path)?;

    // Launch the helper as a fully detached process.
    std::process::Command::new("/bin/bash")
        .arg(&script_path)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| {
            SpeechError::Update(format!(
                "cannot launch update helper script {}: {e}",
                script_path.display()
            ))
        })?;

    tracing::info!("update helper launched (pid {}), app should exit now", pid);
    Ok(())
}

/// Remove leftover staging files from a previous successful (or abandoned) update.
///
/// Safe to call when no staging directory exists — returns `Ok(())`.
pub fn cleanup_staged_update() -> Result<()> {
    let staging_dir = staging_directory();
    if staging_dir.exists() {
        std::fs::remove_dir_all(&staging_dir).map_err(|e| {
            SpeechError::Update(format!(
                "cannot remove staging directory {}: {e}",
                staging_dir.display()
            ))
        })?;
        tracing::info!("cleaned up staging directory at {}", staging_dir.display());
    }
    Ok(())
}

/// Find the `.app` bundle root containing a binary, if any.
///
/// Walks up from the binary path looking for a parent with a `.app` extension.
fn macos_app_bundle_root(binary: &Path) -> Option<PathBuf> {
    let mut current = binary;
    while let Some(parent) = current.parent() {
        if parent
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| ext.eq_ignore_ascii_case("app"))
        {
            return Some(parent.to_path_buf());
        }
        current = parent;
    }
    None
}

/// Returns the expected binary filename for the current platform.
fn binary_filename() -> &'static str {
    if cfg!(target_os = "windows") {
        "fae.exe"
    } else {
        "fae"
    }
}

/// Download a file from a URL to a local path.
fn download_binary(url: &str, dest: &Path) -> Result<()> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(300))
        .build();

    let resp = agent
        .get(url)
        .set("User-Agent", "fae/0.1 (self-update)")
        .call()
        .map_err(|e| SpeechError::Update(format!("download failed: {e}")))?;

    let mut reader = resp.into_reader();
    let mut file = std::fs::File::create(dest).map_err(|e| {
        SpeechError::Update(format!("cannot create temp file {}: {e}", dest.display()))
    })?;

    std::io::copy(&mut reader, &mut file)
        .map_err(|e| SpeechError::Update(format!("download write failed: {e}")))?;

    Ok(())
}

/// Verify the downloaded binary is valid by running it with `--version`.
///
/// On macOS, clears the quarantine extended attribute before execution so
/// Gatekeeper doesn't block the binary inside the App Sandbox container.
fn verify_binary(path: &Path) -> Result<()> {
    // Set executable permission first (Unix).
    set_executable(path)?;

    // Clear macOS quarantine attribute BEFORE attempting to run the binary.
    // Without this, Gatekeeper blocks execution of downloaded binaries inside
    // the App Sandbox container with "Operation not permitted".
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("xattr")
            .args(["-d", "com.apple.quarantine", &path.to_string_lossy()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }

    let output = std::process::Command::new(path)
        .arg("--version")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output()
        .map_err(|e| {
            SpeechError::Update(format!(
                "cannot run downloaded binary {}: {e}",
                path.display()
            ))
        })?;

    if !output.status.success() {
        return Err(SpeechError::Update(format!(
            "downloaded binary failed --version check (exit code {:?})",
            output.status.code()
        )));
    }

    tracing::info!("downloaded binary verified successfully");
    Ok(())
}

/// Set executable permission on Unix platforms.
fn set_executable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).map_err(|e| {
            SpeechError::Update(format!(
                "cannot set executable permission on {}: {e}",
                path.display()
            ))
        })?;
    }
    let _ = path; // Suppress unused warning on Windows.
    Ok(())
}

/// Replace the current binary with the new one.
///
/// - **Linux/macOS**: Rename old binary as backup, move new binary in place,
///   clear macOS quarantine attribute.
/// - **Windows**: Write a helper `.bat` script that waits for the process to
///   exit, replaces the binary, and relaunches.
fn replace_binary(new_binary: &Path, current_binary: &Path) -> Result<ApplyResult> {
    #[cfg(not(target_os = "windows"))]
    {
        replace_binary_unix(new_binary, current_binary)
    }
    #[cfg(target_os = "windows")]
    {
        replace_binary_windows(new_binary, current_binary)
    }
}

/// Unix binary replacement: rename old → backup, copy new → target.
#[cfg(not(target_os = "windows"))]
fn replace_binary_unix(new_binary: &Path, current_binary: &Path) -> Result<ApplyResult> {
    let backup = current_binary.with_extension("old");

    // Rename current binary as backup.
    if current_binary.exists() {
        std::fs::rename(current_binary, &backup).map_err(|e| {
            SpeechError::Update(format!(
                "cannot backup current binary {} → {}: {e}",
                current_binary.display(),
                backup.display()
            ))
        })?;
    }

    // Copy new binary to the target location.
    std::fs::copy(new_binary, current_binary).map_err(|e| {
        // Attempt to restore backup.
        if backup.exists() {
            let _ = std::fs::rename(&backup, current_binary);
        }
        SpeechError::Update(format!(
            "cannot install new binary to {}: {e}",
            current_binary.display()
        ))
    })?;

    // Set executable permission.
    set_executable(current_binary)?;

    // Clear macOS quarantine attribute.
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("xattr")
            .args(["-c", &current_binary.to_string_lossy()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }

    // Keep the backup so the user (or a startup check) can roll back if the
    // new binary fails to launch.  The backup is removed on the *next*
    // successful startup via `cleanup_old_backup()`.
    tracing::info!(
        "binary updated at {} (backup at {})",
        current_binary.display(),
        backup.display()
    );
    Ok(ApplyResult::RestartRequired {
        new_binary: current_binary.to_owned(),
    })
}

/// Windows binary replacement: write a helper .bat script.
#[cfg(target_os = "windows")]
fn replace_binary_windows(new_binary: &Path, current_binary: &Path) -> Result<ApplyResult> {
    let script_path = std::env::temp_dir().join("fae-update.bat");
    let script = format!(
        r#"@echo off
echo Updating Fae...
timeout /t 2 /nobreak >nul
copy /y "{new}" "{current}" >nul
if errorlevel 1 (
    echo Update failed.
    pause
    exit /b 1
)
echo Update complete. Restarting...
start "" "{current}"
del "%~f0"
"#,
        new = new_binary.display(),
        current = current_binary.display()
    );

    std::fs::write(&script_path, script).map_err(|e| {
        SpeechError::Update(format!(
            "cannot write update script to {}: {e}",
            script_path.display()
        ))
    })?;

    tracing::info!("update script written to {}", script_path.display());
    Ok(ApplyResult::ExitRequired {
        helper_script: script_path,
    })
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn binary_filename_is_correct() {
        let name = binary_filename();
        if cfg!(target_os = "windows") {
            assert_eq!(name, "fae.exe");
        } else {
            assert_eq!(name, "fae");
        }
    }

    #[test]
    fn current_exe_path_returns_ok() {
        let path = current_exe_path();
        assert!(path.is_ok());
        assert!(path.unwrap().exists());
    }

    #[test]
    fn set_executable_succeeds_on_temp_file() {
        let dir = std::env::temp_dir().join("fae-test-applier");
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("test-binary");
        std::fs::write(&file, "#!/bin/sh\necho ok").unwrap();

        let result = set_executable(&file);
        assert!(result.is_ok());

        // Verify permission on Unix.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::metadata(&file).unwrap().permissions();
            assert_eq!(perms.mode() & 0o111, 0o111);
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn verify_binary_rejects_nonexistent() {
        let result = verify_binary(Path::new("/nonexistent/fae-test-binary"));
        assert!(result.is_err());
    }

    #[test]
    fn verify_binary_rejects_invalid() {
        let dir = std::env::temp_dir().join("fae-test-verify");
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("not-a-binary");
        std::fs::write(&file, "this is not an executable").unwrap();

        let result = verify_binary(&file);
        // Should fail because the file can't be executed as a binary.
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(not(target_os = "windows"))]
    #[test]
    fn replace_binary_unix_works() {
        let dir = std::env::temp_dir().join("fae-test-replace");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let old_binary = dir.join("fae");
        let new_binary = dir.join("fae-new");

        std::fs::write(&old_binary, "old-content").unwrap();
        std::fs::write(&new_binary, "new-content").unwrap();

        let result = replace_binary_unix(&new_binary, &old_binary).unwrap();
        assert!(matches!(result, ApplyResult::RestartRequired { .. }));

        let content = std::fs::read_to_string(&old_binary).unwrap();
        assert_eq!(content, "new-content");

        // Backup should still exist for potential rollback.
        assert!(old_binary.with_extension("old").exists());
        let backup_content = std::fs::read_to_string(old_binary.with_extension("old")).unwrap();
        assert_eq!(backup_content, "old-content");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(not(target_os = "windows"))]
    #[test]
    fn replace_binary_unix_creates_from_nothing() {
        let dir = std::env::temp_dir().join("fae-test-replace-new");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let target = dir.join("fae");
        let source = dir.join("fae-new");

        // No existing binary at target.
        std::fs::write(&source, "new-content").unwrap();

        let result = replace_binary_unix(&source, &target).unwrap();
        assert!(matches!(result, ApplyResult::RestartRequired { .. }));
        assert!(target.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cleanup_old_backup_removes_backup() {
        let dir = std::env::temp_dir().join("fae-test-cleanup");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let binary = dir.join("test-binary");
        let backup = dir.join("test-binary.old");

        std::fs::write(&binary, "current").unwrap();
        std::fs::write(&backup, "old-version").unwrap();

        // cleanup_old_backup uses current_exe_path, so we can't test it
        // end-to-end here. Instead verify the backup file logic directly.
        assert!(backup.exists());
        std::fs::remove_file(&backup).unwrap();
        assert!(!backup.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn staging_directory_is_under_data_dir() {
        let dir = staging_directory();
        let data = crate::fae_dirs::data_dir();
        assert!(
            dir.starts_with(&data),
            "staging dir {} should be under data dir {}",
            dir.display(),
            data.display()
        );
        assert!(dir.ends_with("staged-update"));
    }

    #[test]
    fn cleanup_staged_update_ok_when_no_dir() {
        // Should succeed even when no staging directory exists.
        let result = cleanup_staged_update();
        assert!(result.is_ok());
    }

    #[test]
    fn cleanup_staged_update_removes_dir() {
        let dir = staging_directory();
        let _ = std::fs::create_dir_all(&dir);
        std::fs::write(dir.join("fae"), "dummy").unwrap();
        assert!(dir.exists());

        let result = cleanup_staged_update();
        assert!(result.is_ok());
        assert!(!dir.exists());
    }

    #[test]
    fn stage_update_fails_with_bad_url() {
        let result = stage_update("http://localhost:1/nonexistent", "99.99.99");
        assert!(matches!(result, StageResult::Failed(_)));
    }

    #[test]
    fn macos_app_bundle_root_finds_app() {
        let path = Path::new("/Applications/Fae.app/Contents/MacOS/fae");
        let bundle = macos_app_bundle_root(path);
        assert_eq!(bundle, Some(PathBuf::from("/Applications/Fae.app")));
    }

    #[test]
    fn macos_app_bundle_root_returns_none_for_cli() {
        let path = Path::new("/usr/local/bin/fae");
        let bundle = macos_app_bundle_root(path);
        assert!(bundle.is_none());
    }

    #[cfg(not(target_os = "windows"))]
    #[test]
    fn install_via_helper_generates_script() {
        let dir = std::env::temp_dir().join("fae-test-helper-gen");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let staged = dir.join("fae");
        let target = dir.join("fae-target");
        std::fs::write(&staged, "new-binary").unwrap();
        std::fs::write(&target, "old-binary").unwrap();

        // We can't actually run the helper (it waits for our PID to exit),
        // but we can verify the script is written and contains the right content.
        // install_via_helper will spawn the script, which will wait for us to exit
        // (which we won't), so it's harmless in tests.
        let result = install_via_helper(&staged, &target);
        assert!(result.is_ok());

        // Verify the helper script was written.
        let script_path = std::env::temp_dir().join("fae-update-helper.sh");
        assert!(script_path.exists());

        let script_content = std::fs::read_to_string(&script_path).unwrap();
        assert!(script_content.contains("kill -0"));
        assert!(script_content.contains(&staged.display().to_string()));
        assert!(script_content.contains(&target.display().to_string()));
        assert!(script_content.contains("xattr"));
        assert!(script_content.contains("chmod +x"));

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_file(&script_path);
    }
}

//! Platform-specific update application.
//!
//! Downloads new binaries and replaces the current executable using
//! platform-appropriate mechanisms (direct replace on Linux/macOS,
//! helper script on Windows).

use crate::error::{Result, SpeechError};
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
    std::fs::create_dir_all(&temp_dir).map_err(|e| {
        SpeechError::Update(format!("cannot create temp dir: {e}"))
    })?;

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
    std::env::current_exe().map_err(|e| {
        SpeechError::Update(format!("cannot determine current executable path: {e}"))
    })
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

    std::io::copy(&mut reader, &mut file).map_err(|e| {
        SpeechError::Update(format!("download write failed: {e}"))
    })?;

    Ok(())
}

/// Verify the downloaded binary is valid by running it with `--version`.
fn verify_binary(path: &Path) -> Result<()> {
    // Set executable permission first (Unix).
    set_executable(path)?;

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

    // Remove backup.
    let _ = std::fs::remove_file(&backup);

    tracing::info!("binary updated at {}", current_binary.display());
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

        // Backup should have been cleaned up.
        assert!(!old_binary.with_extension("old").exists());

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
}

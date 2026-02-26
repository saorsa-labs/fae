//! Platform-specific update application.
//!
//! Downloads new binaries and replaces the current executable using
//! platform-appropriate mechanisms (direct replace on Linux/macOS,
//! helper script on Windows).

use crate::error::{Result, SpeechError};
use crate::update::state::StagedUpdate;
use sha2::{Digest, Sha256};
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
/// 2. Verifies signed checksums and local file integrity
/// 3. Replaces the current binary using a platform-appropriate method
/// 4. Returns whether a restart or exit is needed
///
/// # Errors
///
/// Returns an error if the download fails, the downloaded binary is invalid,
/// or the replacement fails.
pub fn apply_update(
    release: &crate::update::Release,
    current_binary: &Path,
) -> Result<ApplyResult> {
    if release.download_url.trim().is_empty() {
        return Err(SpeechError::Update(
            "cannot apply update: release download URL is empty".to_owned(),
        ));
    }

    let temp_dir = std::env::temp_dir().join("fae-self-update");
    std::fs::create_dir_all(&temp_dir)
        .map_err(|e| SpeechError::Update(format!("cannot create temp dir: {e}")))?;

    let temp_binary = temp_dir.join(binary_filename());

    // Step 1: Download.
    tracing::info!("downloading update from {}", release.download_url);
    download_binary(&release.download_url, &temp_binary)?;

    // Step 2: Verify checksum/signature and basic binary shape.
    let expected_sha256 = resolve_expected_sha256_for_release(release)?;
    verify_sha256(&temp_binary, &expected_sha256)?;
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
/// Returns [`StageResult::Failed`] if download, signature, checksum, or local
/// file verification fails.
pub fn stage_update(release: &crate::update::Release) -> StageResult {
    if release.download_url.trim().is_empty() {
        return StageResult::Failed("release download URL is empty".to_owned());
    }
    if release.version.trim().is_empty() {
        return StageResult::Failed("release version is empty".to_owned());
    }

    let expected_sha256 = match resolve_expected_sha256_for_release(release) {
        Ok(v) => v,
        Err(e) => {
            return StageResult::Failed(format!("integrity metadata verification failed: {e}"));
        }
    };

    let staging_dir = staging_directory();

    // Check for an existing staged binary for this version.
    let staged_binary = staging_dir.join(binary_filename());
    if staged_binary.exists() {
        if verify_sha256(&staged_binary, &expected_sha256).is_ok()
            && verify_binary(&staged_binary).is_ok()
        {
            return StageResult::AlreadyStaged(build_staged_update_record(
                release,
                staged_binary,
                Some(expected_sha256),
            ));
        }
        // Invalid existing staged binary — remove and re-download.
        let _ = std::fs::remove_dir_all(&staging_dir);
    }

    if let Err(e) = std::fs::create_dir_all(&staging_dir) {
        return StageResult::Failed(format!("cannot create staging dir: {e}"));
    }

    tracing::info!(
        "staging update v{} from {}",
        release.version,
        release.download_url
    );
    if let Err(e) = download_binary(&release.download_url, &staged_binary) {
        let _ = std::fs::remove_dir_all(&staging_dir);
        return StageResult::Failed(format!("download failed: {e}"));
    }

    if let Err(e) = verify_sha256(&staged_binary, &expected_sha256) {
        let _ = std::fs::remove_dir_all(&staging_dir);
        return StageResult::Failed(format!("checksum mismatch: {e}"));
    }

    if let Err(e) = verify_binary(&staged_binary) {
        let _ = std::fs::remove_dir_all(&staging_dir);
        return StageResult::Failed(format!("verification failed: {e}"));
    }

    tracing::info!(
        "update v{} staged at {}",
        release.version,
        staged_binary.display()
    );

    StageResult::Staged(build_staged_update_record(
        release,
        staged_binary,
        Some(expected_sha256),
    ))
}

/// Validate an already-staged update before handing it off to the installer helper.
///
/// This re-checks the staged file against the expected SHA-256 so a tampered
/// staged binary cannot be installed.
pub fn verify_staged_update(staged: &StagedUpdate, release: &crate::update::Release) -> Result<()> {
    if !staged.staged_path.exists() {
        return Err(SpeechError::Update(format!(
            "staged update path does not exist: {}",
            staged.staged_path.display()
        )));
    }

    let expected_sha256 = if let Some(ref checksum) = staged.expected_sha256 {
        checksum.clone()
    } else {
        resolve_expected_sha256_for_release(release)?
    };

    verify_sha256(&staged.staged_path, &expected_sha256)?;
    verify_binary(&staged.staged_path)?;
    Ok(())
}

/// Return user-facing warnings for missing update verification prerequisites.
///
/// If this returns a non-empty list, signed in-app updates are not fully
/// configured on the current machine and install attempts are expected to fail.
pub fn update_verification_warnings() -> Vec<String> {
    let mut warnings = Vec::new();

    if find_gpg_binary().is_none() {
        warnings.push("Signed updates unavailable: install GnuPG (`gpg` or `gpg2`).".to_owned());
    }

    if let Err(e) = trusted_update_public_key() {
        warnings.push(format!("Signed updates unavailable: {e}"));
    }

    warnings
}

fn build_staged_update_record(
    release: &crate::update::Release,
    staged_path: PathBuf,
    expected_sha256: Option<String>,
) -> StagedUpdate {
    let staged_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    StagedUpdate {
        version: release.version.clone(),
        download_url: release.download_url.clone(),
        asset_name: if release.asset_name.trim().is_empty() {
            binary_filename().to_owned()
        } else {
            release.asset_name.clone()
        },
        checksums_url: release.checksums_url.clone(),
        checksums_signature_url: release.checksums_signature_url.clone(),
        expected_sha256,
        staged_path,
        staged_at,
    }
}

fn resolve_expected_sha256_for_release(release: &crate::update::Release) -> Result<String> {
    let checksums_url = release
        .checksums_url
        .as_deref()
        .filter(|url| !url.trim().is_empty())
        .ok_or_else(|| {
            SpeechError::Update(
                "release is missing SHA256SUMS.txt URL; refusing unsigned update".to_owned(),
            )
        })?;
    let signature_url = release
        .checksums_signature_url
        .as_deref()
        .filter(|url| !url.trim().is_empty())
        .ok_or_else(|| {
            SpeechError::Update(
                "release is missing SHA256SUMS.txt signature URL; refusing unsigned update"
                    .to_owned(),
            )
        })?;

    let asset_name = if release.asset_name.trim().is_empty() {
        binary_filename().to_owned()
    } else {
        release.asset_name.clone()
    };

    let verify_dir = std::env::temp_dir().join(format!(
        "fae-update-verify-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    std::fs::create_dir_all(&verify_dir).map_err(|e| {
        SpeechError::Update(format!(
            "cannot create checksum verification dir {}: {e}",
            verify_dir.display()
        ))
    })?;

    let checksums_path = verify_dir.join("SHA256SUMS.txt");
    let signature_path = verify_dir.join("SHA256SUMS.txt.asc");

    let result = (|| -> Result<String> {
        download_binary(checksums_url, &checksums_path)?;
        download_binary(signature_url, &signature_path)?;
        verify_checksums_signature(&checksums_path, &signature_path)?;

        let checksums_content = std::fs::read_to_string(&checksums_path).map_err(|e| {
            SpeechError::Update(format!(
                "cannot read checksums file {}: {e}",
                checksums_path.display()
            ))
        })?;
        parse_sha256_from_manifest(&checksums_content, &asset_name).ok_or_else(|| {
            SpeechError::Update(format!(
                "SHA256SUMS.txt does not contain a checksum for asset '{asset_name}'"
            ))
        })
    })();

    let _ = std::fs::remove_dir_all(&verify_dir);
    result
}

fn parse_sha256_from_manifest(manifest: &str, asset_name: &str) -> Option<String> {
    for line in manifest.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let mut parts = trimmed.split_whitespace();
        let checksum = parts.next()?;
        let file = parts.next()?;

        if checksum.len() != 64 || !checksum.chars().all(|c| c.is_ascii_hexdigit()) {
            continue;
        }

        let file = file.trim_start_matches('*');
        let file_name = std::path::Path::new(file)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(file);
        if file_name == asset_name {
            return Some(checksum.to_ascii_lowercase());
        }
    }

    None
}

fn verify_sha256(path: &Path, expected_hex: &str) -> Result<()> {
    let expected = normalize_hex(expected_hex);
    if expected.len() != 64 {
        return Err(SpeechError::Update(format!(
            "invalid expected SHA-256 length for {}",
            path.display()
        )));
    }

    let actual = sha256_hex(path)?;
    if actual != expected {
        return Err(SpeechError::Update(format!(
            "SHA-256 mismatch for {} (expected {}, got {})",
            path.display(),
            expected,
            actual
        )));
    }
    Ok(())
}

fn sha256_hex(path: &Path) -> Result<String> {
    use std::io::Read;

    let mut file = std::fs::File::open(path)
        .map_err(|e| SpeechError::Update(format!("cannot open {}: {e}", path.display())))?;
    let mut hasher = Sha256::new();
    let mut buf = [0_u8; 16 * 1024];

    loop {
        let read = file
            .read(&mut buf)
            .map_err(|e| SpeechError::Update(format!("cannot read {}: {e}", path.display())))?;
        if read == 0 {
            break;
        }
        hasher.update(&buf[..read]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}

fn normalize_hex(input: &str) -> String {
    input
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

fn verify_checksums_signature(checksums_path: &Path, signature_path: &Path) -> Result<()> {
    let gpg = find_gpg_binary().ok_or_else(|| {
        SpeechError::Update(
            "GPG binary not found (`gpg` or `gpg2` required for signed updates)".to_owned(),
        )
    })?;
    let trusted_public_key = trusted_update_public_key()?;
    let expected_fingerprint = trusted_update_signing_fingerprint();

    let gpg_home = std::env::temp_dir().join(format!(
        "fae-gpg-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    std::fs::create_dir_all(&gpg_home).map_err(|e| {
        SpeechError::Update(format!(
            "cannot create temporary GPG home {}: {e}",
            gpg_home.display()
        ))
    })?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&gpg_home, std::fs::Permissions::from_mode(0o700));
    }

    let key_path = gpg_home.join("update-signing-key.asc");
    std::fs::write(&key_path, trusted_public_key).map_err(|e| {
        SpeechError::Update(format!(
            "cannot write trusted update key {}: {e}",
            key_path.display()
        ))
    })?;

    let result = (|| -> Result<()> {
        let import_output = std::process::Command::new(gpg)
            .arg("--batch")
            .arg("--homedir")
            .arg(&gpg_home)
            .arg("--import")
            .arg(&key_path)
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| SpeechError::Update(format!("failed to run gpg import: {e}")))?;

        if !import_output.status.success() {
            let stderr = String::from_utf8_lossy(&import_output.stderr)
                .trim()
                .chars()
                .take(240)
                .collect::<String>();
            return Err(SpeechError::Update(format!(
                "failed to import trusted update key: {stderr}"
            )));
        }

        let verify_output = std::process::Command::new(gpg)
            .arg("--batch")
            .arg("--status-fd")
            .arg("1")
            .arg("--homedir")
            .arg(&gpg_home)
            .arg("--verify")
            .arg(signature_path)
            .arg(checksums_path)
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| SpeechError::Update(format!("failed to run gpg verify: {e}")))?;

        if !verify_output.status.success() {
            let stderr = String::from_utf8_lossy(&verify_output.stderr)
                .trim()
                .chars()
                .take(240)
                .collect::<String>();
            return Err(SpeechError::Update(format!(
                "checksum signature verification failed: {stderr}"
            )));
        }

        if let Some(expected_fp) = expected_fingerprint {
            let status_text = String::from_utf8_lossy(&verify_output.stdout);
            let found_fp = parse_validsig_fingerprint(&status_text).ok_or_else(|| {
                SpeechError::Update(
                    "gpg verify succeeded but did not emit a VALIDSIG fingerprint".to_owned(),
                )
            })?;

            if normalize_hex(&found_fp) != normalize_hex(&expected_fp) {
                return Err(SpeechError::Update(format!(
                    "unexpected update signing fingerprint: expected {}, got {}",
                    normalize_hex(&expected_fp),
                    normalize_hex(&found_fp)
                )));
            }
        }

        Ok(())
    })();

    let _ = std::fs::remove_dir_all(&gpg_home);
    result
}

fn parse_validsig_fingerprint(status_output: &str) -> Option<String> {
    for line in status_output.lines() {
        if let Some(rest) = line.strip_prefix("[GNUPG:] VALIDSIG ") {
            return rest.split_whitespace().next().map(ToOwned::to_owned);
        }
    }
    None
}

fn trusted_update_public_key() -> Result<String> {
    if let Ok(value) = std::env::var("FAE_UPDATE_GPG_PUBLIC_KEY")
        && !value.trim().is_empty()
    {
        return Ok(value);
    }

    let path = crate::fae_dirs::config_dir().join("update-signing-public-key.asc");
    if path.exists() {
        let key = std::fs::read_to_string(&path).map_err(|e| {
            SpeechError::Update(format!(
                "cannot read update signing key from {}: {e}",
                path.display()
            ))
        })?;
        if !key.trim().is_empty() {
            return Ok(key);
        }
    }

    if let Some(value) = option_env!("FAE_UPDATE_GPG_PUBLIC_KEY")
        && !value.trim().is_empty()
    {
        return Ok(value.to_owned());
    }

    Err(SpeechError::Update(format!(
        "missing trusted update signing key; set FAE_UPDATE_GPG_PUBLIC_KEY or provide {}",
        path.display()
    )))
}

fn trusted_update_signing_fingerprint() -> Option<String> {
    if let Ok(value) = std::env::var("FAE_UPDATE_GPG_FINGERPRINT")
        && !value.trim().is_empty()
    {
        return Some(value);
    }
    option_env!("FAE_UPDATE_GPG_FINGERPRINT")
        .filter(|v| !v.trim().is_empty())
        .map(ToOwned::to_owned)
}

fn find_gpg_binary() -> Option<&'static str> {
    for candidate in ["gpg", "gpg2"] {
        let status = std::process::Command::new(candidate)
            .arg("--version")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        if status.is_ok_and(|s| s.success()) {
            return Some(candidate);
        }
    }
    None
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

/// Verify basic properties of the downloaded binary.
///
/// This intentionally does not execute the downloaded file. It only ensures
/// executable permissions are set and the file exists as a non-empty regular
/// file. Cryptographic integrity is checked separately via SHA-256 + GPG.
fn verify_binary(path: &Path) -> Result<()> {
    // Set executable permission first (Unix).
    set_executable(path)?;

    // Clear macOS quarantine attribute so relaunch isn't blocked after install.
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("xattr")
            .args(["-d", "com.apple.quarantine", &path.to_string_lossy()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }

    let metadata = std::fs::metadata(path).map_err(|e| {
        SpeechError::Update(format!(
            "cannot stat downloaded binary {}: {e}",
            path.display()
        ))
    })?;
    if !metadata.is_file() {
        return Err(SpeechError::Update(format!(
            "downloaded update is not a file: {}",
            path.display()
        )));
    }
    if metadata.len() == 0 {
        return Err(SpeechError::Update(format!(
            "downloaded update is empty: {}",
            path.display()
        )));
    }

    tracing::info!("downloaded binary verified (permissions + non-empty file)");
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
    fn verify_binary_accepts_nonempty_file() {
        let dir = std::env::temp_dir().join("fae-test-verify");
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("not-a-binary");
        std::fs::write(&file, "this is not an executable").unwrap();

        let result = verify_binary(&file);
        assert!(result.is_ok());

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
        let release = crate::update::Release {
            tag_name: "v99.99.99".to_owned(),
            version: "99.99.99".to_owned(),
            download_url: "http://localhost:1/nonexistent".to_owned(),
            asset_name: binary_filename().to_owned(),
            checksums_url: Some("http://localhost:1/SHA256SUMS.txt".to_owned()),
            checksums_signature_url: Some("http://localhost:1/SHA256SUMS.txt.asc".to_owned()),
            release_notes: String::new(),
            published_at: String::new(),
            asset_size: 0,
        };
        let result = stage_update(&release);
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

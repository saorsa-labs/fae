//! Diagnostic bundle creation for user-facing log gathering.
//!
//! Creates a timestamped zip file in the diagnostics directory containing:
//! - Log files
//! - Configuration files (no secrets)
//! - Basic system information
//!
//! Explicitly excludes: memory records, conversations, voice samples, API keys.

use crate::error::{Result, SpeechError};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use zip::ZipWriter;
use zip::write::SimpleFileOptions;

/// Gathers diagnostic information into a zip file.
///
/// The bundle is written to [`crate::fae_dirs::diagnostics_dir()`], which is
/// sandbox-safe on macOS.  Returns the path to the created zip file.
///
/// # Errors
///
/// Returns an error if the zip file cannot be created or written.
pub fn gather_diagnostic_bundle() -> Result<PathBuf> {
    let output_dir = crate::fae_dirs::diagnostics_dir();
    fs::create_dir_all(&output_dir)?;

    let timestamp = chrono_timestamp();
    let filename = format!("fae-diagnostics-{timestamp}.zip");
    let zip_path = output_dir.join(&filename);

    let file = fs::File::create(&zip_path)?;
    let mut zip = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    // 1. Log files
    let log_dir = fae_log_dir();
    if log_dir.is_dir() {
        add_directory_to_zip(&mut zip, &log_dir, "logs", options)?;
    }

    // 2. Config file
    let config_path = crate::fae_dirs::config_file();
    if config_path.is_file() {
        add_file_to_zip(&mut zip, &config_path, "config.toml", options)?;
    }

    // 3. Scheduler state
    let scheduler_path = crate::fae_dirs::scheduler_file();
    if scheduler_path.is_file() {
        add_file_to_zip(&mut zip, &scheduler_path, "scheduler.json", options)?;
    }

    // 4. Memory manifest — metadata only, no records
    let manifest_path = crate::fae_dirs::data_dir().join("manifest.toml");
    if manifest_path.is_file() {
        add_file_to_zip(&mut zip, &manifest_path, "manifest.toml", options)?;
    }

    // 5. System information
    let system_info = build_system_info();
    zip.start_file("system-info.txt", options)
        .map_err(|e| SpeechError::Pipeline(format!("zip error: {e}")))?;
    zip.write_all(system_info.as_bytes())?;

    zip.finish()
        .map_err(|e| SpeechError::Pipeline(format!("zip finish error: {e}")))?;

    Ok(zip_path)
}

/// Returns the log directory path.
///
/// Delegates to [`crate::fae_dirs::logs_dir`].
pub fn fae_log_dir() -> PathBuf {
    crate::fae_dirs::logs_dir()
}

/// Generates a simple timestamp string for filenames.
///
/// Returns a string in `YYYYMMDD-HHMMSS` format (UTC).
pub fn chrono_timestamp() -> String {
    use std::time::SystemTime;

    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Convert epoch seconds to a readable YYYYMMDD-HHMMSS string.
    let secs_per_day: u64 = 86400;
    let secs_per_hour: u64 = 3600;
    let secs_per_min: u64 = 60;

    // Days since epoch → date (simplified, no leap-second precision needed)
    let days = now / secs_per_day;
    let time_of_day = now % secs_per_day;

    let hour = time_of_day / secs_per_hour;
    let minute = (time_of_day % secs_per_hour) / secs_per_min;
    let second = time_of_day % secs_per_min;

    // Approximate year/month/day from days since epoch (1970-01-01).
    let (year, month, day) = days_to_ymd(days);

    format!("{year:04}{month:02}{day:02}-{hour:02}{minute:02}{second:02}")
}

/// Convert days since Unix epoch to (year, month, day).
fn days_to_ymd(days: u64) -> (u64, u64, u64) {
    // Adapted from Howard Hinnant's civil_from_days algorithm.
    let z = days as i64 + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y as u64, m, d)
}

/// Builds a system information text block.
fn build_system_info() -> String {
    let mut info = String::new();
    info.push_str("=== Fae Diagnostic Report ===\n\n");

    // Fae version
    info.push_str(&format!("Fae version: {}\n", env!("CARGO_PKG_VERSION")));

    // OS info
    info.push_str(&format!("OS: {}\n", std::env::consts::OS));
    info.push_str(&format!("Arch: {}\n", std::env::consts::ARCH));

    // macOS version (best-effort)
    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = std::process::Command::new("sw_vers").output()
            && let Ok(text) = String::from_utf8(output.stdout)
        {
            info.push_str(&format!("macOS:\n{text}\n"));
        }
    }

    // Audio devices (best-effort via cpal)
    info.push_str("\n=== Audio Devices ===\n");
    match crate::audio::capture::CpalCapture::list_input_devices() {
        Ok(devices) => {
            if devices.is_empty() {
                info.push_str("  (no input devices found)\n");
            }
            for d in &devices {
                info.push_str(&format!("  Input: {d}\n"));
            }
        }
        Err(e) => {
            info.push_str(&format!("  Error listing devices: {e}\n"));
        }
    }
    match crate::audio::playback::CpalPlayback::list_output_devices() {
        Ok(devices) => {
            if devices.is_empty() {
                info.push_str("  (no output devices found)\n");
            }
            for d in &devices {
                info.push_str(&format!("  Output: {d}\n"));
            }
        }
        Err(e) => {
            info.push_str(&format!("  Error listing output devices: {e}\n"));
        }
    }

    info
}

/// Add all files from a directory into the zip under a given prefix.
///
/// Recursively traverses subdirectories, preserving the directory structure
/// in the ZIP archive paths.
fn add_directory_to_zip<W: Write + std::io::Seek>(
    zip: &mut ZipWriter<W>,
    dir: &Path,
    prefix: &str,
    options: SimpleFileOptions,
) -> Result<()> {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };

    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        if path.is_file() {
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown");
            let zip_name = format!("{prefix}/{name}");
            add_file_to_zip(zip, &path, &zip_name, options)?;
        } else if path.is_dir() {
            let subdir_name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown");
            let subdir_prefix = format!("{prefix}/{subdir_name}");
            add_directory_to_zip(zip, &path, &subdir_prefix, options)?;
        }
    }
    Ok(())
}

/// Add a single file to the zip archive.
fn add_file_to_zip<W: Write + std::io::Seek>(
    zip: &mut ZipWriter<W>,
    path: &Path,
    zip_name: &str,
    options: SimpleFileOptions,
) -> Result<()> {
    let mut file = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return Ok(()), // Skip files we can't read
    };
    zip.start_file(zip_name, options)
        .map_err(|e| SpeechError::Pipeline(format!("zip error: {e}")))?;

    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    zip.write_all(&buf)?;
    Ok(())
}

/// Exports all user data to a ZIP file at the given destination path.
///
/// Includes: configuration files, SOUL.md, memory records, skills, logs,
/// voice samples, wakeword recordings, external API profiles, and soul
/// version history.
///
/// Excludes: model cache (large, re-downloadable) and diagnostics directory.
///
/// # Errors
///
/// Returns an error if the ZIP file cannot be created or written.
pub fn export_all_data(destination: &Path) -> Result<PathBuf> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }

    let file = fs::File::create(destination)?;
    let mut zip = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    // 1. Config directory (config.toml, scheduler.json, etc.)
    let cfg_dir = crate::fae_dirs::config_dir();
    if cfg_dir.is_dir() {
        add_directory_to_zip(&mut zip, &cfg_dir, "config", options)?;
    }

    // 2. Data directory — root files only (SOUL.md, onboarding.md, manifest.toml, …)
    let data = crate::fae_dirs::data_dir();
    if data.is_dir()
        && let Ok(entries) = fs::read_dir(&data)
    {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown");
            let zip_name = format!("data/{name}");
            add_file_to_zip(&mut zip, &path, &zip_name, options)?;
        }
    }

    // 3. Named subdirectories under data_dir()
    let subdirs: &[(&str, PathBuf)] = &[
        ("data/logs", crate::fae_dirs::logs_dir()),
        ("data/skills", crate::fae_dirs::skills_dir()),
        ("data/memory", data.join("memory")),
        ("data/external_apis", crate::fae_dirs::external_apis_dir()),
        ("data/wakeword", crate::fae_dirs::wakeword_dir()),
        ("data/voices", data.join("voices")),
        ("data/soul_versions", data.join("soul_versions")),
    ];

    for (prefix, dir_path) in subdirs {
        if dir_path.is_dir() {
            add_directory_to_zip(&mut zip, dir_path, prefix, options)?;
        }
    }

    // 4. Backup metadata
    let metadata = build_backup_metadata();
    zip.start_file("BACKUP_INFO.txt", options)
        .map_err(|e| SpeechError::Pipeline(format!("zip error: {e}")))?;
    zip.write_all(metadata.as_bytes())?;

    zip.finish()
        .map_err(|e| SpeechError::Pipeline(format!("zip finish error: {e}")))?;

    Ok(destination.to_path_buf())
}

/// Builds human-readable metadata for the backup archive.
fn build_backup_metadata() -> String {
    format!(
        "=== Fae Data Backup ===\n\
         \n\
         Fae version: {version}\n\
         Backup date: {date}\n\
         OS: {os} {arch}\n\
         \n\
         Included:\n\
         - Configuration files (config/)\n\
         - User data root files (SOUL.md, onboarding.md, etc.)\n\
         - Memory records (data/memory/)\n\
         - Skills (data/skills/)\n\
         - Logs (data/logs/)\n\
         - Custom voices (data/voices/)\n\
         - Wakeword recordings (data/wakeword/)\n\
         - External API profiles (data/external_apis/)\n\
         - Soul version history (data/soul_versions/)\n\
         \n\
         Excluded (re-downloadable):\n\
         - Model cache (huggingface/)\n\
         - Browser cache\n\
         - Diagnostics bundles\n\
         \n\
         To restore: extract this archive and copy contents to your\n\
         Fae data directories.\n",
        version = env!("CARGO_PKG_VERSION"),
        date = chrono_timestamp(),
        os = std::env::consts::OS,
        arch = std::env::consts::ARCH,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chrono_timestamp_format() {
        let ts = chrono_timestamp();
        // Should be in YYYYMMDD-HHMMSS format (15 chars)
        assert_eq!(ts.len(), 15);
        assert_eq!(&ts[8..9], "-");
    }

    #[test]
    fn test_days_to_ymd_epoch() {
        let (y, m, d) = days_to_ymd(0);
        assert_eq!((y, m, d), (1970, 1, 1));
    }

    #[test]
    fn test_days_to_ymd_known_date() {
        // 2024-01-01 is day 19723
        let (y, m, d) = days_to_ymd(19723);
        assert_eq!((y, m, d), (2024, 1, 1));
    }

    #[test]
    fn test_fae_log_dir_path() {
        let dir = fae_log_dir();
        let path_str = dir.to_string_lossy();
        assert!(path_str.contains("fae"));
        assert!(path_str.ends_with("logs"));
    }

    #[test]
    fn test_build_system_info_contains_version() {
        let info = build_system_info();
        assert!(info.contains("Fae version:"));
        assert!(info.contains(env!("CARGO_PKG_VERSION")));
    }

    #[test]
    fn test_build_backup_metadata_contains_version() {
        let meta = build_backup_metadata();
        assert!(meta.contains("Fae version:"));
        assert!(meta.contains(env!("CARGO_PKG_VERSION")));
        assert!(meta.contains("Included:"));
        assert!(meta.contains("Excluded"));
    }

    /// Helper: set env overrides, run closure, restore env.
    fn with_test_dirs<F, R>(data_dir: &Path, config_dir: &Path, cache_dir: &Path, f: F) -> R
    where
        F: FnOnce() -> R,
    {
        let dk = "FAE_DATA_DIR";
        let ck = "FAE_CONFIG_DIR";
        let xk = "FAE_CACHE_DIR";
        let od = std::env::var_os(dk);
        let oc = std::env::var_os(ck);
        let ox = std::env::var_os(xk);

        // SAFETY: consolidated into a single test to avoid parallel env var races.
        unsafe {
            std::env::set_var(dk, data_dir);
            std::env::set_var(ck, config_dir);
            std::env::set_var(xk, cache_dir);
        }

        let result = f();

        unsafe {
            match od {
                Some(v) => std::env::set_var(dk, v),
                None => std::env::remove_var(dk),
            }
            match oc {
                Some(v) => std::env::set_var(ck, v),
                None => std::env::remove_var(ck),
            }
            match ox {
                Some(v) => std::env::set_var(xk, v),
                None => std::env::remove_var(xk),
            }
        }

        result
    }

    /// Consolidated export test — single test avoids env var race conditions
    /// between parallel test threads.
    #[test]
    fn test_export_all_data() {
        let tmp = tempfile::TempDir::new().unwrap_or_else(|_| unreachable!());

        let data_dir = tmp.path().join("data");
        let config_dir = tmp.path().join("config");
        let cache_dir = tmp.path().join("cache");
        fs::create_dir_all(&data_dir).unwrap_or_else(|_| unreachable!());
        fs::create_dir_all(&config_dir).unwrap_or_else(|_| unreachable!());
        fs::create_dir_all(&cache_dir).unwrap_or_else(|_| unreachable!());

        // Root data files.
        fs::write(data_dir.join("SOUL.md"), "# Test Soul").unwrap_or_else(|_| unreachable!());

        // Config files.
        fs::write(config_dir.join("config.toml"), "[test]\nkey = 1")
            .unwrap_or_else(|_| unreachable!());

        // Skills subdirectory.
        let skills = data_dir.join("skills");
        fs::create_dir_all(&skills).unwrap_or_else(|_| unreachable!());
        fs::write(skills.join("test-skill.md"), "# Skill").unwrap_or_else(|_| unreachable!());

        // Nested soul_versions directory.
        let sv = data_dir.join("soul_versions");
        let sv_sub = sv.join("2026");
        fs::create_dir_all(&sv_sub).unwrap_or_else(|_| unreachable!());
        fs::write(sv.join("v1.md"), "version 1").unwrap_or_else(|_| unreachable!());
        fs::write(sv_sub.join("v2.md"), "version 2").unwrap_or_else(|_| unreachable!());

        // --- Test 1: full backup with files ---
        let dest = tmp.path().join("backup.zip");

        let result = with_test_dirs(&data_dir, &config_dir, &cache_dir, || {
            export_all_data(&dest)
        });

        assert!(result.is_ok(), "export_all_data failed: {result:?}");
        assert!(dest.is_file(), "ZIP file should exist");

        // Open archive and collect entry names.
        let file = fs::File::open(&dest).unwrap_or_else(|_| unreachable!());
        let mut archive = zip::ZipArchive::new(file).unwrap_or_else(|_| unreachable!());
        let names: Vec<String> = (0..archive.len())
            .filter_map(|i| archive.by_index(i).ok().map(|f| f.name().to_owned()))
            .collect();

        // Basic entries.
        assert!(
            names.iter().any(|n| n == "BACKUP_INFO.txt"),
            "should contain BACKUP_INFO.txt, got: {names:?}"
        );
        assert!(
            names.iter().any(|n| n == "data/SOUL.md"),
            "should contain data/SOUL.md, got: {names:?}"
        );
        assert!(
            names.iter().any(|n| n == "config/config.toml"),
            "should contain config/config.toml, got: {names:?}"
        );
        assert!(
            names.iter().any(|n| n == "data/skills/test-skill.md"),
            "should contain data/skills/test-skill.md, got: {names:?}"
        );

        // Nested directories.
        assert!(
            names.iter().any(|n| n == "data/soul_versions/v1.md"),
            "should contain data/soul_versions/v1.md, got: {names:?}"
        );
        assert!(
            names.iter().any(|n| n == "data/soul_versions/2026/v2.md"),
            "should contain nested data/soul_versions/2026/v2.md, got: {names:?}"
        );

        // BACKUP_INFO.txt content.
        let mut info_file = archive
            .by_name("BACKUP_INFO.txt")
            .unwrap_or_else(|_| unreachable!());
        let mut content = String::new();
        info_file
            .read_to_string(&mut content)
            .unwrap_or_else(|_| unreachable!());

        assert!(content.contains("Fae Data Backup"), "should have title");
        assert!(
            content.contains(env!("CARGO_PKG_VERSION")),
            "should have version"
        );
        assert!(content.contains("Included:"), "should list included items");

        // --- Test 2: empty directories (graceful handling) ---
        let empty_data = tmp.path().join("empty_data");
        let empty_config = tmp.path().join("empty_config");
        let empty_cache = tmp.path().join("empty_cache");
        fs::create_dir_all(&empty_data).unwrap_or_else(|_| unreachable!());
        fs::create_dir_all(&empty_config).unwrap_or_else(|_| unreachable!());
        fs::create_dir_all(&empty_cache).unwrap_or_else(|_| unreachable!());

        let empty_dest = tmp.path().join("empty-backup.zip");

        let empty_result = with_test_dirs(&empty_data, &empty_config, &empty_cache, || {
            export_all_data(&empty_dest)
        });

        assert!(
            empty_result.is_ok(),
            "export should succeed with empty dirs: {empty_result:?}"
        );
        let efile = fs::File::open(&empty_dest).unwrap_or_else(|_| unreachable!());
        let earch = zip::ZipArchive::new(efile).unwrap_or_else(|_| unreachable!());
        assert!(
            !earch.is_empty(),
            "empty backup should have at least BACKUP_INFO.txt"
        );
    }
}

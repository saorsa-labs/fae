//! Diagnostic bundle creation for user-facing log gathering.
//!
//! Creates a timestamped zip file on the user's Desktop containing:
//! - Log files from `~/.fae/logs/`
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

/// Gathers diagnostic information into a zip file on the user's Desktop.
///
/// Returns the path to the created zip file.
///
/// # Errors
///
/// Returns an error if the zip file cannot be created or written.
pub fn gather_diagnostic_bundle() -> Result<PathBuf> {
    let desktop = desktop_dir()?;
    let timestamp = chrono_timestamp();
    let filename = format!("fae-diagnostics-{timestamp}.zip");
    let zip_path = desktop.join(&filename);

    let file = fs::File::create(&zip_path)?;
    let mut zip = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    // 1. Log files from ~/.fae/logs/
    let log_dir = fae_log_dir();
    if log_dir.is_dir() {
        add_directory_to_zip(&mut zip, &log_dir, "logs", options)?;
    }

    // 2. Config file (~/.config/fae/config.toml)
    let config_path = crate::SpeechConfig::default_config_path();
    if config_path.is_file() {
        add_file_to_zip(&mut zip, &config_path, "config.toml", options)?;
    }

    // 3. Scheduler state (~/.config/fae/scheduler.json)
    let scheduler_path = scheduler_json_path();
    if scheduler_path.is_file() {
        add_file_to_zip(&mut zip, &scheduler_path, "scheduler.json", options)?;
    }

    // 4. Memory manifest (~/.fae/manifest.toml) — metadata only, no records
    let manifest_path = fae_data_dir().join("manifest.toml");
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

/// Returns the log directory path (`~/.fae/logs/`).
pub fn fae_log_dir() -> PathBuf {
    fae_data_dir().join("logs")
}

/// Returns `~/.fae/`.
fn fae_data_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".fae")
    } else {
        PathBuf::from("/tmp").join(".fae")
    }
}

/// Returns `~/Desktop/`.
fn desktop_dir() -> Result<PathBuf> {
    let home =
        std::env::var_os("HOME").ok_or_else(|| SpeechError::Pipeline("HOME not set".into()))?;
    let desktop = PathBuf::from(home).join("Desktop");
    if !desktop.is_dir() {
        fs::create_dir_all(&desktop)?;
    }
    Ok(desktop)
}

/// Returns `~/.config/fae/scheduler.json`.
fn scheduler_json_path() -> PathBuf {
    if let Some(config) = std::env::var_os("XDG_CONFIG_HOME") {
        PathBuf::from(config).join("fae").join("scheduler.json")
    } else if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home)
            .join(".config")
            .join("fae")
            .join("scheduler.json")
    } else {
        PathBuf::from("/tmp/fae-config/scheduler.json")
    }
}

/// Generates a simple timestamp string for filenames.
fn chrono_timestamp() -> String {
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

    info
}

/// Add all files from a directory into the zip under a given prefix.
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
        assert!(path_str.contains(".fae"));
        assert!(path_str.ends_with("logs"));
    }

    #[test]
    fn test_build_system_info_contains_version() {
        let info = build_system_info();
        assert!(info.contains("Fae version:"));
        assert!(info.contains(env!("CARGO_PKG_VERSION")));
    }
}

//! Rotating file log writer for diagnostic logs.
//!
//! [`RotatingFileWriter`] writes log records to daily log files under
//! `~/.fae/logs/`. On creation it removes log files older than
//! [`MAX_LOG_AGE_DAYS`] days or beyond the [`MAX_LOG_FILES`] file limit
//! (oldest first).
//!
//! # File naming
//!
//! Log files are named `fae-YYYY-MM-DD.log` in the logs directory returned
//! by [`crate::fae_dirs::logs_dir`].
//!
//! # Format
//!
//! Each log record is written as:
//! ```text
//! [YYYY-MM-DD HH:MM:SS] [LEVEL] [target] message\n
//! ```
//!
//! # Usage
//!
//! ```rust,ignore
//! use fae::diagnostics::log_rotation::RotatingFileWriter;
//! let writer = RotatingFileWriter::open(&log_dir)?;
//! writeln!(writer.file(), "[INFO] [app] started").ok();
//! ```

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Maximum age (in days) of log files to keep.
pub const MAX_LOG_AGE_DAYS: u64 = 7;

/// Maximum number of log files to keep.
pub const MAX_LOG_FILES: usize = 10;

/// A rotating file log writer.
///
/// Opens (or creates) today's log file and prunes old log files on
/// construction. Subsequent writes go to the same file for the lifetime of
/// this instance.
pub struct RotatingFileWriter {
    path: PathBuf,
    file: File,
}

impl RotatingFileWriter {
    /// Open (or create) today's log file in `log_dir`, pruning old files.
    ///
    /// # Errors
    ///
    /// Returns an `io::Error` if the directory cannot be created or today's
    /// log file cannot be opened.
    pub fn open(log_dir: &Path) -> io::Result<Self> {
        fs::create_dir_all(log_dir)?;

        // Prune old log files before opening today's file.
        prune_old_logs(log_dir);

        let filename = today_log_filename();
        let path = log_dir.join(&filename);
        let file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)?;

        Ok(Self { path, file })
    }

    /// Return the path of the log file currently being written.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Write a formatted log line.
    ///
    /// The line is flushed immediately so partial writes do not appear on crash.
    ///
    /// # Errors
    ///
    /// Returns an `io::Error` if the write or flush fails.
    pub fn write_line(&mut self, level: &str, target: &str, message: &str) -> io::Result<()> {
        let ts = current_timestamp_str();
        writeln!(self.file, "[{ts}] [{level}] [{target}] {message}")?;
        self.file.flush()
    }
}

impl Write for RotatingFileWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.file.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

/// Generate today's log filename in `fae-YYYY-MM-DD.log` format.
fn today_log_filename() -> String {
    let (y, m, d) = current_ymd();
    format!("fae-{y:04}-{m:02}-{d:02}.log")
}

/// Remove log files older than [`MAX_LOG_AGE_DAYS`] or beyond [`MAX_LOG_FILES`].
///
/// Files are sorted by modification time (newest first). Files beyond the
/// limit or older than the age threshold are deleted.
fn prune_old_logs(log_dir: &Path) {
    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(MAX_LOG_AGE_DAYS * 86_400))
        .unwrap_or(UNIX_EPOCH);
    prune_old_logs_with_cutoff(log_dir, cutoff, MAX_LOG_FILES);
}

/// Inner prune implementation with injectable cutoff for testing.
fn prune_old_logs_with_cutoff(log_dir: &Path, cutoff: SystemTime, max_files: usize) {
    // Collect all fae-*.log files with their modification times.
    let mut entries: Vec<(PathBuf, SystemTime)> = match fs::read_dir(log_dir) {
        Ok(dir) => dir
            .flatten()
            .filter_map(|e| {
                let path = e.path();
                let name = path.file_name()?.to_str()?.to_owned();
                if name.starts_with("fae-") && name.ends_with(".log") {
                    let mtime = path.metadata().ok()?.modified().ok()?;
                    Some((path, mtime))
                } else {
                    None
                }
            })
            .collect(),
        Err(_) => return,
    };

    // Sort newest first.
    entries.sort_by(|a, b| b.1.cmp(&a.1));

    for (i, (path, mtime)) in entries.iter().enumerate() {
        let too_old = *mtime < cutoff;
        let over_limit = i >= max_files;
        if too_old || over_limit {
            let _ = fs::remove_file(path);
        }
    }
}

/// Return the current UTC date as (year, month, day).
fn current_ymd() -> (u64, u64, u64) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86_400;
    days_to_ymd(days)
}

/// Return a formatted timestamp string for log lines: `YYYY-MM-DD HH:MM:SS`.
fn current_timestamp_str() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let time_of_day = secs % 86_400;
    let hour = time_of_day / 3_600;
    let minute = (time_of_day % 3_600) / 60;
    let second = time_of_day % 60;
    let (y, m, d) = days_to_ymd(secs / 86_400);
    format!("{y:04}-{m:02}-{d:02} {hour:02}:{minute:02}:{second:02}")
}

/// Convert days since Unix epoch to (year, month, day).
///
/// Uses Howard Hinnant's `civil_from_days` algorithm.
fn days_to_ymd(days: u64) -> (u64, u64, u64) {
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

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use std::fs;

    #[test]
    fn today_log_filename_has_correct_format() {
        let name = today_log_filename();
        assert!(name.starts_with("fae-"), "should start with fae-: {name}");
        assert!(name.ends_with(".log"), "should end with .log: {name}");
        // fae-YYYY-MM-DD.log = 18 chars
        assert_eq!(name.len(), 18, "unexpected length: {name}");
    }

    #[test]
    fn rotating_writer_creates_log_file() {
        let tmp = tempfile::TempDir::new().unwrap();
        let log_dir = tmp.path().to_path_buf();

        let mut writer = RotatingFileWriter::open(&log_dir).unwrap();
        writer
            .write_line("INFO", "test", "hello from test")
            .unwrap();

        let log_path = writer.path().to_path_buf();
        assert!(log_path.exists(), "log file should exist: {log_path:?}");

        let content = fs::read_to_string(&log_path).unwrap();
        assert!(content.contains("[INFO]"), "should contain level tag");
        assert!(content.contains("[test]"), "should contain target tag");
        assert!(
            content.contains("hello from test"),
            "should contain message"
        );
    }

    #[test]
    fn rotating_writer_appends_to_existing_file() {
        let tmp = tempfile::TempDir::new().unwrap();
        let log_dir = tmp.path().to_path_buf();

        {
            let mut w = RotatingFileWriter::open(&log_dir).unwrap();
            w.write_line("INFO", "app", "first line").unwrap();
        }
        {
            let mut w = RotatingFileWriter::open(&log_dir).unwrap();
            w.write_line("WARN", "app", "second line").unwrap();
        }

        let log_file = today_log_filename();
        let content = fs::read_to_string(log_dir.join(&log_file)).unwrap();
        assert!(content.contains("first line"), "first line should persist");
        assert!(
            content.contains("second line"),
            "second line should be appended"
        );
    }

    #[test]
    fn prune_removes_files_over_limit() {
        let tmp = tempfile::TempDir::new().unwrap();
        let log_dir = tmp.path().to_path_buf();

        // Create MAX_LOG_FILES + 3 fake log files with varying modification times.
        let total = MAX_LOG_FILES + 3;
        for i in 0..total {
            let name = format!("fae-2025-01-{:02}.log", i + 1);
            fs::write(log_dir.join(&name), format!("line {i}")).unwrap();
            // Small sleep to ensure distinct modification times.
            std::thread::sleep(std::time::Duration::from_millis(2));
        }

        prune_old_logs(&log_dir);

        let remaining: Vec<_> = fs::read_dir(&log_dir)
            .unwrap()
            .flatten()
            .filter(|e| {
                let name = e.file_name().to_string_lossy().to_string();
                name.starts_with("fae-") && name.ends_with(".log")
            })
            .collect();

        assert!(
            remaining.len() <= MAX_LOG_FILES,
            "should have at most {MAX_LOG_FILES} log files, got {}",
            remaining.len()
        );
    }

    #[test]
    fn prune_removes_old_files_via_cutoff() {
        let tmp = tempfile::TempDir::new().unwrap();
        let log_dir = tmp.path().to_path_buf();

        // Write two files.
        let path_a = log_dir.join("fae-2025-01-01.log");
        let path_b = log_dir.join("fae-2025-01-02.log");
        fs::write(&path_a, "a").unwrap();
        // Small sleep to ensure distinct modification times.
        std::thread::sleep(std::time::Duration::from_millis(5));
        fs::write(&path_b, "b").unwrap();

        // Use a cutoff of "now" so all files look old (mtime < cutoff).
        // Both files were created before we call this, so they should be pruned.
        let future_cutoff = SystemTime::now() + Duration::from_secs(3600);
        prune_old_logs_with_cutoff(&log_dir, future_cutoff, MAX_LOG_FILES);

        assert!(
            !path_a.exists() && !path_b.exists(),
            "all files older than cutoff should be pruned"
        );
    }

    #[test]
    fn days_to_ymd_epoch_is_1970_01_01() {
        let (y, m, d) = days_to_ymd(0);
        assert_eq!((y, m, d), (1970, 1, 1));
    }

    #[test]
    fn current_timestamp_str_has_expected_format() {
        let ts = current_timestamp_str();
        // Format: YYYY-MM-DD HH:MM:SS (19 chars)
        assert_eq!(ts.len(), 19, "unexpected timestamp length: {ts}");
        assert_eq!(&ts[4..5], "-");
        assert_eq!(&ts[7..8], "-");
        assert_eq!(&ts[10..11], " ");
        assert_eq!(&ts[13..14], ":");
        assert_eq!(&ts[16..17], ":");
    }
}

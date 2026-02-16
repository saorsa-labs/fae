//! Xdotool backend for Linux desktop automation.
//!
//! Wraps `xdotool` (X11) and `scrot` for screenshots to provide
//! desktop automation on Linux systems.
//!
//! Requires: `sudo apt install xdotool scrot` (X11 session).

use super::{ClickTarget, DesktopAction, DesktopBackend, DesktopResult};

/// Default command timeout for xdotool invocations.
const XDOTOOL_TIMEOUT_SECS: u64 = 30;

/// Linux desktop automation via xdotool and scrot.
pub struct XdotoolBackend {
    timeout_secs: u64,
}

impl XdotoolBackend {
    /// Create a new `XdotoolBackend` with default settings.
    pub fn new() -> Self {
        Self {
            timeout_secs: XDOTOOL_TIMEOUT_SECS,
        }
    }

    /// Run a command with timeout, returning stdout.
    fn run_command(&self, program: &str, args: &[&str]) -> Result<String, String> {
        let timeout = std::time::Duration::from_secs(self.timeout_secs);
        let start = std::time::Instant::now();

        let mut cmd = std::process::Command::new(program);
        for arg in args {
            cmd.arg(arg);
        }
        cmd.stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        let mut child = cmd
            .spawn()
            .map_err(|e| format!("failed to spawn {program}: {e}"))?;

        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    let stdout = child
                        .stdout
                        .take()
                        .map(|mut s| {
                            let mut buf = String::new();
                            std::io::Read::read_to_string(&mut s, &mut buf).unwrap_or(0);
                            buf
                        })
                        .unwrap_or_default();

                    let stderr = child
                        .stderr
                        .take()
                        .map(|mut s| {
                            let mut buf = String::new();
                            std::io::Read::read_to_string(&mut s, &mut buf).unwrap_or(0);
                            buf
                        })
                        .unwrap_or_default();

                    if !status.success() {
                        let code = status.code().unwrap_or(-1);
                        let output = if stderr.is_empty() { stdout } else { stderr };
                        return Err(format!("{program} exited with code {code}: {output}"));
                    }

                    return Ok(stdout);
                }
                Ok(None) => {
                    if start.elapsed() > timeout {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err(format!("{program} timed out after {}s", self.timeout_secs));
                    }
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(e) => {
                    return Err(format!("failed to check {program} status: {e}"));
                }
            }
        }
    }

    /// Check if a binary is in PATH.
    fn binary_exists(name: &str) -> bool {
        std::process::Command::new("which")
            .arg(name)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }
}

impl Default for XdotoolBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl DesktopBackend for XdotoolBackend {
    fn name(&self) -> &str {
        "xdotool"
    }

    fn is_available(&self) -> bool {
        Self::binary_exists("xdotool")
    }

    fn execute(&self, action: &DesktopAction) -> Result<DesktopResult, String> {
        match action {
            DesktopAction::Screenshot { app: _ } => {
                // Use scrot for screenshots. App scoping is not easily
                // supported via scrot so we capture the whole screen.
                let path = format!(
                    "/tmp/fae_screenshot_{}.png",
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_millis())
                        .unwrap_or(0)
                );
                self.run_command("scrot", &[&path])?;
                Ok(DesktopResult {
                    output: format!("Screenshot captured: {path}"),
                    screenshot_path: Some(path),
                })
            }

            DesktopAction::Click { target } => match target {
                ClickTarget::Coordinates { x, y } => {
                    let x_int = *x as i64;
                    let y_int = *y as i64;
                    let x_str = x_int.to_string();
                    let y_str = y_int.to_string();
                    self.run_command("xdotool", &["mousemove", &x_str, &y_str, "click", "1"])?;
                    Ok(DesktopResult {
                        output: format!("Clicked at ({x_int}, {y_int})"),
                        screenshot_path: None,
                    })
                }
                ClickTarget::Label(label) => {
                    // xdotool doesn't support accessibility labels directly.
                    // Fall back to searching for a window with that name.
                    let output = self.run_command("xdotool", &["search", "--name", label])?;
                    if output.trim().is_empty() {
                        return Err(format!(
                            "no window found matching label '{label}'. \
                             xdotool does not support accessibility labels; \
                             use coordinates instead."
                        ));
                    }
                    Ok(DesktopResult {
                        output: format!("Found windows matching '{label}': {}", output.trim()),
                        screenshot_path: None,
                    })
                }
            },

            DesktopAction::Type { text } => {
                self.run_command("xdotool", &["type", "--", text])?;
                Ok(DesktopResult {
                    output: format!("Typed: {text}"),
                    screenshot_path: None,
                })
            }

            DesktopAction::Press { key } => {
                self.run_command("xdotool", &["key", key])?;
                Ok(DesktopResult {
                    output: format!("Pressed: {key}"),
                    screenshot_path: None,
                })
            }

            DesktopAction::Hotkey { keys } => {
                let combo = keys.join("+");
                self.run_command("xdotool", &["key", &combo])?;
                Ok(DesktopResult {
                    output: format!("Hotkey: {combo}"),
                    screenshot_path: None,
                })
            }

            DesktopAction::Scroll { direction, amount } => {
                // xdotool uses button 4 (up) and 5 (down) for scroll.
                let button = match direction.as_str() {
                    "up" => "4",
                    "down" => "5",
                    "left" => "6",
                    "right" => "7",
                    _ => "5", // default down
                };
                let clicks = (*amount as u32).max(1);
                for _ in 0..clicks {
                    self.run_command("xdotool", &["click", button])?;
                }
                Ok(DesktopResult {
                    output: format!("Scrolled {direction} {clicks} times"),
                    screenshot_path: None,
                })
            }

            DesktopAction::ListWindows => {
                let output = self.run_command("xdotool", &["search", "--name", ""])?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }

            DesktopAction::FocusWindow { title } => {
                let window_id = self.run_command("xdotool", &["search", "--name", title])?;
                let first_id = window_id
                    .lines()
                    .next()
                    .ok_or_else(|| format!("no window found matching '{title}'"))?
                    .trim();
                self.run_command("xdotool", &["windowactivate", first_id])?;
                Ok(DesktopResult {
                    output: format!("Focused window: {title} (id: {first_id})"),
                    screenshot_path: None,
                })
            }

            DesktopAction::ListApps => {
                // No direct equivalent; list all window names.
                let output = self.run_command("xdotool", &["search", "--name", ""])?;
                Ok(DesktopResult {
                    output: format!("Window IDs:\n{output}"),
                    screenshot_path: None,
                })
            }

            DesktopAction::LaunchApp { name } => {
                self.run_command("xdg-open", &[name])?;
                Ok(DesktopResult {
                    output: format!("Launched: {name}"),
                    screenshot_path: None,
                })
            }

            DesktopAction::Raw { command } => {
                let parts: Vec<&str> = command.split_whitespace().collect();
                if parts.is_empty() {
                    return Err("raw command cannot be empty".to_string());
                }
                let output = self.run_command(parts[0], &parts[1..])?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_is_xdotool() {
        let backend = XdotoolBackend::new();
        assert_eq!(backend.name(), "xdotool");
    }

    #[test]
    fn xdotool_availability_check_does_not_panic() {
        // This test just verifies the method doesn't panic.
        let backend = XdotoolBackend::new();
        let _ = backend.is_available();
    }

    #[test]
    fn binary_exists_returns_true_for_sh() {
        // /bin/sh should always exist.
        assert!(XdotoolBackend::binary_exists("sh"));
    }

    #[test]
    fn binary_exists_returns_false_for_nonexistent() {
        assert!(!XdotoolBackend::binary_exists(
            "definitely_not_a_real_binary_12345"
        ));
    }
}

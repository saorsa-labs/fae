//! Peekaboo backend for macOS desktop automation.
//!
//! Wraps the [`peekaboo`](https://github.com/steipete/Peekaboo) CLI tool
//! to provide screenshots, accessibility-based clicks, typing, and window
//! management on macOS.
//!
//! Requires: `brew install steipete/tap/peekaboo` + Accessibility permission.

use super::{ClickTarget, DesktopAction, DesktopBackend, DesktopResult};

/// Default command timeout for Peekaboo invocations.
const PEEKABOO_TIMEOUT_SECS: u64 = 30;

/// macOS desktop automation via the Peekaboo CLI.
pub struct PeekabooBackend {
    timeout_secs: u64,
}

impl PeekabooBackend {
    /// Create a new `PeekabooBackend` with default settings.
    pub fn new() -> Self {
        Self {
            timeout_secs: PEEKABOO_TIMEOUT_SECS,
        }
    }

    /// Build a `std::process::Command` for a peekaboo invocation.
    fn build_command(args: &[&str]) -> std::process::Command {
        let mut cmd = std::process::Command::new("peekaboo");
        for arg in args {
            cmd.arg(arg);
        }
        cmd.stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        cmd
    }

    /// Run a command with timeout, returning combined stdout/stderr.
    fn run_command(&self, mut cmd: std::process::Command) -> Result<String, String> {
        let timeout = std::time::Duration::from_secs(self.timeout_secs);
        let start = std::time::Instant::now();

        let mut child = cmd
            .spawn()
            .map_err(|e| format!("failed to spawn peekaboo: {e}"))?;

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
                        return Err(format!("peekaboo exited with code {code}: {output}"));
                    }

                    return Ok(stdout);
                }
                Ok(None) => {
                    if start.elapsed() > timeout {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err(format!("peekaboo timed out after {}s", self.timeout_secs));
                    }
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(e) => {
                    return Err(format!("failed to check peekaboo status: {e}"));
                }
            }
        }
    }
}

impl Default for PeekabooBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl DesktopBackend for PeekabooBackend {
    fn name(&self) -> &str {
        "peekaboo"
    }

    fn is_available(&self) -> bool {
        std::process::Command::new("which")
            .arg("peekaboo")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    fn execute(&self, action: &DesktopAction) -> Result<DesktopResult, String> {
        match action {
            DesktopAction::Screenshot { app } => {
                let mut args = vec!["see", "--format", "json"];
                // Peekaboo's `see` can scope to an app.
                let app_owned;
                if let Some(name) = app {
                    app_owned = name.clone();
                    args.push("--app");
                    args.push(&app_owned);
                }
                let cmd = Self::build_command(&args);
                let output = self.run_command(cmd)?;
                // Peekaboo outputs JSON with screenshot path in the response.
                Ok(DesktopResult {
                    output,
                    screenshot_path: None, // path is in the JSON output
                })
            }

            DesktopAction::Click { target } => match target {
                ClickTarget::Label(label) => {
                    let cmd = Self::build_command(&["click", "--label", label, "--format", "json"]);
                    let output = self.run_command(cmd)?;
                    Ok(DesktopResult {
                        output,
                        screenshot_path: None,
                    })
                }
                ClickTarget::Coordinates { x, y } => {
                    let x_str = x.to_string();
                    let y_str = y.to_string();
                    let cmd = Self::build_command(&[
                        "click", "--x", &x_str, "--y", &y_str, "--format", "json",
                    ]);
                    let output = self.run_command(cmd)?;
                    Ok(DesktopResult {
                        output,
                        screenshot_path: None,
                    })
                }
            },

            DesktopAction::Type { text } => {
                let cmd = Self::build_command(&["type", text]);
                let output = self.run_command(cmd)?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }

            DesktopAction::Press { key } => {
                let cmd = Self::build_command(&["press", key]);
                let output = self.run_command(cmd)?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }

            DesktopAction::Hotkey { keys } => {
                let combo = keys.join("+");
                let cmd = Self::build_command(&["hotkey", &combo]);
                let output = self.run_command(cmd)?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }

            DesktopAction::Scroll { direction, amount } => {
                let amount_str = amount.to_string();
                let cmd = Self::build_command(&[
                    "scroll",
                    "--direction",
                    direction,
                    "--amount",
                    &amount_str,
                ]);
                let output = self.run_command(cmd)?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }

            DesktopAction::ListWindows => {
                let cmd = Self::build_command(&["window", "list", "--format", "json"]);
                let output = self.run_command(cmd)?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }

            DesktopAction::FocusWindow { title } => {
                let cmd = Self::build_command(&["window", "focus", "--title", title]);
                let output = self.run_command(cmd)?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }

            DesktopAction::ListApps => {
                let cmd = Self::build_command(&["app", "list", "--format", "json"]);
                let output = self.run_command(cmd)?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }

            DesktopAction::LaunchApp { name } => {
                let cmd = Self::build_command(&["app", "launch", name]);
                let output = self.run_command(cmd)?;
                Ok(DesktopResult {
                    output,
                    screenshot_path: None,
                })
            }

            DesktopAction::Raw { command } => {
                // Split the raw command into arguments for peekaboo.
                let parts: Vec<&str> = command.split_whitespace().collect();
                if parts.is_empty() {
                    return Err("raw command cannot be empty".to_string());
                }
                let cmd = Self::build_command(&parts);
                let output = self.run_command(cmd)?;
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
    fn name_is_peekaboo() {
        let backend = PeekabooBackend::new();
        assert_eq!(backend.name(), "peekaboo");
    }

    #[test]
    fn peekaboo_not_installed_returns_false_or_true() {
        // This test just verifies the method doesn't panic.
        // The result depends on whether peekaboo is actually installed.
        let backend = PeekabooBackend::new();
        let _ = backend.is_available();
    }

    #[test]
    fn action_to_command_screenshot() {
        // Verify command construction without executing.
        let cmd = PeekabooBackend::build_command(&["see", "--format", "json"]);
        let program = cmd.get_program().to_str().unwrap_or("");
        assert_eq!(program, "peekaboo");
        let args: Vec<&str> = cmd.get_args().filter_map(|a| a.to_str()).collect();
        assert_eq!(args, vec!["see", "--format", "json"]);
    }

    #[test]
    fn action_to_command_click_label() {
        let cmd = PeekabooBackend::build_command(&["click", "--label", "OK", "--format", "json"]);
        let args: Vec<&str> = cmd.get_args().filter_map(|a| a.to_str()).collect();
        assert_eq!(args, vec!["click", "--label", "OK", "--format", "json"]);
    }

    #[test]
    fn action_to_command_click_coordinates() {
        let cmd = PeekabooBackend::build_command(&[
            "click", "--x", "100", "--y", "200", "--format", "json",
        ]);
        let args: Vec<&str> = cmd.get_args().filter_map(|a| a.to_str()).collect();
        assert_eq!(
            args,
            vec!["click", "--x", "100", "--y", "200", "--format", "json"]
        );
    }

    #[test]
    fn action_to_command_type() {
        let cmd = PeekabooBackend::build_command(&["type", "hello"]);
        let args: Vec<&str> = cmd.get_args().filter_map(|a| a.to_str()).collect();
        assert_eq!(args, vec!["type", "hello"]);
    }

    #[test]
    fn action_to_command_hotkey() {
        let cmd = PeekabooBackend::build_command(&["hotkey", "cmd+shift+s"]);
        let args: Vec<&str> = cmd.get_args().filter_map(|a| a.to_str()).collect();
        assert_eq!(args, vec!["hotkey", "cmd+shift+s"]);
    }

    #[test]
    fn action_to_command_window_list() {
        let cmd = PeekabooBackend::build_command(&["window", "list", "--format", "json"]);
        let args: Vec<&str> = cmd.get_args().filter_map(|a| a.to_str()).collect();
        assert_eq!(args, vec!["window", "list", "--format", "json"]);
    }

    #[test]
    fn action_to_command_window_focus() {
        let cmd = PeekabooBackend::build_command(&["window", "focus", "--title", "Terminal"]);
        let args: Vec<&str> = cmd.get_args().filter_map(|a| a.to_str()).collect();
        assert_eq!(args, vec!["window", "focus", "--title", "Terminal"]);
    }

    #[test]
    fn action_to_command_app_launch() {
        let cmd = PeekabooBackend::build_command(&["app", "launch", "Safari"]);
        let args: Vec<&str> = cmd.get_args().filter_map(|a| a.to_str()).collect();
        assert_eq!(args, vec!["app", "launch", "Safari"]);
    }

    #[test]
    fn action_to_command_app_list() {
        let cmd = PeekabooBackend::build_command(&["app", "list", "--format", "json"]);
        let args: Vec<&str> = cmd.get_args().filter_map(|a| a.to_str()).collect();
        assert_eq!(args, vec!["app", "list", "--format", "json"]);
    }
}

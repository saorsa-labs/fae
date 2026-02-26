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

/// Parse `xdotool getwindowgeometry` output and return the window center `(x, y)`.
///
/// Expected format:
/// ```text
/// Window 12345
///   Position: 100,200 (screen: 0)
///   Geometry: 800x600
/// ```
///
/// Center is `(pos_x + width / 2, pos_y + height / 2)`.
fn parse_window_geometry(output: &str) -> Result<(i64, i64), String> {
    let mut pos_x: Option<i64> = None;
    let mut pos_y: Option<i64> = None;
    let mut width: Option<i64> = None;
    let mut height: Option<i64> = None;

    for line in output.lines() {
        let trimmed = line.trim();

        if let Some(rest) = trimmed.strip_prefix("Position:") {
            // "100,200 (screen: 0)"
            let coords_part = rest.trim().split_whitespace().next().unwrap_or("");
            let mut parts = coords_part.split(',');
            pos_x = parts.next().and_then(|s| s.trim().parse().ok());
            pos_y = parts.next().and_then(|s| s.trim().parse().ok());
        } else if let Some(rest) = trimmed.strip_prefix("Geometry:") {
            // "800x600"
            let size_part = rest.trim();
            let mut parts = size_part.split('x');
            width = parts.next().and_then(|s| s.trim().parse().ok());
            height = parts.next().and_then(|s| s.trim().parse().ok());
        }
    }

    let px = pos_x.ok_or("missing Position in geometry output")?;
    let py = pos_y.ok_or("missing Position y-coordinate in geometry output")?;
    let w = width.ok_or("missing Geometry width in geometry output")?;
    let h = height.ok_or("missing Geometry height in geometry output")?;

    Ok((px + w / 2, py + h / 2))
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
            && Self::binary_exists("scrot")
            && Self::binary_exists("xdg-open")
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
                    // Fall back to searching for a window with that name and
                    // clicking the center of the first match.
                    let output = self.run_command("xdotool", &["search", "--name", label])?;
                    let first_id = output
                        .lines()
                        .next()
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .ok_or_else(|| {
                            format!(
                                "no window found matching label '{label}'. \
                                 xdotool does not support accessibility labels; \
                                 use coordinates instead."
                            )
                        })?;

                    // Get geometry so we can click the window center.
                    let geom_output =
                        self.run_command("xdotool", &["getwindowgeometry", first_id])?;
                    let (cx, cy) = parse_window_geometry(&geom_output).map_err(|e| {
                        format!("failed to parse geometry for window {first_id}: {e}")
                    })?;

                    let cx_str = cx.to_string();
                    let cy_str = cy.to_string();

                    self.run_command("xdotool", &["windowactivate", first_id])?;
                    self.run_command("xdotool", &["mousemove", &cx_str, &cy_str, "click", "1"])?;

                    Ok(DesktopResult {
                        output: format!(
                            "Clicked window '{label}' (id: {first_id}) at ({cx}, {cy})"
                        ),
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

    // ── Geometry parsing tests ──────────────────────────────────

    #[test]
    fn parse_window_geometry_valid() {
        let output = "Window 12345\n  Position: 100,200 (screen: 0)\n  Geometry: 800x600\n";
        let result = parse_window_geometry(output);
        assert!(result.is_ok());
        let (cx, cy) = match result {
            Ok(v) => v,
            Err(_) => unreachable!("should parse valid geometry"),
        };
        // center = (100 + 800/2, 200 + 600/2) = (500, 500)
        assert_eq!(cx, 500);
        assert_eq!(cy, 500);
    }

    #[test]
    fn parse_window_geometry_asymmetric() {
        let output = "Window 99\n  Position: 0,0 (screen: 0)\n  Geometry: 1920x1080\n";
        let (cx, cy) = match parse_window_geometry(output) {
            Ok(v) => v,
            Err(_) => unreachable!("should parse valid geometry"),
        };
        assert_eq!(cx, 960);
        assert_eq!(cy, 540);
    }

    #[test]
    fn parse_window_geometry_offset_position() {
        let output = "Window 42\n  Position: 50,75 (screen: 0)\n  Geometry: 100x200\n";
        let (cx, cy) = match parse_window_geometry(output) {
            Ok(v) => v,
            Err(_) => unreachable!("should parse valid geometry"),
        };
        // center = (50 + 100/2, 75 + 200/2) = (100, 175)
        assert_eq!(cx, 100);
        assert_eq!(cy, 175);
    }

    #[test]
    fn parse_window_geometry_missing_position() {
        let output = "Window 12345\n  Geometry: 800x600\n";
        assert!(parse_window_geometry(output).is_err());
    }

    #[test]
    fn parse_window_geometry_missing_geometry() {
        let output = "Window 12345\n  Position: 100,200 (screen: 0)\n";
        assert!(parse_window_geometry(output).is_err());
    }

    #[test]
    fn parse_window_geometry_empty_input() {
        assert!(parse_window_geometry("").is_err());
    }

    #[test]
    fn parse_window_geometry_malformed_coords() {
        let output = "Window 12345\n  Position: abc,def (screen: 0)\n  Geometry: 800x600\n";
        assert!(parse_window_geometry(output).is_err());
    }
}

//! Damage-control: a coarse denylist of obviously-catastrophic shell commands.
//!
//! This is NOT a sandbox. It is the "obviously catastrophic" filter the Fae
//! policy hook enforces ahead of `bash` execution. The real sandbox is the
//! (future) OS-level isolation in fluers (seatbelt/landlock); until then this
//! layer + `LocalSessionEnv` containment + the control-plane scope gate are the
//! pre-execution defenses.
//!
//! Keep the patterns conservative: prefer false-negatives (let a command
//! through to fluers' own containment) over false-positives (block legitimate
//! work). The `bash` tool already requires `tool.execute_dangerous` scope,
//! which — without A3's confirmation channel — maps to `Deny` (the `Confirm`
//! trap, see [`crate::toolhost::policy`]). This layer catches the accidental
//! `rm -rf /` before it ever reaches that gate.

/// True if `command` matches a known-catastrophic pattern.
///
/// Checked case-insensitively against the raw command string. Intentionally
/// coarse: a determined adversary can evade a denylist. The defense-in-depth is
/// that dangerous commands also require confirmation (absent until A3), so this
/// is the "belt" to that "suspenders".
#[must_use]
pub fn is_catastrophic_command(command: &str) -> bool {
    let lower = command.to_ascii_lowercase();
    // Substring patterns. Order is not significant. Each is chosen to be
    // high-signal (catastrophic + rare as a substring of a benign command).
    const PATTERNS: &[&str] = &[
        // Recursive force-delete of the root (NOT `./x` — the char after
        // `rm -rf ` must be `/`).
        "rm -rf /",
        "rm -rf /*",
        // Fork bomb.
        ":(){:|:&};:",
        // Filesystem format = wiping a block device.
        "mkfs",
        // Raw writes to whole-disk device nodes.
        "dd of=/dev/sd",
        "dd of=/dev/nvme",
        "dd of=/dev/disk",
        "dd if=/dev/zero of=/dev/",
        // Redirect-overwrite a whole-disk device.
        "> /dev/sd",
        // Root-wide permission nuke.
        "chmod -r 777 /",
        // Host power state.
        "shutdown",
        "poweroff",
        "halt",
        "reboot",
        "init 0",
    ];
    PATTERNS.iter().any(|p| lower.contains(p))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_recursive_force_root_delete() {
        assert!(is_catastrophic_command("rm -rf /"));
        assert!(is_catastrophic_command("sudo rm -rf /"));
        assert!(is_catastrophic_command("RM -RF /etc")); // case-insensitive
    }

    #[test]
    fn flags_fork_bomb_and_mkfs_and_device_write() {
        assert!(is_catastrophic_command(":(){:|:&};:"));
        assert!(is_catastrophic_command("mkfs.ext4 /dev/sda1"));
        assert!(is_catastrophic_command("dd if=/dev/zero of=/dev/sda bs=1M"));
        assert!(is_catastrophic_command("chmod -R 777 /"));
    }

    #[test]
    fn allows_benign_and_scoped_commands() {
        assert!(!is_catastrophic_command("ls -la"));
        assert!(!is_catastrophic_command("echo hello"));
        assert!(!is_catastrophic_command("cargo build --release"));
        // Scoped delete: `./target` does not contain `rm -rf /`.
        assert!(!is_catastrophic_command("rm -rf ./target/debug/artifact"));
        // `~/projects` does not trip the root-delete patterns.
        assert!(!is_catastrophic_command("rm -rf ~/projects/old"));
    }
}

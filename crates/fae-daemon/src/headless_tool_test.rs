//! Headless ToolHost + SkillHost execution proof (Phase C).
//!
//! The Phase C gate: *"a Linux daemon build actually executes read/write/edit/
//! bash + a run_skill end-to-end, through the governed host, proven headlessly
//! in ci-linux.yml."* This driver builds the SAME governed [`ToolHost`] the
//! `toolhost.set_root` protocol path builds, then, WITHOUT a socket or a model:
//!
//! 1. **Host tier** (owner-interactive origin): write → read → edit → bash, each
//!    through [`ToolHost::execute_governed`], asserting the tool output and that
//!    fail-closed mutation receipts landed in the conductor store.
//! 2. **Jailed tier** (a non-interactive origin that *requires* the OS jail):
//!    a write INSIDE the root succeeds; a write OUTSIDE the root is REJECTED by
//!    the OS sandbox (Landlock on Linux, seatbelt on macOS) — proving the jail
//!    actually confines, not just the path policy. Fails closed (nonzero exit)
//!    if no jail backend is available on the running kernel.
//! 3. **Skill half**: SkillHost discovers → activates → `prepare_run`s the
//!    `ci-proof` fixture skill, then routes its `uv run --script …` command
//!    through the governed bash path under the jail and asserts the deterministic
//!    marker survives.
//!
//! Every step prints a `PASS`/`FAIL` line; the process exits 0 only if all pass.
//! It is a dev/CI harness (never a production launch path) — assertions may use
//! plain error returns that bubble to a nonzero exit.

use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use fae_control_plane::{ClientClass, ClientRecord, Scope};
use fluers_core::tool::ToolResult;
use fluers_runtime::Limits;
use serde_json::{json, Value};
use tokio_util::sync::CancellationToken;

use crate::conductor::ConductorStore;
use crate::skillhost::audit::ConductorStoreSkillAudit;
use crate::skillhost::SkillHost;
use crate::toolhost::confirm::{ConfirmReply, ConfirmRequest, ToolConfirmation};
use crate::toolhost::isolation::{jail_backend_available, ToolOrigin};
use crate::toolhost::{ToolHost, ToolHostRequest};

/// The deterministic marker `scripts/hello.py` prints (kept in sync with the
/// `ci-proof` fixture).
const SKILL_MARKER: &str = "CI-PROOF-SKILL-OK-7f3a2b";

/// Parsed `--headless-tool-test` arguments.
pub struct HeadlessToolTestArgs {
    /// Directory CONTAINING skill subdirectories (e.g. `.../test-fixtures/skills`).
    /// The `ci-proof` fixture must live directly beneath it.
    pub skills_dir: PathBuf,
}

impl HeadlessToolTestArgs {
    /// Parse from a raw args iterator (everything after `--headless-tool-test`).
    /// The sole required flag is `--skills <dir>`.
    pub fn parse(mut args: impl Iterator<Item = String>) -> Result<HeadlessToolTestArgs, String> {
        let mut skills_dir: Option<PathBuf> = None;
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--skills" => {
                    skills_dir = Some(PathBuf::from(
                        args.next().ok_or("--skills requires a directory")?,
                    ));
                }
                other => return Err(format!("unknown --headless-tool-test arg: {other}")),
            }
        }
        Ok(HeadlessToolTestArgs {
            skills_dir: skills_dir.ok_or("--headless-tool-test requires --skills <dir>")?,
        })
    }
}

/// An auto-approving confirmation channel for the harness. The point of this
/// driver is to prove the EXECUTION path (governance → isolation → tool → receipt)
/// on the running kernel; the owner-confirmation round-trip is exercised by the
/// unit/protocol tests. Every catastrophic-op deny still fires BEFORE the confirm
/// is reached, so auto-approve cannot bypass the damage-control gate.
struct AutoApprove;

#[async_trait]
impl ToolConfirmation for AutoApprove {
    async fn confirm(&self, _req: &ConfirmRequest) -> ConfirmReply {
        ConfirmReply::Approved
    }
}

fn pass(step: &str) {
    println!("[headless-tool-test] PASS  {step}");
}

fn check(cond: bool, step: &str, why: &str) -> Result<(), String> {
    if cond {
        pass(step);
        Ok(())
    } else {
        let msg = format!("{step}: {why}");
        eprintln!("[headless-tool-test] FAIL  {msg}");
        Err(msg)
    }
}

/// Concatenate every text content block a tool returned.
fn content_text(out: &ToolResult) -> String {
    out.content
        .iter()
        .filter_map(|v| v.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Extract a bash tool's `exit_code` from its structured details.
fn exit_code(out: &ToolResult) -> Option<i64> {
    out.details
        .as_ref()
        .and_then(|d| d.get("exit_code"))
        .and_then(Value::as_i64)
}

/// A client holding both tool-execute scopes (owner-equivalent for the harness).
fn harness_client() -> ClientRecord {
    ClientRecord {
        client_id: "headless-tool-test".into(),
        class: ClientClass::TestHarness,
        scopes: [Scope::ToolExecuteSafe, Scope::ToolExecuteDangerous]
            .into_iter()
            .collect(),
        issued_at_ms: 0,
        expires_at_ms: u64::MAX,
        revoked_at_ms: None,
        display_name: "Headless Tool Test".into(),
    }
}

fn req(tool: &str, input: Value, origin: ToolOrigin, call_id: &str) -> ToolHostRequest {
    ToolHostRequest {
        client: harness_client(),
        tool: tool.into(),
        input,
        call_id: call_id.into(),
        cancel: CancellationToken::new(),
        origin,
    }
}

/// Run the full Phase C proof. Returns `Err` on the FIRST failed assertion so the
/// caller exits nonzero; prints a per-step `PASS`/`FAIL` log throughout.
pub async fn run(args: HeadlessToolTestArgs) -> Result<(), String> {
    println!("[headless-tool-test] Phase C governed-execution proof");
    println!(
        "[headless-tool-test] jail backend available: {}",
        jail_backend_available()
    );

    // A non-temp base: the OS jail allows writes under the root AND system temp,
    // so the "outside" probe MUST NOT live in temp or the negative test is void.
    // `CARGO_MANIFEST_DIR/target/...` mirrors the isolation integration test.
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let base = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target")
        .join(format!("headless-tool-test-{nonce}"));
    let root = base.join("root");
    let outside = base.join("outside");
    let store_dir = base.join("store");
    std::fs::create_dir_all(&root).map_err(|e| format!("create root: {e}"))?;
    std::fs::create_dir_all(&outside).map_err(|e| format!("create outside: {e}"))?;
    std::fs::create_dir_all(&store_dir).map_err(|e| format!("create store: {e}"))?;

    let result = run_inner(&args, &root, &outside, &store_dir).await;
    // Best-effort cleanup regardless of outcome.
    let _ = std::fs::remove_dir_all(&base);
    result
}

async fn run_inner(
    args: &HeadlessToolTestArgs,
    root: &std::path::Path,
    outside: &std::path::Path,
    store_dir: &std::path::Path,
) -> Result<(), String> {
    let store = Arc::new(ConductorStore::open(store_dir).map_err(|e| format!("store open: {e}"))?);
    let host = ToolHost::new(root.to_path_buf(), Limits::default(), Arc::clone(&store))
        .await
        .map_err(|e| format!("toolhost build: {e}"))?;
    let confirm = AutoApprove;

    // ── 1. Host tier: write → read → edit → bash (owner-interactive) ──────────
    let owner = ToolOrigin::OwnerInteractive;

    let w = host
        .execute_governed(
            req(
                "write",
                json!({ "path": "hello.txt", "content": "marker-A" }),
                owner,
                "host-write",
            ),
            &confirm,
        )
        .await
        .map_err(|e| format!("host write governed error: {e}"))?;
    check(
        root.join("hello.txt").exists(),
        "host.write",
        "hello.txt not created",
    )?;
    let _ = w;

    let r = host
        .execute_governed(
            req("read", json!({ "path": "hello.txt" }), owner, "host-read"),
            &confirm,
        )
        .await
        .map_err(|e| format!("host read governed error: {e}"))?;
    check(
        content_text(&r.output).contains("marker-A"),
        "host.read",
        "read did not return the written content",
    )?;

    let e = host
        .execute_governed(
            req(
                "edit",
                json!({ "path": "hello.txt", "old_text": "marker-A", "new_text": "marker-B" }),
                owner,
                "host-edit",
            ),
            &confirm,
        )
        .await
        .map_err(|err| format!("host edit governed error: {err}"))?;
    let _ = e;
    let r2 = host
        .execute_governed(
            req("read", json!({ "path": "hello.txt" }), owner, "host-read2"),
            &confirm,
        )
        .await
        .map_err(|err| format!("host read2 governed error: {err}"))?;
    check(
        content_text(&r2.output).contains("marker-B")
            && !content_text(&r2.output).contains("marker-A"),
        "host.edit",
        "edit did not replace marker-A with marker-B",
    )?;

    let b = host
        .execute_governed(
            req(
                "bash",
                json!({ "command": "echo MARKER-BASH-OK" }),
                owner,
                "host-bash",
            ),
            &confirm,
        )
        .await
        .map_err(|err| format!("host bash governed error: {err}"))?;
    check(
        exit_code(&b.output) == Some(0) && content_text(&b.output).contains("MARKER-BASH-OK"),
        "host.bash",
        "bash did not exit 0 with the expected stdout",
    )?;

    // ── 2. Mutation receipts recorded (write + edit + bash = 3) ───────────────
    let receipts_path = store.dir().join("toolhost_receipts.jsonl");
    let receipt_lines = std::fs::read_to_string(&receipts_path)
        .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count())
        .unwrap_or(0);
    check(
        receipt_lines >= 3,
        "receipts.recorded",
        &format!("expected >= 3 mutation receipts, found {receipt_lines}"),
    )?;

    // ── 3. Jailed tier: prove the OS sandbox actually runs on this kernel ─────
    if !jail_backend_available() {
        return Err(
            "jail_backend_available() is false — cannot prove OS isolation on this host".into(),
        );
    }
    let jailed = ToolOrigin::Proactive; // non-interactive → REQUIRES the jail

    let jin = host
        .execute_governed(
            req(
                "bash",
                json!({ "command": "touch jailed_inside.txt" }),
                jailed,
                "jail-inside",
            ),
            &confirm,
        )
        .await
        .map_err(|err| format!("jailed inside governed error: {err}"))?;
    check(
        exit_code(&jin.output) == Some(0) && root.join("jailed_inside.txt").exists(),
        "jail.write_inside",
        "jailed write inside the root should succeed",
    )?;

    // Negative: a jailed write OUTSIDE the root must be denied by the OS jail.
    let outside_file = outside.join("leak.txt");
    let outside_cmd = format!(
        "printf x > {}",
        sh_single_quote(&outside_file.to_string_lossy())
    );
    let jout = host
        .execute_governed(
            req(
                "bash",
                json!({ "command": outside_cmd }),
                jailed,
                "jail-outside",
            ),
            &confirm,
        )
        .await
        .map_err(|err| format!("jailed outside governed error: {err}"))?;
    // The bash itself runs (exit is whatever sh reports); the load-bearing proof
    // is that the write never landed — the OS jail blocked it.
    let _ = jout;
    check(
        !outside_file.exists(),
        "jail.write_outside_denied",
        "jailed write escaped the root — OS jail did NOT confine it",
    )?;

    // ── 4. Skill half: discover → activate → prepare_run → jailed bash exec ───
    // Canonicalize the skills dir to an ABSOLUTE path so `prepare_run` builds a
    // `uv run --script <abs>` command that resolves regardless of the bash cwd
    // (the jailed bash runs with cwd = the workspace root, not the skills dir).
    let skills_dir = std::fs::canonicalize(&args.skills_dir)
        .map_err(|e| format!("skills dir {}: {e}", args.skills_dir.display()))?;
    let skill_audit = Arc::new(ConductorStoreSkillAudit::new(Arc::clone(&store)));
    let skillhost = SkillHost::new(&skills_dir, skill_audit);
    let listing = skillhost.list();
    let ci_proof = listing.iter().find(|s| s.name == "ci-proof");
    check(
        ci_proof.is_some_and(|s| s.available),
        "skill.discovered",
        "ci-proof skill not discovered/available",
    )?;

    let body = skillhost
        .activate("ci-proof")
        .map_err(|e| format!("skill activate: {e}"))?;
    check(
        body.contains("CI-PROOF-SKILL-BODY-MARKER"),
        "skill.activated",
        "activated body missing its marker",
    )?;

    let plan = skillhost
        .prepare_run("ci-proof", None, "skill-run")
        .map_err(|e| format!("skill prepare_run: {e}"))?;
    check(
        plan.command.starts_with("uv run --script ") && plan.command.contains("hello.py"),
        "skill.prepared",
        "prepare_run did not build a uv run --script command",
    )?;

    // Point uv's caches at jail-allowed paths under the root so `uv run --script`
    // works inside the OS sandbox (writes confined to the root). `system` python,
    // no downloads, no network needed (the script has no dependencies).
    std::env::set_var("UV_CACHE_DIR", root.join(".uv-cache"));
    std::env::set_var("UV_PYTHON_DOWNLOADS", "never");
    std::env::set_var("HOME", root.join(".uv-home"));
    std::env::set_var("XDG_CACHE_HOME", root.join(".uv-home/.cache"));
    std::env::set_var("XDG_DATA_HOME", root.join(".uv-home/.local/share"));

    let sk = host
        .execute_governed(
            req(
                "bash",
                json!({ "command": plan.command.clone() }),
                jailed, // autonomous skill run → jailed
                "skill-bash",
            ),
            &confirm,
        )
        .await
        .map_err(|err| format!("skill bash governed error: {err}"))?;
    let sk_text = content_text(&sk.output);
    check(
        exit_code(&sk.output) == Some(0) && sk_text.contains(SKILL_MARKER),
        "skill.executed",
        &format!("skill run did not emit {SKILL_MARKER} at exit 0; output was: {sk_text}"),
    )?;

    println!("[headless-tool-test] all governed-execution steps passed");
    Ok(())
}

/// Single-quote a string for safe inclusion in an `sh -c` command.
fn sh_single_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_requires_skills_dir() {
        assert!(HeadlessToolTestArgs::parse(std::iter::empty()).is_err());
        let ok =
            HeadlessToolTestArgs::parse(["--skills", "/tmp/skills"].into_iter().map(String::from))
                .expect("valid args");
        assert_eq!(ok.skills_dir, PathBuf::from("/tmp/skills"));
    }

    #[test]
    fn parse_rejects_unknown_flag() {
        assert!(HeadlessToolTestArgs::parse(["--nope"].into_iter().map(String::from)).is_err());
    }

    #[test]
    fn sh_single_quote_escapes_embedded_quote() {
        assert_eq!(sh_single_quote("abc"), "'abc'");
        assert_eq!(sh_single_quote("a'b"), "'a'\\''b'");
    }
}

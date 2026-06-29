# ADR-013 Vision A — Slice A3→B: owner-approved durable workspace root

> **Status:** SCOPE rev 0 — **direction chosen by owner (2026-06-29: Option B)**.
> This relaxes A3 §5's "never cwd/home/project as the root" under explicit
> owner governance. Drafted for advisor/oracle review BEFORE implementation —
> it changes a security invariant, so the model must be signed off first.
>
> **Parent:** `vision-a-a3-protocol-surface-scope-2026-06-29.md` (§11 — the
> mechanism landed inert; routing was blocked pending this decision).
>
> **Depends on (merged):** A3-Rust (`8ed142d5`) + A3-Swift Layer 1 (`0266d93b`)
> + the dangerous-scope proof (`ec15a4bd`).

## 1. Why Option B

A3 delivered the governed ToolHost *mechanism* but left it **callable but
uncalled**: the session-root is a per-connection **ephemeral temp sandbox**
(§5), so routing Fae's owner-facing file tools (`read`/`write`/`edit`/`bash`/
`glob`/`grep`) to the daemon would operate on an empty tempdir, not the user's
project. Option B makes the root an **owner-approved durable workspace
directory** (the real project), which is what makes the ToolHost *useful* and
unblocks A3-Swift deliverable #4 (routing).

## 2. The threat-model shift (the reason this needs a signed scope)

| | Pre-B (temp sandbox) | Post-B (durable root) |
|---|---|---|
| Worst case | `rm -rf /` destroys temp files | `rm -rf .` / `git clean -fdx` / overwrite of a real critical file destroys **real work** |
| Confirm stakes | Low (owner can approve freely) | **High** (a social-engineered approve = real damage) |
| Path escape | Contained (canonicalize + `starts_with`) | **Unchanged** — still contained (§4) |

**The new risk is blast radius, not path escape.** A durable root means
operations hit real files. The scope's job is to bound that blast radius under
governance so the owner is never one distracted tap away from destroying work.

## 3. What changes (three things) — vs what does NOT

### Changes
1. **Root approval** (new capability): a distinct, explicit grant of a workspace
   directory, separate from the per-tool confirm. Higher bar (the owner is
   authorizing a *place*, once, not a *tool* per call).
2. **Blast-radius-aware damage control**: under a durable root, recursive
   deletes of the workspace/project deny **before** the confirm (§6.2 ordering).
   The current denylist only catches device/system catastrophic commands.
3. **Routing** (deliverable #4): Swift routes portable file tools to
   `toolhostExecute`; macOS-native stays local; networked stays denied.

### Does NOT change
- **Path containment** — `LocalSessionEnv` canonicalizes + checks `starts_with(root)`
  for *any* root (verified in fluers `local_env.rs:48-84`). A symlink pointing
  outside canonicalizes outside → rejected. Swapping the root from tempdir to a
  real dir does not weaken this. **The model uses relative paths under the root
  (the fluers convention); `FaeToolPolicy::path_is_escape` (defense-in-depth:
  rejects absolute + `..`) stays as-is and is compatible.**
- **Per-tool confirm** for dangerous tools — still shows path / new_bytes /
  old_exists (the owner sees *which* real file is touched).
- **Server-side dangerous-scope enforcement** — still requires
  `ToolExecuteDangerous` + confirm (proven `ec15a4bd`).
- **§6.2 ordering** — path/damage still run before the confirm surfaces.
- **No `fae.db` / MemoryOrchestrator** — audit stays in the conductor JSONL store.

## 4. Containment proof (why path escape is not the new risk)

`LocalSessionEnv::resolve(rel)` (fluers): joins `rel` under the canonicalized
`root`, canonicalizes the result, and verifies `canon.starts_with(&root)`. For
Option B, `root` = the approved workspace dir. This holds for every relative
path the model can name:
- `read("src/main.rs")` → `<root>/src/main.rs`, contained. ✓
- `read("../secret")` → `path_is_escape` denies (defense-in-depth) AND the
  canonicalize check would reject it. ✓ (two layers)
- a symlink `root/evil → /etc` → `canonicalize(root/evil/x)` = `/etc/x`,
  `!starts_with(root)` → rejected. ✓

Residual (documented, unchanged): `LocalSessionEnv` is **not** an OS-level
sandbox (no chroot/landlock/UID — see fluers `SECURITY.md`). There is a TOCTOU
window between the canonicalize check and the file op. This is a pre-existing
limitation of the substrate, not introduced by Option B, and acceptable because
the threat model is *accidental escape + blast radius under governance*, not a
malicious local adversary (Fae runs as the owner).

## 5. The approval mechanism (the new confirmation semantics)

**Lean: per-session, immutable, distinct card.**

- A new control-plane scope `ToolWorkspaceGrant` gates the ability to set a
  durable root at all (NOT in `SwiftFrontend::default_scopes` — explicit opt-in,
  like `ToolExecuteDangerous`).
- A new wire command `toolhost.set_root {path}`:
  - Requires `ToolWorkspaceGrant`.
  - Triggers a **distinct root-approval card** (not the inline `tool.confirm`):
    shows the absolute directory path + a blast-radius note. Server-side, the
    path is canonicalized + verified to exist + be a directory.
  - On approval, the session's ToolHost root is set to that path (replacing the
    temp sandbox) for the **remainder of the session**. Immutable once set
    (avoids mid-session root-swapping races; a new session picks a new root).
- Without an approved root: the ToolHost stays temp-sandboxed (file tools operate
  there) OR file tools are unavailable (OPEN-Q1 — lean: temp-sandbox default
  preserves the A3 inert-safe behavior).

**Why distinct from `tool.confirm`:** `tool.confirm` is per-call, inline, and
the owner approves a *tool invocation*. Root approval is per-session, deliberate,
and the owner authorizes a *place*. Conflating them would let a per-call tap
implicitly grant a durable workspace — exactly the "one distracted tap" failure
the threat model forbids.

**Lifecycle:** the root is set at session setup (after auth, before the first
`toolhost.execute` that needs the real project). This avoids recreating the
ToolHost mid-session. The ToolHost is created lazily on first
`toolhost.execute` (already the case post-A3 oracle fix); the root is resolved
then (approved durable root if granted, else temp sandbox).

### Q7b (dangerous opt-in) interaction — OPEN-Q2
Dangerous execution still requires `ToolExecuteDangerous`. Two models:
- **(a) Coupled:** granting the workspace root also grants `ToolExecuteDangerous`
  for the session (the owner opted into the workspace; each dangerous tool is
  still per-call confirmed). Simpler UX.
- **(b) Separate:** root grant and dangerous opt-in are independent grants.
  Tighter least-privilege.

**Lean (a)** for the minimal slice (one deliberate approval unlocks the
workspace; per-tool confirms remain). Flag for owner.

## 6. Blast-radius-aware damage control (the must-change)

The current `is_catastrophic_command` denylist catches device/system commands
(`rm -rf /`, `mkfs`, `dd of=/dev/...`). Under a durable root it must ALSO catch
**workspace-destroying** commands, and deny them **before** the confirm (§6.2):

- `rm -rf .` / `rm -rf ./` / `rm -rf <root-basename>` — recursive delete of the
  workspace.
- `git clean -fdx` / `git reset --hard` (destroys uncommitted work) — **OPEN-Q3**:
  deny, or high-bar confirm? Lean deny-before-confirm for `-fdx`/`--hard`
  (irreversible), same blast class as `rm -rf .`.
- `find . -delete` — recursive delete.
- Overwrite of a workspace-critical file (Makefile/Cargo.toml/package.json) —
  **OPEN-Q4**: hard to classify cheaply; lean: rely on the per-tool confirm's
  `old_exists` + `new_bytes` to surface it, NOT a deny (too many false positives).

This list must be **root-aware**: the same `rm -rf ./subdir` is fine (a clean
subdir) but `rm -rf .` is catastrophic. The denylist compares against the root.
Mutation-guarded tests for each.

**Crucially:** the §6.2 ordering means these deny **without prompting** — a
social-engineered "approve" can never authorize a workspace wipe.

## 7. Routing (deliverable #4 — Swift side)

Once a durable root is approved, Swift routes portable file tools to
`toolhostExecute`:

| Tool class | Routes to | Status |
|---|---|---|
| Portable (`read`/`write`/`edit`/`bash`/`glob`/`grep`) | daemon `toolhost.execute` (server-request-aware) | **NEW in B** |
| macOS-native (EventKit/camera/computer-use) | Swift, in-process | unchanged |
| Networked (`web_search`/`fetch_url`) | denied (`DisabledGate`) | unchanged |

Routing helper: a small pure classifier `portableDaemon | localSwift |
deniedNetworked` at the `PipelineCoordinator.executeTool` convergence point,
explicitly allowlisting daemon-routed tool names (matching the Swift registry
names to daemon tool names). Unknown/plugin/macOS-native tools stay local unless
deliberately classified. (Networked explicitly denied — no silent egress.)

## 8. Split (mirror A3-Rust / A3-Swift)

- **B-Rust:** `toolhost.set_root` command + `ToolWorkspaceGrant` scope + the
  lazy-root-resolves-to-approved-path change + blast-radius damage-control
  expansion + root-aware denylist + tests. Fully Rust-tested via a fake client
  (no Swift). **Merges first.**
- **B-Swift:** the root-approval card + `toolhost.set_root` Swift call (server-
  request-aware) + the routing helper + `PipelineCoordinator` integration + Q7b
  scope provisioning + human-in-the-loop confirm testing. **After B-Rust green.**

## 9. Test plan (highlights — each mutation-guarded)
- Root-not-approved → file tools operate in temp sandbox (or deny per OPEN-Q1).
- Root approved → file tools read/write the real project dir; escapes still deny.
- `rm -rf .` under a durable root → denied WITHOUT prompt (blast-radius).
- `rm -rf ./subdir` → proceeds to confirm (not a workspace wipe).
- Symlink-outside under the root → denied (containment).
- Per-tool confirm shows the real path + old_exists + new_bytes (redacted).
- Routing: portable→daemon, native→local, networked→denied.
- BLOCKER-1 still holds for `toolhost.set_root` (server-request-aware if it can
  trigger a confirm).

## 10. Open questions
- **OPEN-Q1:** no-root-approved behavior — temp-sandbox default (lean) vs file-
  tools-unavailable?
- **OPEN-Q2:** Q7b coupling — root grant implies `ToolExecuteDangerous` (lean)
  vs separate grants?
- **OPEN-Q3:** `git clean -fdx` / `git reset --hard` — deny-before-confirm (lean)
  vs high-bar confirm?
- **OPEN-Q4:** critical-file overwrite (Cargo.toml etc.) — rely on confirm's
  `old_exists` (lean) vs a deny?
- **OPEN-Q5:** persistent per-project root grant (survives sessions) — follow-on
  to the per-session minimal slice?

## 11. Acceptance (B done when)
1. An owner can approve a durable workspace root via a distinct card; the root
   is canonicalized, verified, and stored per-session.
2. File tools operate on the real project under that root; path escapes (incl.
   symlinks) still deny (two layers).
3. Workspace-wipe commands (`rm -rf .`, etc.) deny WITHOUT prompting, regardless
   of the confirm.
4. macOS-native tools still run locally; networked tools still deny.
5. Dangerous execution still requires `ToolExecuteDangerous` + per-tool confirm.
6. Gates green; boundary guards intact; no `fae.db` writes; BLOCKER-1 holds.

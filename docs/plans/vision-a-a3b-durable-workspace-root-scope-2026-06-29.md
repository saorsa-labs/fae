# ADR-013 Vision A — Slice A3→B: owner-approved durable workspace root

> **Status:** SCOPE rev 2 — **owner-signed-off (2026-06-29: Option B)**,
> advisor-reviewed (rev 1: 7 corrections; rev 2: implementation-structure pass).
> This relaxes A3 §5's "never cwd/home/project as the root" under explicit
> owner governance. A3-Swift Layer 1 merged (`9cad5c23`); B-Rust now in flight.
>
> **Rev 2 folds the implementation-structure pass:** Q6 RESOLVED (provision
> `ToolWorkspaceGrant` default-off via `FAE_TOOLHOST_WORKSPACE_GRANT=1` at daemon
> startup — never a client-supplied payload as authority); Q3 RESOLVED (`git
> clean -fdx` / `git reset --hard` deny-before-confirm); a per-connection root
> STATE MACHINE (`Unset`/`PendingRootConfirm`/`ApprovedRoot`/`InitializedTemp`/
> `InitializedDurable`) under `tokio::sync::Mutex` (no std-mutex-across-awaits);
> a structural root-safety guard (reject `/`, filesystem roots, the home dir);
> late-set_root → `root_already_initialized`; execute-while-pending →
> `root_initialization_pending`.
>
> **Rev 1 folds the advisor pass:** no-root ⇒ NO daemon routing (not a tempdir
> fallback); root grant and `ToolExecuteDangerous` stay DECOUPLED (safe tools
> route first, dangerous waits for explicit provisioning); `ToolWorkspaceGrant`
> provisioning made real (server-side, not a Swift-local flag); `toolhost.
> set_root` is BLOCKER-1 load-bearing; root is immutable once set; damage
> control gets an explicit `TempSandbox` vs `DurableWorkspace` mode;
> containment claims softened to the cooperative-owner threat model.
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
  - **Provisioning (advisor #3):** `ToolWorkspaceGrant` is NOT in
    `SwiftFrontend::default_scopes`. It must be obtainable through REAL
    server-side provisioning — a new bootstrap-token-stamped scope (the same
    hash-verified per-connection handshake `session.authenticate` uses), NOT a
    Swift-local flag. A Swift-local approval is not authority. (Provisioning
    surface: `session.authenticate` gains an opt-in `workspace_grant` capability
    bound to the bootstrap token; the server records it on `ClientRecord`.)
  - **BLOCKER-1 (advisor #4 — load-bearing):** root approval is a daemon-
    initiated `ServerRequester` round-trip (the daemon surfaces the root-
    approval card, the owner replies). Therefore `toolhost.set_root` MUST be
    SPAWNED like `toolhost.execute` (never awaited inline in the read loop), and
    the Swift caller MUST use the server-request-aware `roundTrip`. Same
    deadlock class as BLOCKER-1; regression-test-required.
  - Triggers a **distinct root-approval card** (not the inline `tool.confirm`):
    shows the canonicalized absolute directory path + a blast-radius note. The
    path is canonicalized + verified to exist + be a directory server-side.
  - **Immutability (advisor #5):** on approval, the session's `ApprovedRoot` is
    stored in connection/session state and the ToolHost is created bound to it.
    A late `set_root` (after the ToolHost exists or tasks are in flight) is
    denied with `root_already_initialized`. A new session picks a new root.
- **No-root behavior (advisor #1 — RESOLVED, no longer OPEN):** without an
  approved durable root, **owner-facing file tools do NOT route to the daemon.**
  They either preserve the existing Swift-local behavior (today's path) or the
  daemon denies with `workspace_root_required`. Critically, they do NOT silently
  fall back to the temp sandbox — routing file tools to an empty tempdir is the
  exact failure mode that blocked routing in the first place (reads/writes hit
  nothing real). The temp sandbox is reserved for the daemon-resident agent loop
  (Vision B) and for callers that explicitly opt into it.

**Why distinct from `tool.confirm`:** `tool.confirm` is per-call, inline, and
the owner approves a *tool invocation*. Root approval is per-session, deliberate,
and the owner authorizes a *place*. Conflating them would let a per-call tap
implicitly grant a durable workspace — exactly the "one distracted tap" failure
the threat model forbids.

**Lifecycle:** the root is set at session setup (after auth, before the first
`toolhost.execute` that needs the real project). The ToolHost is created lazily
on first `toolhost.execute`; the root is resolved then (the approved
`ApprovedRoot` if set, else `workspace_root_required` for routed file tools).

### Root grant vs dangerous scope — DECOUPLED (advisor #2 — RESOLVED, no longer OPEN)

Root grant answers "WHERE" (the workspace dir); `ToolExecuteDangerous` answers
"MAY this client write/shell". These are independent axes. Keeping them
**decoupled** (not coupled as rev 0 leaned) means:
- **Safe tools** (`read`/`glob`/`grep`) route to the daemon with JUST an approved
  root (no dangerous scope needed — they're read-only + path-contained).
- **Dangerous tools** (`write`/`edit`/`bash`) additionally require explicit
  server-side `ToolExecuteDangerous` provisioning (Q7b, a separate grant) AND
  the per-tool confirm. Without `ToolExecuteDangerous`, they deny at the inner
  `authorize("tool.execute_dangerous")` gate (proven `ec15a4bd`).

This lets minimal routing land with safe tools first — the useful, low-blast-
radius case (read/search a project) — and gates dangerous execution behind its
own deliberate provisioning. Tighter least-privilege than rev 0's coupled lean.

## 6. Blast-radius-aware damage control (the must-change)

The current `is_catastrophic_command` denylist catches device/system commands
(`rm -rf /`, `mkfs`, `dd of=/dev/...`). Under a durable root it must ALSO catch
**workspace-destroying** commands, and deny them **before** the confirm (§6.2).
This requires an explicit **mode** in `FaeToolPolicy` (advisor #6):
`TempSandbox` (current behavior — a recursive delete of the temp root is fine)
vs `DurableWorkspace` (a recursive delete of the real project is catastrophic).
The denylist is mode-aware; the catastrophic patterns apply only in
`DurableWorkspace` mode.

Durable-mode catastrophic patterns (deny WITHOUT prompting, §6.2):
- `rm -rf .` / `rm -rf ./` / `rm -rf *` — recursive delete of the workspace.
- `rm -rf <root-basename>` — deleting the workspace by name (root-aware).
- `find . -delete` / `find <root> -delete` — recursive delete.
- `git clean -fdx` / `git reset --hard` (destroys uncommitted work) —
  **OPEN-Q3**: deny-before-confirm (lean; irreversible, same blast class as
  `rm -rf .`) vs high-bar confirm. Lean deny.
- Overwrite of a workspace-critical file (Cargo.toml/Makefile/package.json) —
  **OPEN-Q4**: hard to classify cheaply; lean: rely on the per-tool confirm's
  `old_exists` + `new_bytes` to surface it, NOT a deny (too many false
  positives). The confirm shows the real path so the owner sees the target.

This list must be **root-aware**: `rm -rf ./subdir` is fine (a clean subdir) but
`rm -rf .` is catastrophic. The mode+root are threaded into the denylist check.
Mutation-guarded tests for EACH pattern (`rm -rf .`, `rm -rf ./`, `rm -rf *`,
`find . -delete`, `git clean -fdx`, `git reset --hard`) — flipping the pattern
must flip the verdict (mutation discipline).

**Crucially:** the §6.2 ordering means these deny **without prompting** — a
social-engineered "approve" can never authorize a workspace wipe.

**Honesty (advisor #6):** this is a substring/regex denylist — it is NOT a
complete shell-safety guarantee. A determined obfuscation (`rm -rf ${PWD}` or a
script that deletes the root) can bypass it. The defense is layered:
containment (paths stay under the root) + the denylist (catches the obvious
wipes) + the per-tool confirm (the owner sees the command preview for EVERY
bash call). The denylist raises the bar; it does not make `bash` safe. That is
acceptable under the cooperative-owner threat model (Fae runs as the owner;
the risk is accidental/over-broad damage, not a malicious local adversary).

## 7. Routing (deliverable #4 — Swift side)

Once a durable root is approved, Swift routes portable file tools to
`toolhostExecute`. Routing respects the decoupling (§5): safe tools route with
just the root; dangerous tools additionally require `ToolExecuteDangerous` (and
the per-tool confirm):

| Tool class | Routes to | Requires |
|---|---|---|
| Safe portable (`read`/`glob`/`grep`) | daemon `toolhost.execute` (server-request-aware) | approved root only |
| Dangerous portable (`write`/`edit`/`bash`) | daemon `toolhost.execute` | approved root **+** `ToolExecuteDangerous` **+** per-tool confirm |
| macOS-native (EventKit/camera/computer-use) | Swift, in-process | unchanged (privileged OS APIs) |
| Networked (`web_search`/`fetch_url`) | denied (`DisabledGate`) | egress adapter is A2.5/P7 |

No approved root ⇒ owner-facing file tools do NOT route to the daemon (advisor
#1): they preserve existing Swift-local behavior or the daemon denies with
`workspace_root_required`. They never silently fall back to the temp sandbox.

Routing helper: a small pure classifier `portableDaemonSafe | portableDaemonDangerous | localSwift | deniedNetworked` at the
`PipelineCoordinator.executeTool` convergence point, explicitly allowlisting
daemon-routed tool names (matching the Swift registry names to daemon tool
names). Unknown/plugin/macOS-native tools stay local unless deliberately
classified. (Networked explicitly denied — no silent egress.)

## 8. Split (mirror A3-Rust / A3-Swift)

- **B-Rust:** `toolhost.set_root` command + `ToolWorkspaceGrant` scope + the
  lazy-root-resolves-to-approved-path change + blast-radius damage-control
  expansion + root-aware denylist + tests. Fully Rust-tested via a fake client
  (no Swift). **Merges first.**
- **B-Swift:** the root-approval card + `toolhost.set_root` Swift call (server-
  request-aware) + the routing helper + `PipelineCoordinator` integration + Q7b
  scope provisioning + human-in-the-loop confirm testing. **After B-Rust green.**

## 9. Test plan (highlights — each mutation-guarded)
- Root-not-approved → owner-facing file tools do NOT route to the daemon (Swift-local or `workspace_root_required`); they never hit the temp sandbox silently.
- Root approved, safe-only client → `read`/`glob`/`grep` run on the real project; `write`/`edit`/`bash` deny on `missing_scope` WITHOUT prompting (proven `ec15a4bd`).
- Root approved + `ToolExecuteDangerous` → dangerous tools reach the confirm; approve runs, deny doesn't.
- `rm -rf .` / `rm -rf ./` / `rm -rf *` / `find . -delete` / `git clean -fdx` / `git reset --hard` under a durable root → denied WITHOUT prompt (blast-radius; mutation-tested — flipping the pattern flips the verdict).
- `rm -rf ./subdir` → proceeds to confirm (not a workspace wipe).
- Symlink-outside under the root → denied (containment).
- Per-tool confirm shows the real path + old_exists + new_bytes (redacted, never contents).
- Late `toolhost.set_root` (after init) → `root_already_initialized`.
- Routing: safe-portable→daemon, dangerous-portable→daemon+scope, native→local, networked→denied.
- BLOCKER-1 holds for `toolhost.set_root` (spawned + server-request-aware).

## 10. Open questions
- **OPEN-Q1 (RESOLVED, advisor #1):** no-root behavior = NO daemon routing for
  owner-facing file tools (Swift-local or `workspace_root_required`), never a
  temp-sandbox fallback.
- **OPEN-Q2 (RESOLVED, advisor #2):** root grant and `ToolExecuteDangerous` are
  DECOUPLED. Safe tools route with just a root; dangerous waits for explicit
  provisioning.
- **OPEN-Q3 (RESOLVED, rev 2):** `git clean -fdx` / `git reset --hard` →
  deny-before-confirm (irreversible, same blast class as `rm -rf .`).
- **OPEN-Q4:** critical-file overwrite (Cargo.toml etc.) — rely on confirm's
  `old_exists` (lean) vs a deny?
- **OPEN-Q5:** persistent per-project root grant (survives sessions) — follow-on
  to the per-session minimal slice?
- **OPEN-Q6 (RESOLVED, advisor #3 + rev 2):** provisioning = a daemon-startup
  env opt-in `FAE_TOOLHOST_WORKSPACE_GRANT=1` (default off) that adds
  `ToolWorkspaceGrant` to the bootstrap `SwiftFrontend` client's scopes at
  registration (`main.rs`, precedent `FAE_CONDUCTOR_CHAIN`). Owner-controlled,
  server-side, never a client-supplied `session.authenticate` payload as
  authority. Off by default ⇒ `toolhost.set_root` denies at the scope gate.

## 11. Acceptance (B done when)
1. An owner can approve a durable workspace root via a DISTINCT card (not the
   inline `tool.confirm`); the root is canonicalized, verified, stored per-session
   in `ApprovedRoot`, and immutable once set (`root_already_initialized`).
2. No approved root ⇒ owner-facing file tools do NOT route to the daemon (Swift-
   local or `workspace_root_required`); they never silently hit the temp sandbox.
3. Safe portable tools (`read`/`glob`/`grep`) run on the real project under the
   approved root with just the root grant; path escapes (incl. symlinks) deny.
4. Dangerous portable tools (`write`/`edit`/`bash`) additionally require
   `ToolExecuteDangerous` (decoupled from the root grant) + the per-tool confirm.
5. Workspace-wipe commands (`rm -rf .`, `git clean -fdx`, etc.) deny WITHOUT
   prompting, regardless of the confirm (mode-aware damage control).
6. macOS-native tools still run locally; networked tools still deny.
7. `toolhost.set_root` is spawned + server-request-aware (BLOCKER-1).
8. Gates green; boundary guards intact; no `fae.db` writes.

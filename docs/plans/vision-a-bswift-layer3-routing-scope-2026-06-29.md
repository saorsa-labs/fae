# Vision A — B-Swift Layer 3 Routing Scope (rev 1)

**Owner decision (2026-06-29):** root source = **C′ — Fae-managed default workspace**
(non-technical users never pick a folder).

**Rev 1 changes (advisor review 2026-06-29):** all 8 advisor MUST-changes applied.
Biggest: **Layer 3 is default-workspace-ONLY** — B-Rust root is immutable per
connection after `set_root` (`session.rs:1221-1223`: "set_root is only valid from
`Unset`; already-approved root is immutable for the session"), so a later
"real-project" `set_root` on the same session would `root_already_initialized`.
Paths outside the default root are therefore **denied with a helpful error**;
multi-root/session-pool is deferred. This *simplifies* Layer 3 and removes the
"card for non-default path" logic from rev0.

**Status:** advisor-rev1 → **3a IMPLEMENTED + advisor-approved** (4 review rounds,
`a30431ab`). Auto-approve-of-a-root-path converged to READY. 3b (routing) next,
as a minimal `read`-only slice.

**Final invariants (implemented, stricter than rev1 after review):**
- `defaultAwareHandler`: `call_id` raw==trimmed + non-empty; `path` raw==trimmed +
  non-empty + **absolute**; canonical-EXACT match + marker present; `tool.confirm`
  NEVER auto-approved. (`isCleanNonBlank` / `isCleanAbsolutePath` helpers.)
- `DaemonToolHostSession.setRoot(path:handler:)` is **private**; binds
  `approvedRootPath` only on `ok==true` with a clean-absolute daemon-RETURNED
  `result.root` (not the requested path). `ok:true` with missing/whitespace/relative
  root leaves it nil → `ensureDefaultRooted` throws.
- Tests: `DaemonToolHostTests` 27/27.

---

## 1. What C′ means (rev 1: default-workspace-only)

Fae owns ONE default workspace dir (`~/Documents/Fae/`, via injectable provider).
It becomes the ToolHost's durable root, **auto-approved without a per-session
card** (Fae-owned; blast radius bounded by the B-Rust guard). The session holds
this root for its lifetime. Tool operations are confined to paths under it; paths
outside are **denied at the Swift routing seam** (the daemon can't express a
second root on the same connection anyway). Reaching a *different* root is a
future session-pool feature — explicitly out of scope for Layer 3.

**Why default-only is safe AND simpler:** the root-immutability constraint means
a "confirm a different root" flow can't coexist with the auto-rooted default on
one connection. Rather than build a connection pool now, Layer 3 confines work to
the default. The confirm card (`workspace.confirm_root`) still fires — but only
ONCE, for the default, and is auto-approved by the marker-aware handler.

---

## 2. Layering (unchanged from rev0)

| Layer | Scope | Safety class |
|-------|-------|--------------|
| **3a** | Default workspace provisioning + auto-root | **safety-critical** |
| **3b** | Routing classifier + arg normalization | safety-critical |
| 4 | `FAE_TOOLHOST_DANGEROUS_TOOLS` provisioning | scope-gate |
| 5 | Integration tests | proof |

**Implement 3a this turn; 3b after 3a gates pass.**

---

## 3. Layer 3a — Default workspace + auto-root (rev 1)

### 3.1 Injectable workspace provider (advisor #4)

```swift
/// Pure provider (no mutable shared state). Default impl resolves
/// .documentDirectory + "Fae". Tests inject a temp-dir provider so they NEVER
/// touch real ~/Documents (oracle MAJOR-1 DI precedent; also avoids macOS TCC
/// sandbox prompts in CI).
protocol FaeWorkspaceProvider {
    var workspaceRoot: URL { get }
    var markerName: String { get }  // ".fae-workspace"
}
struct DefaultDocumentsWorkspace: FaeWorkspaceProvider { … }
```

**TCC note:** `.documentDirectory` may trigger a macOS Files/Files permission
prompt. If that proves disruptive, swap the provider to App Support — **no
routing changes** (the provider is the only seam that knows the path).

### 3.2 Provisioning (advisor #4, marker as UX/collision guard — NOT security)

```swift
enum ProvisionOutcome {
    case provisioned(URL)           // Fae created it + marker this call
    case alreadyOwned(URL)          // marker already present (sticky)
    case preExistingWithoutMarker   // dir exists, NO marker → surface the card
}

static func provision(_ p: FaeWorkspaceProvider) throws -> ProvisionOutcome
```

**Marker semantics (rev1):** the marker is an **ownership/collision guard**, not
a security boundary. It prevents Fae from silently taking over a user-made
`~/Documents/Fae/` with precious files. The **security** authority is the B-Rust
`is_safe_workspace_root` server guard (`root_confirm.rs:224-278`) — it
canonicalizes and rejects home/system regardless of what the client approves
(this is what defeats symlink-to-home attacks, not the marker).

### 3.3 Session: `ensureDefaultRooted` + store the approved path (advisor #2)

`DaemonToolHostSession` gains:

```swift
private var approvedRootPath: URL?   // store the PATH, not just rootSet:Bool

/// Idempotent: connect → provision default → setRoot(default). Auto-approves the
/// confirm (marker present) via the wrapper handler. On preExistingWithoutMarker
/// → surfaces the real card ONCE; on approval writes the marker → sticky.
func ensureDefaultRooted(provider: FaeWorkspaceProvider = DefaultDocumentsWorkspace()) async throws -> URL

/// Execute confined to the default workspace. Fails-closed if not rooted.
/// Path args are normalized to root-relative (rev1 §5) before sending.
func executeInDefaultWorkspace(tool: String, input: [String: Any]) async throws -> [String: Any]
```

The session is **one long-lived actor** (rev0's per-call pattern was wrong). All
routed execute calls reuse `ensureDefaultRooted`'s connection + root.

### 3.4 Auto-approve wrapper (advisor #3)

```swift
func defaultAwareHandler(_ real: DaemonServerRequestHandler,
                         defaultPath: URL,
                         markerPresent: () -> Bool) -> DaemonServerRequestHandler
```

Auto-approves IFF **all** hold:
1. `method == "workspace.confirm_root"` (**never** `tool.confirm`), AND
2. canonical(confirm.path) == canonical(defaultPath) (EXACT, never prefix), AND
3. `markerPresent()`.

Otherwise → `real` (the card surfaces). The daemon still asks; the client still
decides — only UI friction is removed for the Fae-owned path. Authority intact.

### 3.5 What this does NOT relax (unchanged from rev0)

- Daemon `set_root` round-trip unchanged — always asks.
- Daemon `is_safe_workspace_root` always runs (rejects home/system even if
  auto-approved).
- `tool.confirm` (per-call dangerous op) is **never** auto-approved.

---

## 4. Layer 3b — Routing classifier + arg normalization (rev 1)

### 4.1 bash reclassified (advisor #5 — verified against policy.rs:78-95)

Daemon policy: `read`=safe; **`write`/`edit`/`bash`=dangerous** (`tool.execute_dangerous`).
Rev0 wrongly listed bash as safe. Corrected table:

| Tool | Route | Daemon scope needed | Layer-3 disposition |
|------|-------|---------------------|---------------------|
| `read` | `portableDaemonSafe` | `tool.execute_safe` | route to daemon NOW |
| `write`,`edit` | `portableDaemonDangerous` | `tool.execute_dangerous` | route, but denied until Layer 4 provisions scope |
| `bash` | `localSwift` (rev1) | `tool.execute_dangerous` | **leave on existing Swift path** — highest blast radius; substring damage-denylist isn't complete shell safety. Defer to a dedicated slice. |
| apple/scheduler/roleplay/web | `localSwift` | — | existing Swift impl |
| networked egress tools | `deniedNetworked` | — | deny at Swift boundary |

**Default = existing local Swift behavior unless explicitly routed.** Conservative.

### 4.2 Placement (advisor #6 — verified executeInner:224→365)

The span already contains Swift deny gates: step 7 DamageControlPolicy, step 9
PreToolUse hooks, step 11 irreversible-countdown. Routing inserts **before step
7** so:
- **Deterministic Swift deny gates stay** (tool-mode, proactive-allowlist, step
  limit, irreversible-countdown) as fast pre-filters.
- **For routed tools, daemon governance is authoritative** for path/damage/egress
  + confirm — the Swift DamageControl verdict is NOT re-applied (no double
  approval). The daemon's `tool.confirm` surfaces the SAME card via
  `serverRequestHandler`.

### 4.3 Path normalization (advisor #7)

Swift sends **root-relative paths only** to the daemon:
- Reject absolute paths and any path escaping the root (`..`, symlink-escape).
- Existing paths: canonicalize, assert under root.
- Non-existing write targets: canonicalize nearest existing parent, assert under
  root.
- Tests: symlink-escape (`defaultRoot/evil → /etc`), `..` traversal.

---

## 5. Security analysis (rev 1)

### 5.1 Auto-approve safety (core question) — YES with rev1 invariants
- Daemon still asks; client still decides. No authority delegated.
- B-Rust guard canonicalizes + rejects home/system regardless of client approval.
- Auto-approve = canonical-EXACT + marker + method-restricted
  (`workspace.confirm_root` only). Cannot widen.
- Blast radius = `~/Documents/Fae/`, Fae-owned.

### 5.2 Marker = UX/collision guard, NOT security (rev1 correction)
- Defeats "Fae takes over user's precious `~/Documents/Fae/`," NOT symlink
  attacks (those are the server guard's job). Specified explicitly to avoid the
  mistaken belief that the marker is a security control.

### 5.3 Residual risks (accepted)
- User puts precious files in the Fae-owned dir after provisioning → Fae tools
  can delete them. Mitigated by Fae-named dir + workspace-wipe denylist. Inherent
  to "Fae owns a workspace."
- No OS-level sandbox (same as B-Rust ACCEPTABLE-RESIDUAL).

### 5.4 Invariants (must not break)
1. Auto-approve fires ONLY for canonical-exact default path WITH marker, on
   `workspace.confirm_root` only.
2. `tool.confirm` NEVER auto-approved.
3. Daemon governance always runs (never bypassed by routing).
4. Root is the provisioned default — NEVER inferred from a requested file path
   (the §1 footgun is structural).
5. Paths outside the default root are DENIED (root-immutability makes a second
   root impossible on one connection anyway).

---

## 6. Tests (advisor #8 — write before coding 3b)

3a tests (NFS-safe temp dirs, never real Documents):
1. `testProvisionCreatesDirAndMarker` — fresh temp → dir + marker created.
2. `testAlreadyOwnedIsSticky` — marker present → `alreadyOwned`, no re-card.
3. `testPreExistingWithoutMarkerSurfacesRealHandler` — pre-made dir, no marker →
   real handler invoked (card), NOT auto-approved.
4. `testAutoApproveCanonicalExactOnly` — confirm on default path → auto-approved;
   confirm on a sibling path → real handler.
5. `testToolConfirmNeverAutoApproved` — `tool.confirm` → always real handler,
   even for default path.
6. `testSymlinkedDefaultRejectedByServerGuard` — `default → ~/` → daemon rejects
   (canon == home) despite auto-approval attempt.
7. `testOutsideDefaultPathDeniedAtRouting` — `read` of `/etc/passwd` → denied
   (path normalization; 3b, but the seam lands in 3a's execute).
8. `testSessionReusedAcrossEnsureRootedAndExecute` — one connection, one root,
   multiple executes (persistence proof, extends Layer 2's).

---

## 7. Advisor questions — RESOLVED in rev1

1. ✅ Marker = UX/collision guard (not security); server guard is authority.
2. ✅ Keep deterministic Swift deny gates; daemon authoritative for routed tools
   (no double approval).
3. ✅ `deniedNetworked` = networked egress tools; `web_search`/`fetch_url` stay
   `localSwift` (read-egress, existing impl). Exact denylist finalized in 3b.
4. ✅ Swift sends root-relative only; reject absolute/escaping.

---

## 8. Hand-back

**3a COMPLETE + advisor-approved** (`6805938b` → `a30431ab`, 4 review rounds):
FaeWorkspace provider/provision/marker + defaultAwareHandler +
ensureDefaultRooted/executeInDefaultWorkspace + 27/27 DaemonToolHostTests.

**3b (next) — minimal `read`-only routing slice** (per advisor signoff):
1. Route **only `read`** to the daemon initially.
2. `write`/`edit` stay dangerous-classed, not enabled until Layer 4; `bash`
   stays local/denied (highest blast radius; substring denylist ≠ shell safety).
3. Insert before the Swift DamageControl user-approval path, AFTER deterministic
   gates (tool-mode, proactive-allowlist, step-limit) — avoid double approval.
4. Root-relative path normalization for `read`: reject absolute, `..`, and symlink
   escapes; canonicalize existing path, assert under `rootPath()`.
5. Tests first: valid default-root read routes to daemon; absolute/`..`/symlink
   denied; non-routed tools preserve local behavior; session reused.

Root-source footgun (§1) is structural: the root is always the provisioned default
— never inferred from a requested file path.

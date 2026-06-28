# ADR-013 Vision A — Slice A2 scope: the governed daemon ToolHost

> **Status:** rev 4 (2026-06-29) — **reviewer-approved**; the **owner explicitly
> accepted the networked→`safe` scope deviation (2026-06-29)**. Other §7 items
> (Q1 A2-pre, Q2 audit file, Q3 deferred-to-A3, Q4 fail-closed) are
> **reviewer-recommended** and owner-ratified by accepting this merge — they were
> not separately owner-signed (provenance corrected at merge; earlier revs
> overstated "owner-signed"). Rev 2 incorporated the oracle
> scope review (`a9f83f11`, NOT READY → fixed): BLOCKER-1 (full egress gate:
> mode+PII+provisioning, not PII-only), MAJOR-1 (per-tool path extractors incl.
> glob/grep), MAJOR-2 (explicit risk-class→scope table), MAJOR-3 (A3 internal
> API seam), MAJOR-4 (SkillHost split resolved to A2.5), MINOR-1/2. Rev 3 folded
> the owner sign-off decisions (§7: Q1/Q2/Q4 resolved, Q3 deferred to A3 with
> leans) + the grep-optional-`paths` nuance (§5.2 step 3, §8). Rev 4 records the
> post-implementation acceptance of the networked→`safe` scope deviation
> (§5.2 table + note): oracle code review `ec0c3a17` (CONDITIONAL, no BLOCKER)
> flagged that the table's `dangerous` made the step-5 egress gate unreachable;
> owner accepted `safe + egress gate` as the authorization model for networked
> tools. Second oracle pass on the scope was skipped (source-grounding > LLM
> re-read); the oracle was spent on the A2-body code instead.
> **Authority:** ADR-013 (Accepted, `c64e9476`) → Vision A kickoff
> (`docs/plans/vision-a-toolhost-kickoff-2026-06-28.md`).
> **Depends on:** A0 (fluers `ToolPolicy` hook, released v0.2.0 `fcd044a`) ✅;
> A1 (fae-daemon git-dep, now pinned to fluers **v0.3.0** `1a3f75a`) ✅ merged;
> A2-pre (generic fluers `edit` + `read_file_full`, v0.3.0) ✅ merged+tagged.
> **Proven reference:** `crates/fae-substrate-spike/src/lib.rs` (spike S19,
> reviewer-verified; reference-only, NOT for merge).

## 1. What A2 is

A daemon-side tool/skill **execution host** that runs fluers native tools
(`read`/`write`/`bash`/`glob`/`grep`/`edit`) over a `LocalSessionEnv`, **behind a
Fae `ToolPolicy` impl** that composes the full governance stack. Every execution →
control-plane **fail-closed audit**.

**SkillHost is DEFERRED to A2.5** (oracle MAJOR-4, resolved): ADR-013 §changes
lists the integrity'd `Skill` schema as a fluers deviation, but it is not on
the critical path for the native-tool proof (A4). A2 = native ToolHost only.
A2.5 adds integrity'd Skills (`schemaVersion`/`capabilities`/`allowedTools`/
SHA-256) as a separate, owner-approved hand-back. P7 (CalDAV/CardDAV/himalaya
skills) builds on A2.5, not A2.

A2 is **internal**: it defines the ToolHost + the `FaeToolPolicy` + unit/integration
tests. It deliberately does NOT include the protocol surface (that's A3:
`tool.execute`/`toolhost.execute` + Swift routing) or the live bundled-app proof
(A4). A2 defines the seams A3 will call, but A3 is a separate hand-back.

**Hard Vision-B boundary (unchanged):** no loop relocation, no
conductor-as-`ModelProvider`, no `RemoteSwiftTool`. The Swift loop still drives;
it calls INTO this host for portable/native tool execution.

## 2. Blocking prerequisite — fluers `edit` tool (A2-pre)

**Verified absence:** fluers 0.2.0 ships `read`/`write`/`bash`/`glob`/`grep`
(`crates/fluers-runtime/src/tool.rs`, `mvp_tools_with_limits`) but **no `edit`**.
ADR-013 §"Fae-driven changes to fluers" explicitly lists `edit` as a sanctioned
generic deviation. The kickoff (A2) lists `edit` in the toolset.

**Decision required (OPEN-Q1):** two options —

- **(a) Land a generic `EditTool` in fluers** as a v0.3 deviation (README note,
  `mvp_tools` adds it, 2–3 tests: exact-match replace, no-match error,
  path-escape denied by `LocalSessionEnv`). Release fluers v0.3; Fae re-pins
  A1's rev. *Recommended* — it matches the ADR's "fluers deviations stay generic"
  ownership rule and keeps `edit` available to other fluers consumers.
- **(b) Ship a Fae-local `edit` tool wrapper** inside `crates/fae-daemon/src/toolhost/`.
  *Rejected unless owner overrides* — it forks the tool surface and contradicts
  the "one `Tool` trait spanning all tools" ADR goal.

**Recommendation:** A2 is split into **A2-pre** (generic `EditTool` → fluers v0.3
→ Fae re-pin) and **A2-body** (the governed ToolHost). A2-pre is small, generic,
and independently reviewable; it unblocks A2-body cleanly.

## 3. Verified source facts (grounded the design, 2026-06-29)

### 3.1 fluers 0.2.0 surface (the substrate)

- `fluers_core::policy::{ToolPolicy, PolicyVerdict}` (A0) —
  `check(&self, tool: &str, input: &Value, ctx: &InvokeContext) -> PolicyVerdict`.
  **`InvokeContext` carries ONLY `{tool_call_id: String, cancel: CancellationToken}`**
  — no client identity, no audit sink, no session root. (S19 caveat #2: run-scoped
  state must live in the Fae policy impl's own `Arc`.)
- `fluers_core::tool::{Tool, ToolDefinition, InvokeContext, ToolCall, ToolResult}`.
- `fluers_runtime::SessionEnv` — async trait: `read_file`/`write_file`/`exec`/
  `glob`/`grep`, all bounded (`max_lines`/`max_bytes`/`max_matches`/`limit`).
- `fluers_runtime::LocalSessionEnv::new(root, limits)` — **canonicalizes the
  root; `validate_path` checks `starts_with(&self.root)` → path-containment-ONLY**
  (fluers `local_env.rs` comment: it is **not** an OS sandbox — it "prevents
  accidental path escape" but is "not a defense against a determined adversary";
  OS isolation is on fluers' SECURITY.md roadmap). This is the load-bearing
  reason A2's `PathPolicy` layer is mandatory, not optional defense-in-depth.
- `fluers_runtime::{Limits, Skill}` — `Skill` is frontmatter-parsed markdown
  (`name`/`description`/`body`/`source`). The integrity'd loader is **A2.5**, not
  A2 (§1); A2 uses only the native tools, not Skills.
- `fluers_runtime::tool::mvp_tools_with_limits(env, limits)` → the native toolset.

### 3.2 Fae governance surface (what A2 composes)

- **`fae_control_plane::authorize(client: &ClientRecord, cmd: &Command, now_ms: u64)
  -> AuthzDecision`** (`fae-control-plane/src/lib.rs:416`). `AuthzDecision::{Allow,
  ConfirmRequired, Deny(DenyReason)}`. `Scope::{ToolExecuteSafe,
  ToolExecuteDangerous}` are the relevant scopes. **This is the canonical scope
  check — A2 reuses it, does not reimplement it.**
- **Egress membrane:** `fae_pii_membrane::{should_block_remote_egress(text),
  scan(text) -> ScanResult}` (`fae-pii-membrane/src/lib.rs`). Precedent:
  `assert_agent_egress_gates` (`session.rs:594`) — but that is **prompt-shaped**;
  A2 must NOT copy it blindly (see §5.4).
- **`DamageControlPolicy` / `PathPolicy` — VERIFIED ABSENT as concrete types.**
  They appear only as *conceptual layers* (doc comments / ADR references) and in
  the spike's stand-in `PathContainmentPolicy`. **A2 must DEFINE Fae-owned policy
  layers** (or extract them later if found). This is scope, not a gap to paper
  over.
- **Audit sink:** control-plane writes fail-closed audit rows today (audit.jsonl
  pattern in session.rs/conductor). A2 needs a ToolHost-specific audit file
  (OPEN-Q2) — never `fae.db`/`MemoryOrchestrator` (storage isolation invariant).

## 4. Two silent-allow traps (load-bearing safety notes)

### 4.1 The `Confirm` trap

fluers A0's `policy_check` treats `PolicyVerdict::Confirm(reason)` as
**allow-with-log** (a confirmation channel is out of scope for the loop itself).
**Therefore:** A2's `FaeToolPolicy` MUST map `AuthzDecision::ConfirmRequired`
(dangerous tools) → `PolicyVerdict::Deny("dangerous tool requires confirmation
not yet available")` **until A3 lands a real confirmation channel**. Returning
`PolicyVerdict::Confirm` would *silently allow* every dangerous tool — a
governance bypass. This fail-closed mapping is a hard A2 invariant, tested
explicitly + mutation-guarded.

### 4.2 The egress-gate trap (oracle BLOCKER-1)

`assert_agent_egress_gates` (`session.rs:594`) checks **three** gates, not one:
1. **mode/lane** — `mode_permits_lane(mode, PrivacyLane::CloudBacked)`;
2. **PII** — `should_block_remote_egress(prompt)` (+ `scan` for detail);
3. **provisioning** — `workers.is_provisioned(worker_id)` + locality match.

A2's networked-tool egress gate MUST run **all three** equivalents on the tool
input — never the PII scan alone. A clean `fetch_url`/`web_search` input with no
sentinel would otherwise be **allowed even when cloud egress is disabled or the
worker isn't provisioned**. **Until the full tool-shaped egress wrapper exists,
ALL networked tools fail-closed** (§5.2 step 5). This is a hard A2 invariant,
tested explicitly (mode-off denies, unprovisioned denies, clean-URL-but-gated
denies).

## 5. Design — `FaeToolPolicy` governance pipeline

### 5.1 Structure

```rust
// crates/fae-daemon/src/toolhost/policy.rs (new)
pub struct FaeToolPolicy {
    gov: Arc<ToolHostGovernance>,
}

/// Run-scoped governance state missing from fluers' `InvokeContext`.
/// Held in an `Arc` so the `&self` policy impl can read it per-call.
pub struct ToolHostGovernance {
    client: ClientRecord,           // control-plane identity for authorize()
    audit: ToolHostAuditSink,       // fail-closed audit (file path + writer)
    session_root: PathBuf,          // the LocalSessionEnv root (for PathPolicy)
    egress: ToolEgressConfig,       // networked-tool gate config
    clock: fn() -> u64,             // now_ms for authorize()
}
```

### 5.2 Pipeline order (in `check()`)

1. **Classify** the tool by name → risk class (oracle MAJOR-2: explicit table).
   **Any unknown tool name → Deny (fail-closed).**

   | Tool | Risk class | Control-plane scope | Path field? | Notes |
   |---|---|---|---|---|
   | `read` | `Read` | `tool.execute_safe` | `input["path"]` | read-only |
   | `glob` | `Read` | `tool.execute_safe` | `input["pattern"]` | read-only (fluers uses `pattern`, not `path`) |
   | `grep` | `Read` | `tool.execute_safe` | every `input["paths"]` array entry | read-only (fluers uses `pattern`+`paths`) |
   | `write` | `Write` | `tool.execute_dangerous` | `input["path"]` | ConfirmRequired→Deny (§4.1) |
   | `edit` | `Write` | `tool.execute_dangerous` | `input["path"]` | A2-pre (fluers v0.3) |
   | `bash` | `Shell` | `tool.execute_dangerous` | n/a | ConfirmRequired→Deny + DamageControl |
   | (networked stub) | `Networked` | `tool.execute_safe` ✏️rev4 | n/a | egress gate IS the authorization (see note below) |
   | any other | `Unknown` | — | — | **Deny** (deny-until-classified) |

   > **✏️ Rev 4 deviation (owner-accepted, post oracle `ec0c3a17`):** networked
   > tools map to `tool.execute_safe`, NOT `tool.execute_dangerous`. The signed
   > table (rev 3) said `dangerous`, but that made the §5.2 step-5 egress gate
   > **structurally unreachable**: `authorize()` returns `ConfirmRequired` for
   > any dangerous command when the client holds the scope (control-plane
   > `lib.rs`), and we map `ConfirmRequired`→`Deny` (§4.1); an unscoped client
   > hits `MissingScope`. Either way step 5 (egress) is dead code — contradicting
   > "egress wired from day one." A networked tool's risk is *egress* (data
   > leaving the device, gated by the membrane), not local destruction (gated by
   > the confirm flow), so the egress gate is the correct authorization. Safe
   > today: `DisabledGate` (the A2 prod default) denies ALL networked tools. A
   > future safe-scoped client + an allowing adapter still needs mode-on +
   > PII-clean + provisioned-worker (the 3 gates). OPEN-Q3 may yet introduce a
   > dedicated `Scope::ToolExecuteNetworked` in A3; until then `safe`+gate is
   > the model.

2. **Control-plane `authorize`** with the mapped command (`tool.execute_safe` or
   `tool.execute_dangerous` per the table — OPEN-Q3 on exact names). Map:
   - `Allow` → continue.
   - `Deny(reason)` → `PolicyVerdict::Deny` + audit (`decision: Denied`,
     `reason: missing_scope`/etc.).
   - `ConfirmRequired` → **`PolicyVerdict::Deny` + audit** (the §4.1 trap).
3. **PathPolicy** (Fae-owned, new): for path-bearing tools, run the **per-tool
   path extractor** (oracle MAJOR-1) — `read`/`write`/`edit` → `input["path"]`;
   `glob` → `input["pattern"]`; `grep` → every entry in `input["paths"]` — but
   `paths` is **optional** in fluers (`("paths","array",false)`), so an **absent
   `paths` is a legitimate path-less search** of the contained root (allow;
   `LocalSessionEnv` bounds the search to the root), NOT a deny. The extractor
   exists and returns "no paths to check"; deny-until-extractor is for tools that
   *should* carry a path but have no extractor defined at all. **A
   path-bearing tool with no extractor → Deny** (deny-until-extractor, so a new
   path field can't silently fall through). Each extracted path is rejected if
   absolute (`/`), root-anchored, contains `..`, backslashes (Windows escape),
   or drive-like (`C:`). Deny + audit on violation. *Defense-in-depth ahead of
   `LocalSessionEnv`'s own containment (accidental-escape-only).*
4. **DamageControl** (Fae-owned, new): for `bash`, deny clearly-dangerous
   patterns (`rm -rf /`, `dd of=/dev/`, `:(){:|:&};:`, `mkfs`, `chmod -R 777 /`,
   redirects to device nodes). **Coarse denylist, not a sandbox** — the real
   sandbox is fluers' (future) OS isolation; A2's layer is the "obviously
   catastrophic" filter the policy hook exists to enforce.
5. **Networked-tool egress gate — full 3-gate wrapper** (§4.2, oracle BLOCKER-1).
   For `Networked` tools: run **all three** gate equivalents on the bounded known
   fields (`url`/`query`), mirroring `assert_agent_egress_gates`: (a) mode/lane
   via `mode_permits_lane(mode, CloudBacked)`; (b) PII via
   `should_block_remote_egress` + `scan` on the extracted field; (c) provisioning
   via `workers.is_provisioned(worker_id)` + locality. **Until this wrapper
   exists, ALL networked tools fail-closed** (Deny + audit). Real `web_search`/
   `fetch_url` land via P7 skills on A2.5; A2 ships a stub networked tool only to
   prove the gate fires on all three paths.
6. **Allow + audit** (`decision: Allowed`).

### 5.3 Audit schema (OPEN-Q2 — provisional)

`toolhost_audit.jsonl` (oracle MINOR-2: dropped the misleading `conductor_`
prefix — ToolHost is deliberately outside `conductor/`; sibling to the
conductor telemetry files in the same daemon store dir, **never** `fae.db`).
One row per policy decision:

```json
{"event_type":"tool_policy","ts_ms":…,"tool":"write","call_id":"…",
 "decision":"Allowed|Denied","reason":"…","risk_class":"Write"}
```

Fail-closed: a write failure aborts the decision (deny), matching the
conductor's audit discipline.

### 5.4 The tool-egress gate: `assert_agent_egress_gates` translated to tool inputs

That function (`session.rs:594`) is **prompt-shaped** — it scans a prompt string
for PII *and* checks mode + provisioning. A2's gate runs the **same three gates**
(§4.2) but on the **bounded known fields** of structured tool inputs, not a
prompt blob: mode/lane and provisioning are tool-host-level (not field-shaped);
the PII scan runs on the extracted `url`/`query` only. This avoids (a)
serializing arbitrary JSON as "prompt text" (semantically wrong + could smuggle
fields past the PII scan) and (b) letting a crafted `url` bypass it. Until the
full 3-gate wrapper exists, networked tools fail-closed (§5.2 step 5).

## 6. ToolHost module layout (provisional)

```
crates/fae-daemon/src/toolhost/
├── mod.rs          # ToolHost struct: owns LocalSessionEnv + tool registry + execute()
├── policy.rs       # FaeToolPolicy + ToolHostGovernance + the §5.2 pipeline
├── path_policy.rs  # the Fae-owned path-escape layer (per-tool extractors, §5.2 step 3)
├── damage.rs       # the Fae-owned damage-control denylist (§5.2 step 4)
├── egress.rs       # the 3-gate tool-egress wrapper (§5.2 step 5, §5.4)
└── audit.rs        # ToolHostAuditSink (fail-closed JSONL; never fae.db)
```

(SkillHost + `skill.rs` move to A2.5.) The dormant `toolhost.rs` from A1
becomes `toolhost/mod.rs` (the witness moves into a unit test or is removed once
real types land).

## 6.1 The A3 seam — internal `ToolHost::execute` API (oracle MAJOR-3)

A2 **defines but does not wire** the governed entry point A3 (protocol surface)
will call. Raw `fluers_core::Tool::execute` is **not exposed** outside the
ToolHost — tools are only callable through the governed path. Provisional
internal API (A2 implements + unit-tests it; A3 wraps it in the wire protocol):

```rust
// crates/fae-daemon/src/toolhost/mod.rs
pub struct ToolHost { env: Arc<LocalSessionEnv>, tools: Registry, gov: Arc<ToolHostGovernance> }

pub struct ToolHostRequest {
    pub client: ClientRecord,    // how governance state reaches the host
    pub tool: String,
    pub input: serde_json::Value,
    pub call_id: String,
    pub deadline_ms: Option<u64>,
    pub cancel: CancellationToken,
}

pub struct ToolHostResult { pub output: ToolResult, pub audit_id: AuditId }

impl ToolHost {
    /// The ONE governed entry point. Builds a per-call FaeToolPolicy bound to
    /// `req.client`, runs the tool under fluers' run_agent machinery with that
    /// policy, and returns the result + the audit row id. A3 wraps this in
    /// `tool.execute`/`toolhost.execute`; nothing calls raw Tool::execute.
    pub async fn execute(&self, req: ToolHostRequest) -> Result<ToolHostResult, ToolHostError>;
}
```

Open sub-questions folded into OPEN-Q3: session-root selection (per-client?
shared?), and the exact `ClientRecord`→`ToolHostGovernance` binding lifecycle
(A3 owns it; A2 stubs a test-only constructor).

## 7. Open questions (surface, don't solve silently)

- **OPEN-Q1 — RESOLVED (owner, rev 3): A2-pre.** Generic `EditTool` lands in
  fluers (→ v0.3 → Fae re-pin), NOT a Fae-local wrapper. Matches ADR-013 (`edit`
  is a listed fluers deviation) + the "one `Tool` trait" goal. Oracle NOTE-1 concurs.
- **OPEN-Q2 — RESOLVED (owner, rev 3): `toolhost_audit.jsonl`** in the conductor
  store dir (never `fae.db`). Accepted as-is (reviewer-level).
- **OPEN-Q3 — DEFERRED TO A3 (owner, rev 3).** Decided jointly when the protocol
  surface lands. Owner leans recorded: (a) **session-root = per-session/per-client
  ephemeral root** (smallest blast radius) over a shared persistent one — note
  this is security-load-bearing (it IS the sandbox boundary); (b) **command name
  = new `toolhost.execute`** mapped onto the existing `ToolExecuteSafe`/
  `ToolExecuteDangerous` scopes (keeps "execute" distinct from the old broker
  semantics). A2 stubs test-only constructors; A3 owns the real binding lifecycle.
- **OPEN-Q4 — RESOLVED + OWNER-BLESSED (rev 3): fail-closed, NO.** `write`/`edit`/
  `bash` do NOT execute via the daemon ToolHost until A3's confirmation channel
  exists. `ConfirmRequired` → `Deny` is a hard invariant (§4.1), mutation-guarded.
  This is the safety posture — explicitly blessed by owner 2026-06-29.
- ~~OPEN-Q5: SkillHost in A2 or A2.5?~~ **RESOLVED (rev 2): SkillHost → A2.5**
  (oracle MAJOR-4). A2 is native-tool ToolHost only.

## 8. Test plan (A2-body)

- `control_plane_safe_scope_allows_read_glob_grep` — `ToolExecuteSafe` →
  `read`/`glob`/`grep` all allowed (oracle MAJOR-2).
- `control_plane_missing_scope_denies_and_audits` — no scope → Deny + audit row.
- `write_edit_bash_require_dangerous_scope` — `write`/`edit`/`bash` map to
  `tool.execute_dangerous`; with only safe scope → Deny + audit (oracle MAJOR-2).
- `dangerous_tool_confirm_required_maps_to_deny` — the §4.1 trap: `bash` with
  dangerous scope → `ConfirmRequired` → **Deny** (not Confirm) + audit. (Mutation
  guard: changing the mapping to `Confirm` must fail this test.)
- `path_escape_denied_by_fae_policy_before_localenv` — `read` with `../escape`
  → Deny at step 3 (Fae PathPolicy), `LocalSessionEnv` never reached.
- `per_tool_path_extractor_covers_glob_and_grep` — `glob`'s `pattern` and
  `grep`'s `paths[]` escapes are each caught (oracle MAJOR-1).
- `path_bearing_tool_without_extractor_denies` — a new path-bearing tool with no
  extractor → Deny (deny-until-extractor; oracle MAJOR-1).
- `grep_without_paths_runs_path_less` — grep with only `pattern` (no `paths`)
  → **allowed** (path-less search; `LocalSessionEnv` contains it to the root).
  Owner watch-item (rev 3): ensures the deny-until-extractor rule doesn't wrongly
  deny a legitimate path-less grep.
- `local_session_env_still_denies_if_policy_bypassed` — defense-in-depth: a
  test-double allow-all policy + an escape path → `LocalSessionEnv` itself denies.
- `damage_control_denies_catastrophic_bash` — `rm -rf /` → Deny + audit.
- `networked_tool_denied_when_mode_off` — `CloudBacked` lane not permitted →
  Deny (oracle BLOCKER-1 gate a).
- `networked_tool_denied_when_not_provisioned` — worker not provisioned →
  Deny (oracle BLOCKER-1 gate c).
- `networked_tool_sentinel_blocked_by_pii` — a stub networked tool; a sentinel
  secret in `query`/`url` → Deny via `should_block_remote_egress` + audit
  (oracle BLOCKER-1 gate b).
- `networked_tool_clean_input_still_denied_until_wrapper` — **a clean networked
  input is denied** until the full 3-gate wrapper exists (fail-closed, §5.2 step 5).
- `unknown_tool_fails_closed` — unclassified tool name → Deny + audit.
- `every_decision_writes_audit_row` — allow AND deny both produce exactly one row.
- `no_fae_db_created` — ToolHost dir has no `fae.db`; no MemoryOrchestrator ref.
- `raw_tool_execute_not_exposed` — only `ToolHost::execute` is callable; raw
  `fluers_core::Tool::execute` is private to the module (oracle MAJOR-3).
- **Gates:** fmt; clippy strict (`-D warnings` + panic/unwrap/expect); `cargo
  check --workspace --all-targets`; fae-daemon tests; mesh + metaopt boundary
  guards green. (No `swift build` in A2 — no Swift change until A3.)

## 9. Explicitly OUT of A2 scope

- ❌ Protocol surface / `tool.execute` wiring / Swift routing (A3).
- ❌ Live bundled-app proof (A4).
- ❌ Loop relocation / conductor-as-`ModelProvider` / `RemoteSwiftTool` (Vision B).
- ❌ R5 `ToolProgramRuntime` (rquickjs) — follow-on, parallels P7.
- ❌ OS-level sandbox isolation (seatbelt/landlock) — fluers' own SECURITY.md
  roadmap; A2 relies on the policy hook + `LocalSessionEnv` containment until then.
- ❌ M6-C/D/F (Track 1, deferred for Vision A).

## 10. Acceptance (A2-body done when)

1. `FaeToolPolicy` composes control-plane `authorize` + PathPolicy + DamageControl
   + the **3-gate** tool-egress wrapper, in the §5.2 order, with the §4.1
   fail-closed `Confirm` mapping.
2. The tool-egress gate checks **mode + PII + provisioning** on bounded extracted
   fields (§4.2); until it exists, networked tools fail-closed.
3. Every decision (allow + deny) writes a fail-closed audit row; nothing reaches
   `fae.db`.
4. The test plan (§8) passes, incl. mutation guards on the `Confirm` trap, the
   per-tool path extractors, and the egress-gate's three gates.
5. Gates green; boundary guards intact.
6. A2 defines (but does not wire) the governed `ToolHost::execute` seam A3 calls
   (§6.1); raw `Tool::execute` is not exposed.

## 11. Risks

- **The policy hook is the only pre-execution gate.** `LocalSessionEnv` is
  accidental-escape-only. A2's PathPolicy/DamageControl carry the real safety
  weight until OS isolation lands in fluers. If a path extractor is missed, a
  path-bearing tool now **Denies** (deny-until-extractor, oracle MAJOR-1) rather
  than falling through — the weak `LocalSessionEnv` is no longer a silent
  fallback for known path tools. Mitigated by the test double (§8) + the
  deny-until-extractor rule.
- **`Confirm` silently allowing** is the highest-impact bug. Mitigated by the
  explicit fail-closed mapping (§4.1) + its mutation test.
- **Egress-gate field extraction** — a too-loose extraction could let a crafted
  `url` bypass the PII scan, or a clean input slip through when mode/provisioning
  are off. Mitigated by (a) the full 3-gate wrapper (§4.2), (b) bounded
  known-field extraction only (§5.4), (c) the three separate egress tests + the
  clean-input-still-denied-until-wrapper test (§8).
- **ToolHost-vs-conductor boundary drift.** ToolHost lives outside `conductor/`;
  the mesh/metaopt boundary guards don't cover it. A2 must not accidentally pull
  conductor internals into the ToolHost (or vice versa). Mitigated by keeping
  the dependency direction one-way (ToolHost may call control-plane/conductor
  governance APIs; conductor must not depend on toolhost).
- **Tool-input egress gate shape.** A too-loose field extraction could let a
  crafted `url` bypass the scan. Mitigated by bounded known-field extraction only
  (§5.4) + the sentinel test.
- **`proptest` in fluers 0.2.0's non-dev deps** (flagged in A1) adds compile
  footprint but no correctness risk.

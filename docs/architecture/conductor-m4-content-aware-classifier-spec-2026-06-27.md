# Conductor M4 — Content-Aware Task Classifier (F-4/n boundary crossing)

**Status:** spec (not yet implemented). **Date:** 2026-06-27.
**Milestone:** M4 (new — not an M3 continuation). Supersedes the "someday" classifier
placeholder; this is the milestone elevated to M3's critical path by the M2 spec (§2.6)
and the execution-plan Sequencing gate.
**Authoritative tracker:** `TODO-8ef3d7e7` — **[SEQUENCING GATE] Content-aware classifier
before any live mutation.**

> **Process rule:** spec → advisor review → implement → advisor completion review → real
> gates. Per the owner's reliability directive (2026-06-27), broad internal subagent review
> is **skipped** for this milestone; acceptance rests on direct source verification + the
> advisor + the real gate suite (fmt/clippy(-D)/check/tests). External (codex) review
> optional at the owner's request.

---

## §0. What this is, and the one boundary it crosses

M2 wired reward + shadow capture into the live local turn loop, but the **routing-accuracy
dimension is degenerate**: the live `ConductorTurnContext` is built content-blind
(`task_class = Unknown`, `feature_predicates = []`), so `shadow::match_corpus_entry`
— which requires `entry.feature_predicates ⊆ ctx.feature_predicates` — matches **zero**
corpus entries ⇒ `corpus_match = None` for every turn (M2 spec v3 MAJOR-1, verified in
source: `policy.rs:117-118`, `shadow.rs:104-108`, `executor.rs:2091-2094`). The conductor
cannot measure "did we route well" because it never classifies the turn.

M3 shipped the MetaOpt self-mutation surface **dormant/offline/CLI-only** precisely because
this dimension is absent: a live optimizer would mutate routing recipes against proxy signal
only and plateau. **The classifier is the real unlock for M3's central job** (M2 spec §2.6).
It is the hard gate recorded in the execution plan: *"The content-aware task classifier is a
hard prerequisite for any live mutation loop"* (owner directive 2026-06-25).

**This milestone adds exactly one component that reads prompt text** — the designated
F-4/n boundary-crossing surface. Everything else in the conductor remains content-blind.

### The F-4 / "n" boundary statement (load-bearing)

F-4 (redacted as `n` in docs) is: **the routing policy does not read prompt text.**
Authoritative sources:
- `conductor/policy.rs` module doc + `StaticDirectPolicy::classify` doc: *"Coarse classifier
  over non-content metadata only. Reads no prompt text."*
- `conductor-m1-static-recipes-spec`: *"The policy is content-blind: it does not read prompt
  text at all."*

The egress-scope §0 framing (owner 2026-06-23) is consistent with a **local** classifier:
*"conversation context never leaves the machine for the purpose of making the routing
decision."* Classification **is** routing reasoning; doing it on-device is exactly the
security model. The classifier:

1. **Runs local-only.** Never cloud, never egress. No `fae-engine`/mistralrs call in the
   MVP — it is a pure, synchronous, deterministic function over the prompt string.
2. **Emits only labels** — a `ConductorTaskClass` enum variant + an allowlisted
   `Vec<String>` of predicate names + a source/version tag. **Never** the prompt text, a
   prompt hash, or a prompt fingerprint.
3. **Is the sole designated content-reader.** The policy stays content-blind; it consumes
   the classifier's *label*, not the prompt. This preserves F-4 for the policy while
   crossing it in exactly one audited place.

---

## §1. Design — live classification, NO live routing-authority change

**Decision (advisor-directed):** the classifier populates the **normal**
`ConductorTurnContext` before `route_turn` — not a shadow-side parallel context. A
shadow-only design would defer the real F-4 crossing to a side-channel; this milestone
crosses it honestly on the live path. The label is in the live context.

**The route does not change today**, and an acceptance test proves it: `StaticDirectPolicy`
is M1-inert to `task_class` (always `direct` + `local-model` + `ApprovalClass::None`),
so populating `task_class` lights up shadow/corpus/reward **without** touching egress. The
*only* reason egress is unchanged is the policy's current inertness — which is asserted, not
assumed. When a future recipe keys on `task_class` (post-M4, post-M3-live-gate), the label is
already on the live path where it needs to be.

### Components (new module `crates/fae-daemon/src/conductor/classifier.rs`)

```rust
/// A stable, allowlisted feature-predicate name emitted by the classifier.
/// Fixed vocabulary — aligned to the eval corpus so `match_corpus_entry` can hit.
/// `as_str()` is the serialized form; never emit free-form strings.
pub enum FeaturePredicate { /* see §3 vocabulary */ }

/// The output of classifying a turn. Labels only — never prompt content.
pub struct TurnClassification {
    pub task_class: ConductorTaskClass,
    pub feature_predicates: Vec<String>,  // sorted, deduped, allowlisted
    pub source: ClassifierSource,         // rule-based v1, etc.
}

/// Classify a turn's prompt text. The ONE designated F-4/n content-reader.
/// Pure + infallible by construction: any failure path fails closed to
/// `Unknown + []` (never panics, never returns Err on the hot path).
pub trait TurnClassifier: Send + Sync {
    fn classify(&self, prompt: &str) -> TurnClassification;
}

/// Deterministic rule-based MVP. No model, no async, no I/O, no cloud.
pub struct RuleBasedTurnClassifier { /* version tag */ }
impl TurnClassifier for RuleBasedTurnClassifier { /* rules in §3 */ }
```

The classifier is **constructed once** (a `Default`/const, held by the runtime or built in
`build_turn_context`) — there is no per-turn allocation cost beyond the classification itself.

### Why rule-based, not the local LLM (MVP)

The milestone's discipline is **deterministic + heavily tested** (M3's prompt lint is pure
functions with 19 tests; the boundary guard is mutation-tested). A mistralrs LLM classifier
is non-deterministic, latency-bearing, hard to gate, and hard to property-test. The
`TurnClassifier` **trait** is the upgrade surface: a future `LlmTurnClassifier` impl (behind
the same trait, local-only) is an additive change that does not alter wiring or the F-4
contract. The MVP ships the trait + the deterministic impl so the boundary crossing, the
wiring, and the corpus-match unlock are all proven before any model is involved.

---

## §2. Wiring — `session::build_turn_context`

**The single live wiring site:** `session.rs:build_turn_context(cmd: &Command)` (called at
`session.rs:1508`, inside the `inject_text` → `Some(runtime)` branch, immediately before
`route_turn`). Today it hardcodes `task_class: Unknown, feature_predicates: Vec::new()`.

The change:
1. Extract the prompt text: `cmd.payload.get("text").and_then(Value::as_str)` — the same
   extraction `parse_tts_payload` uses (session.rs:1213). If absent (non-`inject_text`
   command, or no text field), the classifier input is `""` ⇒ classifies to `Unknown + []`
   (fail-closed, no behavior change for non-text turns).
2. `let cls = classifier.classify(prompt);`
3. Populate `task_class: cls.task_class, feature_predicates: cls.feature_predicates`.

The change is a **low-blast-radius helper split** (no new fields on `ConductorRuntime` or
`SessionBackends` in M4):

```rust
fn build_turn_context(cmd: &Command) -> ConductorTurnContext {
    build_turn_context_with_classifier(cmd, &RuleBasedTurnClassifier::default())
}

fn build_turn_context_with_classifier(
    cmd: &Command,
    classifier: &impl TurnClassifier,
) -> ConductorTurnContext { /* extract text → classify → populate existing fields */ }
```

The existing `build_turn_context(cmd)` call site (session.rs:1508) is unchanged — it now
delegates. The `_with_classifier` variant is the test seam (acceptance tests inject a fixed
classifier). **No classifier field is added to `ConductorRuntime`/`SessionBackends`** unless a
later slice requires it. `TurnClassification.source/version` stays on the classification
object — it is NOT added to `ConductorTurnContext` (only the already-existing `task_class` +
`feature_predicates` fields are populated); if classifier-source needs to be observed, it rides
on **shadow telemetry** specifically, not on the live context or the event/receipt schemas.

### What does NOT change

- `route_turn` signature and body (it receives a populated `ctx`, as today).
- `StaticDirectPolicy::decide` (still returns `direct`+`local-model`+`None` regardless of
  `task_class`). **Asserted by acceptance test, not assumed.**
- The executor, the §5 gate pipeline, the shadow capture path (they consume `ctx` as today).
- The byte-identical-direct safety contract (the conductor's `direct` arm still runs
  `inject_text_core` verbatim).

---

## §3. Predicate vocabulary (fixed, allowlisted, corpus-aligned)

`match_corpus_entry` requires `entry.feature_predicates ⊆ ctx.feature_predicates`. So the
classifier's emitted vocabulary must **include** the eval-corpus predicate names for a match
to be possible. The corpus today uses fixture names like `"credential_shaped_fixture"`
(eval.rs:753). The classifier vocabulary is a fixed `enum FeaturePredicate` with `as_str()`,
**not** free-form strings — output is sorted, deduped, and every element is a known variant.

Initial vocabulary (small, aligned to advisor list + corpus):

| Predicate | Fires when | Aligns to |
|---|---|---|
| `has_codeblock` | fenced ``` ``` ``` block present | Coding corpus |
| `has_inline_code` | `` `code` `` spans present | Coding corpus |
| `has_file_path` | path-shaped token (`/`, extensions) | Coding/ToolUse |
| `tool_request` | imperative tool/commands ("run", "execute", "install", "build") | ToolUse |
| `planning_shaped` | planning/step/decomposition language | Planning |
| `research_shaped` | research/search/cite language | Research |
| `personal_data_shaped` | first-person personal content (health, finance, relationships) | PersonalData |
| `credential_shaped` | secret/key/token patterns | PersonalData + corpus |
  (**canonical** name; the eval fixture `credential_shaped_fixture` is migrated to this — see §3.1) |
| `long_prompt` | `prompt.len()` above a threshold | budget/corpus `len>` fixtures |

`task_class` derivation from predicates is a deterministic precedence (e.g. `credential_shaped`
⇒ `PersonalData`; `has_codeblock` ∨ `has_inline_code` ⇒ `Coding`; else `Chat`). No predicate
⇒ `Unknown`.

### §3.1 Corpus ↔ classifier vocabulary alignment (exact-match requirement)

`shadow::match_corpus_entry` requires an **exact string subset** match
(`entry.feature_predicates ⊆ ctx.feature_predicates`, string equality). The classifier
vocab above is the **canonical** set. The eval corpus fixture at `eval.rs:753` currently
uses the name `credential_shaped_fixture` — a fixture-era spelling that will NOT subset-match
the canonical `credential_shaped`.

**Resolution (part of M4-A):** the corpus is synthetic test data (not production data), so
the fixture predicate is **migrated** to the canonical name `credential_shaped` (and any
other fixture names that don't match a canonical variant are aligned at the same time).
This is the whole point of a fixed, shared vocabulary. The acceptance test (§5.4) proves the
**exact shared string** flips `corpus_match` `None → Some`. The canonical names are the
contract; both sides converge on them.

---

## §4. Non-goals (explicit)

- **No scheduler task, no auto-deploy, no live mutation loop.** (M3's dormant posture holds;
  this milestone does not open it — the classifier is the *prerequisite*, not the opener.)
- **No recipe-mutation use.** The classifier populates the *turn context*; it does not touch
  recipes, MetaOpt, or `recipe_mutation.rs`.
- **No cloud/egress.** Local-only, synchronous, no network.
- **No prompt persistence (scoped to the conductor surface).** The prompt text is read,
  classified, and dropped. M4 must not add prompt text to **conductor-specific**
  telemetry/store — the shadow records, conductor events/receipts, and classifier
  metadata. Only the **labels** (`task_class`, predicate names, source) appear there.
  (The raw control-plane frame / session audit may already contain `cmd.payload.text`
  by design — M2 spec v2 fix #2: "the raw frame still enters the audit log by design."
  M4 does not change that and does not claim the global audit is prompt-free; the
  acceptance grep targets the **conductor** JSONL/store, not the raw session audit.)
- **No prompt fingerprints / hashes.** (M2's `RequestFingerprint` is HMAC of the opaque
  `request_id`, unchanged; the classifier adds no content-derived hash.)
- **No LLM classifier in the MVP.** Trait is the upgrade surface; `mistralrs` impl is later.
- **No route worker/topology/lane change.** Proven by the inert-policy acceptance test.
- **No new config keys / no new control-plane commands.** The classifier is constructed in
  code; nothing user-configurable this milestone.

---

## §5. Acceptance tests (required)

1. **Rule fixtures → expected `ConductorTaskClass`.** A coding prompt (code fence) ⇒
   `Coding`; a planning prompt ⇒ `Planning`; a research prompt ⇒ `Research`; a personal-data
   prompt ⇒ `PersonalData`; an empty/greeting prompt ⇒ `Chat` or `Unknown`.
2. **Predicates are sorted, deduped, and allowlisted.** A prompt firing the same predicate
   twice emits it once; output order is deterministic; every element is a known
   `FeaturePredicate::as_str()`.
3. **No prompt text in conductor telemetry.** Build a classified turn whose prompt carries a
   unique sentinel string; assert the **conductor** JSONL/store files written for that turn
   (shadow record, event, receipt) contain `task_class` + predicate names but **no substring
   of the sentinel prompt text**. (Scoped to the conductor surface — the raw session audit is
   out of scope; see §4.)
4. **`corpus_match` flips `None → Some`.** A classified turn whose predicate set (canonical
   names) ⊇ a corpus entry's predicates (canonical names, post-§3.1 migration) produces
   `Some(CorpusMatch)` where the content-blind baseline produced `None`. The **exact shared
   string** is what flips it — proving corpus↔classifier vocab alignment.
5. **`StaticDirectPolicy` authority fields are identical** for a classified context vs an
   `Unknown + []` context: same `recipe_id`, `topology` (Direct), `worker_id` (local-model),
   `lane` (LocalOnly), `approval` (None), `reason`. **`task_class` is metadata and is expected
   to DIFFER** (Unknown → classified) — it is explicitly excluded from the equality assertion.
   Asserting the authority-carrying fields is the no-egress-change proof.
6. **Fail-closed path:** a missing/empty/non-text payload ⇒ `Unknown + []` (no panic, no
   `Err` on the hot path). The classifier is infallible by construction.
7. **Standard gate hygiene:** no production `unwrap`/`expect`/`panic!`; `cargo fmt`;
   `cargo clippy -p fae-daemon --all-targets -- -D warnings -D clippy::panic
   -D clippy::unwrap_used -D clippy::expect_used`; `cargo check --workspace --all-targets`;
   `cargo nextest run -p fae-daemon`; boundary guard still green.

---

## §6. Slice plan (tentative — finalized post-spec-review)

- **M4-A (dormant surface):** `classifier.rs` — `TurnClassifier` trait +
  `RuleBasedTurnClassifier` + `TurnClassification` + `FeaturePredicate` vocab + tests 1, 2, 6.
  Constructed nowhere outside tests (dormant, like M3-B). No wiring.
- **M4-B (live wiring + inert-proof):** wire `build_turn_context` to call the classifier;
  tests 3, 4, 5 (no-prompt-in-telemetry, corpus_match flip, inert-policy proof); full gate.

Two slices. Small milestone. The classifier hard-gate (TODO-8ef3d7e7) closes when M4-B is
merged — at which point M3's live-mutation loop becomes *eligible* to open (still a separate,
owner-gated decision).

---

## §7. Predecessors & references

- **Predecessors:** M2-live (reward + shadow capture, COMMITTED); M3 (dormant MetaOpt
  mutation surface, COMMITTED); the M2 spec §2.6 classifier-on-critical-path finding.
- **Wiring sites (verified):** `session.rs:1508,1521` (`build_turn_context`, the plug-in
  point); `session.rs:1213` (`cmd.payload.get("text")` extraction pattern); `policy.rs:87-90`
  (`classify`, content-blind); `shadow.rs:104-108` (`match_corpus_entry` subset rule);
  `executor.rs:2091-2094` (the named content-blind gap).
- **Boundary docs:** `egress-scope-and-stage3-hold-2026-06-23.md` §0 (local-coordinator
  security model); `conductor-m1-static-recipes-spec` (F-4/n).
- **Execution plan:** `fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md`
  Sequencing (classifier hard gate).

# M5 — Release-Validation Hardening (F-6 / F-9 / F-15)

**Status:** DRAFT (pre-advisor)
**Date:** 2026-06-27
**Owner:** David Irvine
**Predecessors:** M2-live (`7e63d567`), M3 (`7df3552c`), M4 classifier (`acdd04af`, all on `origin/main`)
**Plan ref:** `docs/plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md` → "After M3 → M5"

---

## 1. Goal

Three milestones of conductor work (M2 reward+shadow live wiring, M3 recipe-mutation surface, M4
content-aware classifier) have shipped to `origin/main` without the release-validation gate being
**enforced**. Today the gate is *decorative*: a markdown checklist an author must remember to read,
referenced from an `AGENTS.md` that points at a file that does not exist.

M5 promotes the invariant to CI **before** the next egress-expanding milestone (x0x-sync / live
mutation), per the gate-first principle that has governed every prior slice (boundary guard before
wiring; denylist before the surface; classifier before live mutation).

**M5 is hardening only.** No new egress, no live mutation, no new routing behavior, no classifier
upgrade.

## 2. Scope — the three findings

### F-9 (MAJOR): Doc drift — broken checklist references

**Problem:** `AGENTS.md` §"Release validation is mandatory" (lines ~222–231) instructs authors to
treat `docs/checklists/app-release-validation.md` as a required gate and to update
`docs/checklists/main-and-cowork-live-test-scenarios.md` in the same change. The second file **does
not exist** (CoWork was removed in the Great Cleanup, 2026-06-11). An author following the
instructions literally either creates a stray file or silently skips the step.

**Fix (surgical — no checklist rewrite):**
1. Edit `AGENTS.md` §"Release validation is mandatory": remove the broken reference to
   `main-and-cowork-live-test-scenarios.md`. State that the live-scenario script is **absorbed into**
   `docs/checklists/app-release-validation.md` (per the research note: "absorb into
   app-release-validation.md + update AGENTS.md"). Do **not** recreate the CoWork-era file.
2. Add a one-line note to `docs/checklists/app-release-validation.md` confirming it is the single
   canonical release-validation artifact (checklist + live-scenario script).
3. Add conductor/classifier/routing/reward/mutation-surface changes to the checklist's "When this
   contract is mandatory" trigger list (currently absent — the conductor shipped without the
   checklist knowing it exists).

**Explicitly NOT in scope:** rewriting the 318-line Swift-native checklist body. The Swift app is a
still-valid migration surface; its checks remain legitimate for Swift changes. ADR-011 makes the
Rust core canonical, but the checklist's Swift sections are not *wrong* — they're *legacy*. Rewriting
them risks errors for no safety gain and is a separate, larger effort.

### F-6 (MAJOR): Release gate decorative → enforced

**The enforcement model, stated honestly:**

The release-validation contract is ~70% **manual**: real audio capture/playback, VoiceOver passes,
screenshots, UI interaction. CI cannot automate a VoiceOver pass. Therefore "enforced" means **two
layers**, not magic automation:

| Layer | What | How | Enforced by |
|---|---|---|---|
| **Automatable** | Rust workspace gates (fmt/clippy/test/check), boundary guard, comprehensive harness phases (`--skip-llm`) | CI workflow (already mostly in `ci-linux.yml`) | GitHub "required check" (owner-configured branch protection) |
| **Manual** | Real audio, screenshots, UI/VoiceOver passes | **PR attestation** — the author must declare, per PR, that they ran the relevant manual checks (with evidence links) or explicitly waive with a reason | A PR-body checker + PR template |

The repo code supplies the **workflow + template + checker**. The actual branch-protection "required
check" toggle is configured out-of-band by the repo owner (it cannot be set from a commit). The spec
calls this out explicitly so "enforced" is not over-claimed.

**Deliverables:**
1. `.github/PULL_REQUEST_TEMPLATE.md` — a "Release validation" section with three mutually-exclusive
   options:
   - **Not applicable** + one-line reason (e.g. "docs-only, no runtime/UI/policy change").
   - **Applicable + completed** + evidence links (screenshot root, comprehensive JSON report path).
   - **Applicable, not release-ready** + blocker/issue link (the PR is explicitly not for release).
2. `scripts/ci/guard-release-validation-pr.py` — a dependency-free checker (stdlib only, so it runs
   on any runner without `pip install`). It enforces **exactly one** of three stable,
   machine-readable checkboxes (pre-filled by the PR template) **AND** that the selected option's
   required field is non-empty after stripping HTML-comment placeholders:
   - `[x] Release validation: N/A` + a non-empty `Reason:` (placeholder `<!-- ... -->` does not count).
   - `[x] Release validation: done` + non-empty `Evidence:`.
   - `[x] Release validation: blocker` + a non-empty `Blocker/issue:` link.
   - **Zero checked → FAIL.** **Two or more → FAIL** (ambiguous). **Null/empty body → FAIL.**
   - **Checked but required field missing/empty/placeholder-only → FAIL.** The field is
     validated **only in the selected option's own following block** (from the checked line
     until the next checkbox), so a field label appearing elsewhere (e.g. the PR Summary)
     cannot mask a placeholder — enforced by the `invalid-na-cross-section` fixture.
   - Reads `$GITHUB_EVENT_PATH` (the PR webhook payload) in CI mode; `--self-test` runs 12 built-in
   fixtures (valid-N/A, valid-done, valid-blocker, invalid-empty, invalid-none, invalid-multiple,
   invalid-unchecked, invalid-na/done/blocker-placeholder, invalid-na-no-field,
   invalid-na-cross-section) without a real PR.
3. `.github/workflows/release-validation.yml` — a **separate** workflow (NOT in `ci-linux.yml`, which
   has path filters that would miss docs/template-only PRs):
   - `pull_request` → run `guard-release-validation-pr.py` (the attestation check).
   - `pull_request`/`push` → run a small docs guard asserting `AGENTS.md` references resolve to
     files that exist, and the PR template is present (catches future F-9 regressions).
   - No path filter (runs on every PR — the attestation must appear even for a one-line doc fix,
     which is the whole point: the author decides N/A and says why).

### F-15: Recipe defense-in-depth — `deny_unknown_fields` + recipe-level rejection

**Problem:** `ConductorTopology` already makes `star`/`debate` compile-time-unreachable (enum has
only `Direct`/`Chain`), and an existing test (`serde_rejects_unknown_topology`) proves the enum
rejects `"topology":"star"`. But `FaeConductorRecipe` (recipe.rs:247) has **no
`deny_unknown_fields`** — serde's forward-compat default silently accepts unknown top-level fields
(`"star_mode": true`, `"debate_v2": ...`). A future code change that reads such a field would
silently honor attacker/mutation-injected metadata. F-15 closes this at the struct boundary.

**Fix:**
1. Add `#[serde(deny_unknown_fields)]` to `FaeConductorRecipe`.
2. Strengthen the test to cover **recipe-level** (not just enum-level) rejection:
   - `"topology":"star"` in a full recipe JSON → `Err`.
   - `"topology":"debate"` in a full recipe JSON → `Err`.
   - A valid recipe with one extra unknown top-level field → `Err` (the `deny_unknown_fields` proof).
3. Keep exhaustive enum matching — do NOT add a wildcard variant to "catch" star/debate (that would
   *weaken* compile-time exhaustiveness, the opposite of the goal).

**Verified safe:** all recipe construction is via struct literals (no extra fields); the one
round-trip test serializes-then-deserializes (only known fields in the JSON). `deny_unknown_fields`
breaks nothing.

### CI consolidation (bonus, low-risk)

The existing `ci-linux.yml` gates `fae-daemon` + `fae-engine` but **not** `fae-metaopt` (tests) or
the full workspace (`cargo check --workspace --all-targets`). Add to the new
`release-validation.yml` (or `ci-linux.yml` crate-gate step — TBD in impl):
- `cargo check --workspace --all-targets`
- `cargo nextest run -p fae-metaopt`
- strict clippy for `fae-metaopt` (already clean locally).

These already pass locally; this just makes them blocking on Linux CI. Avoid broad
`cargo nextest run --workspace` (platform-sensitive tests).

## 3. Non-goals

- **No rewrite of the Swift-native checklist body.** Surgical F-9 fix only.
- **No live mutation loop, no x0x-sync, no classifier upgrade.** Those are separate owner-gated
  milestones.
- **No branch-protection configuration from code.** That's an owner/GitHub-settings action; the spec
  supplies the artifacts (workflow + template + checker) that branch protection would require.
- **No automation of manual checks.** VoiceOver/audio/screenshots stay human-attested.
- **No new routing behavior.** `StaticDirectPolicy` remains M1-inert.

## 4. Sequencing (slices)

Each slice is independently shippable; per-stage gate is the relevant crate + the new CI scripts.

| Slice | What | Gate |
|---|---|---|
| **M5-A** | F-9 doc drift: `AGENTS.md` fix + checklist trigger-list + canonical-artifact note | docs guard (asserts refs resolve) |
| **M5-B** | F-6 enforcement artifacts: PR template + `guard-release-validation-pr.py` (with `--self-test`) + `release-validation.yml` workflow | `python3 guard-release-validation-pr.py --self-test` (GitHub validates YAML syntax post-push) |
| **M5-C** | F-15 recipe hardening: `deny_unknown_fields` + 3 recipe-level tests | `-p fae-daemon` fmt/clippy/test |
| **M5-D** | CI consolidation: workspace check + fae-metaopt tests in CI | workflow runs green |
| **M5-E** | Plan updates: close F-6/F-9/F-15 checkboxes; mark classifier hard gate satisfied (`acdd04af`); record branch-protection-is-owner-config note | n/a (docs) |

May be combined into fewer commits if small. Order is not load-bearing except M5-A should land before
M5-B's docs-guard (so the guard passes on the fixed refs).

## 5. Test plan

**M5-A (F-9):**
- The new `release-validation.yml` docs guard asserts every `docs/checklists/...` path referenced in
  `AGENTS.md` resolves to an existing file — catching both backtick-wrapped (`` `docs/.../x.md` ``)
  and plain (`docs/.../x.md`) references. After the fix, `main-and-cowork-live-test-scenarios.md`
  is no longer referenced → guard passes. Mutation tests: re-add the broken ref (plain OR
  backticked) → guard fails.

**M5-B (F-6):**
- `python3 scripts/ci/guard-release-validation-pr.py --self-test` exits 0 with 12 fixture cases
  (valid-N/A, valid-done, valid-blocker, invalid-empty, invalid-none, invalid-multiple,
  invalid-unchecked, invalid-na/done/blocker-placeholder, invalid-na-no-field,
  invalid-na-cross-section).
- `python3 scripts/ci/guard-release-validation-docs.py` passes (AGENTS refs resolve + template).
- Manual: the workflow's `pull_request` trigger runs the checker; a PR with no attestation fails, a
  PR with exactly one valid option + non-empty field passes; a placeholder-only or cross-section
  field fails. (Verified locally via `--self-test`; full PR-path verification is the first real PR
  after merge.)

**M5-C (F-15):**
- `serde_recipe_rejects_star_topology` — full recipe JSON with `"topology":"star"` → `Err`.
- `serde_recipe_rejects_debate_topology` — full recipe JSON with `"topology":"debate"` → `Err`.
- `serde_recipe_rejects_unknown_field` — valid recipe + one extra top-level field → `Err`.
- Existing `serde_roundtrip_preserves_recipe` still passes (regression: `deny_unknown_fields`
  doesn't break round-trip).

**M5-D (CI):** the new CI steps run green on Linux (fae-metaopt tests + workspace check pass).

## 6. Acceptance

- [ ] `AGENTS.md` has no broken checklist references; the checklist notes itself as canonical.
- [ ] `.github/PULL_REQUEST_TEMPLATE.md` exists with the three-option release-validation section.
- [ ] `scripts/ci/guard-release-validation-pr.py --self-test` passes (exit 0).
- [ ] `.github/workflows/release-validation.yml` runs the attestation check + docs guard on every PR.
- [ ] `FaeConductorRecipe` has `#[serde(deny_unknown_fields)]`; 3 recipe-level rejection tests pass.
- [ ] CI runs `cargo check --workspace --all-targets` + `cargo nextest run -p fae-metaopt`.
- [ ] Execution plan checkboxes: F-6, F-9, F-15 closed; classifier hard gate marked satisfied.
- [ ] Spec honestly states branch protection is an owner-configured setting, not a code artifact.
- [ ] Standard gates green: `cargo fmt` / `cargo clippy -D warnings` / `cargo check --workspace` /
      `cargo test` / boundary guard.

## 7. Risks

- **PR-body checker false negatives** — a PR with a legitimate attestation phrased differently than
  the checker expects fails. Mitigation: the checker matches on a small set of stable tokens (e.g.
  `[x] Release validation: N/A`, `[x] Release validation: done`, `[x] Release validation: blocker`),
  and the PR template pre-fills them. `--self-test` fixtures cover the happy paths.
- **`deny_unknown_fields` breaks a fixture I didn't find** — low; verified all construction is struct
  literals + one round-trip. Covered by the existing round-trip test as regression.
- **Over-claiming "enforced"** — mitigated by the explicit two-layer table and the branch-protection
  caveat in §2.

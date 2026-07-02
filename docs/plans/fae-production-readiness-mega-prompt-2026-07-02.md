# Fae → Production-Ready + Full Vision — Handoff Mega-Prompt (2026-07-02)

> Paste this whole file as the opening prompt of a fresh Claude Code (Fable) session
> at repo root `/Users/davidirvine/Desktop/Devel/projects/fae`. It is self-contained.
> You are taking over from a deep production-readiness review that just landed on `main`.

---

## 0. Mission

Get **Fae** fully production-ready AND land the complete product vision:

> Fae is a cross-platform, local-first, self-evolving voice AI. Her local model is
> the secure core; she can *optionally* use cloud models (OpenRouter etc.) and other
> local models. She runs on all the owner's devices and **hands off** following the
> user around. She uses **`../x0x`** to connect the owner's machines, to collaborate
> with *other people's* Fae, and to create company/community spaces. She uses
> **`../x0x-symphony`** to orchestrate **groups of Fae** working problems together.
> She is the most proactive friend anyone can have. Correct over fast, always.

The bar is: **all gates green, on `main`, no branches or worktrees left behind, and
the vision actually implemented — not scaffolded.** `../x0x` and `../x0x-symphony`
are being built in parallel by others; treat them as moving dependencies and drive
against their real REST/socket/trait surfaces, not assumptions.

## 1. Where things stand right now (read this first)

- Trunk is **`main`** @ `14dcb7aa` (pushed). Working tree clean, single worktree, no
  feature branches. CI (`ci.yml`, `ci-linux.yml`, `linux-render-spike.yml`) is running
  on that commit — **your first job is to confirm it goes fully green** (`gh run list --branch main`).
- A 10-dimension adversarial review just fixed **26 verified findings** (2 critical, 8
  high, 16 medium). Details: memory file `project_production_readiness_review_2026-07-02.md`
  and the commit body of `14dcb7aa`. Gates were green locally before push (crates fmt +
  clippy `-D warnings` + 520/520 tests; orb-host check; `swift build`; touched Swift suites).
- Read `CLAUDE.md` (root) fully — it is the ground truth for architecture, model stack,
  tool/skill/security model, scheduler, memory, and the orb-first workflow.

### Two owner follow-ups left open by the review (close these in Phase A)
1. **appimagetool digests** — `.github/workflows/release-linux.yml` pins appimagetool to
   tag `1.9.0` with a fail-closed SHA-256 check, but the two per-arch digests are sentinel
   placeholders (`__REPLACE_ME_APPIMAGETOOL_*_SHA256__`). Fetch the real digests for that
   tag's `appimagetool-x86_64.AppImage` / `-aarch64.AppImage`, fill them in. (Owner may
   need to confirm the tag; if 1.9.0 is wrong, pick a real fixed tag.)
2. **Restore-from-Vault button** — `GitVaultManager.restore()` is hardened (copy-then-swap)
   and `RescueMode.restore(commit:from:)` exists, but no SwiftUI button invokes it. Wire a
   "Restore from Vault" control (respecting `DESIGN.md`) into the rescue-mode UI
   (`SettingsPersonalityTab.swift` / `FaeApp.swift`) so the advertised recovery path is
   user-reachable.

## 2. Non-negotiable operating rules (hard-won; violating these is how trust is lost)

1. **Adversarial verification.** Subagents in this project have fabricated completion
   reports (0 tool calls, invented diffs) and written tests that guessed impl behavior
   wrong. **Never accept an agent's report.** Verify every hand-back against the real
   `git diff` + a re-run gate + live output. When you fan out fixers, have independent
   skeptics try to REFUTE each finding before you accept it.
2. **Gates are the definition of done.** Nothing is "done" until: crates
   `cd crates && env -u RUSTFLAGS just check` (fmt + clippy `-D warnings` + tests) is green,
   `env -u RUSTFLAGS just check-ui-shell` is green, `swift build` is clean, and the relevant
   Swift test suites pass. Crate builds REQUIRE `env -u RUSTFLAGS`. For anything touching
   models/prompts/voice/approvals/memory/scheduler/skills/orb, honor
   `docs/checklists/app-release-validation.md`.
3. **Commit discipline.** Work on `main` (the owner wants trunk-based, no stray branches).
   Commit in coherent, gated chunks — never a giant dump. If you must parallelize file-
   mutating agents, give each a **git worktree** to avoid `.git/index.lock` races, then
   **fold results back into `main` and remove every worktree + delete every temp branch
   when done.** End state after every phase: on `main`, tree clean, `git worktree list`
   shows one entry, `git branch` shows only `main`. Never leave a branch or worktree behind.
   End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
4. **Test hygiene.** MLX ops CRASH under `swift test` — QUIT the dev app first and prefer
   targeted `--filter` runs (the full suite also times out on Contacts/AddressBook XPC
   noise). Kill stray `just check`/`cargo-nextest`/`gpg-agent`/`mock_acp_agent` processes
   between big runs — they deadlock on the cargo target lock (this bit the last session).
5. **Fail closed, be honest.** Security/integrity gates must fail closed. "Completed" is
   wrong if anything was skipped. Surface conflicts (pick the more-tested/documented option,
   flag the other) — don't blend. Correct > fast.
6. **Don't break the two untouched lanes.** macOS Kokoro/voice-tts and the MLX fallback/
   training substrate stay working. Linux paths are `cfg`-gated. Prove both when you touch
   shared code.
7. **Owner-in-the-loop for the irreversible + the physical.** Voice/mic/TTS/orb/camera and
   real ACP-agent approval cards can only be validated by the owner via `source ~/.secrets &&
   just run-dev`. Prepare runbooks; don't claim green on things only a human can green.

## 3. The roadmap — phased, each phase ends green on `main`

Build the ordering the last review's gap-analysis established. **The daemon execution host
is the linchpin — most of the vision is blocked on it, so it comes first after CI is green.**
Do NOT start a later phase until the earlier one's gates are green and committed.

### Phase A — Green the board (fast)
- Confirm CI on `14dcb7aa` goes fully green; diagnose real failures (pull logs), re-enqueue
  genuine flakes. Fix anything red with a minimal, verified change.
- Close the two owner follow-ups (§1). The appimagetool digests unblock the Linux release job.
- Sweep the just-landed 26-fix diff for any regression a reviewer would catch.

### Phase B — Daemon ToolHost / SkillHost foundation (THE linchpin; P7/D3 unblocker)
Today all 37 tools + 30 skills execute **only inside the macOS Swift app**; the Linux daemon
is tool-*aware* but executes nothing (`crates/README.md` lists pipeline/skills/scheduler as
"not yet wired"). Cross-platform Fae is a voice shell until this lands.
- Decide the substrate: the sibling Rust harness **`../fluers`** is already spiked for exactly
  this (ADR-013, memory `project_fluers_substrate.md` — Spike S19 Stage 1 verified
  PROCEED-WITH-B, 4 caveats, hybrid rquickjs+JSC). Either adopt fluers Stage B or build a
  minimal native daemon `ToolHost`/`SkillHost`. Whatever you pick, it MUST re-expose the
  full governance stack: control-plane scopes, a DamageControlPolicy-equivalent (port the
  Swift policy — including the zero-access + catastrophe-rm fixes just made), receipts, and
  the SHA-256 skill-integrity contract (fail closed on undeclared scripts).
- Add a real **execution-isolation tier** under bash/tool-programs (hermes-agent ships six
  backends; Fae has none — everything runs on-host under pattern policy alone). Minimum:
  macOS `sandbox-exec`/App-Sandbox helper + a Linux container/jail backend (the fluers jail
  is a natural fit). Default proactive/scheduler/auto-skill/script-block executions to isolated.

### Phase C — Cross-platform tool + skill execution (P7/D3 proper)
- Port the portable tools + executable skills to run through the Phase-B host so **Linux and
  macOS Fae have identical capability**. Keep macOS-only tools (Apple Calendar/Mail/etc.)
  gated; provide the portable CalDAV/CardDAV/himalaya skills as the Linux equivalents.
- Gate: a Linux daemon build actually executes read/write/edit/bash + a run_skill end-to-end,
  through the governed host, proven headlessly in `ci-linux.yml`.

### Phase D — Cloud / multi-model lane (the "secure local + optional cloud" promise)
- `native/.../Core/FaeConfig.swift` (~lines 100-104) already defines `llm.remoteProviderPreset`
  (default `"openrouter"`), `remoteBaseURL`, `remoteModel` — **parsed and serialized but read
  by nothing.** Implement an OpenAI-compatible `RemoteHttpAdapter` behind fae-engine's
  `ProviderAdapter` trait, register it as a vetted **conductor** worker (e.g.
  `cloud:openrouter/<model>`) so every cloud turn flows through the already-built gate pipeline
  in `crates/fae-daemon/src/conductor/` (mode cap → `fae-pii-membrane` → budget → telemetry →
  `pricing.rs`). Wire the Swift config keys to actually select it; keep the local model the
  secure default and make the privacy lane explicit (pure-local / local-symphony / all-available).
- Gate: an owner can switch to an OpenRouter model, PII membrane strips before egress, budget +
  usage are tracked, and the local lane is untouched when cloud is off.

### Phase E — x0x: Fae↔Fae governed peer messaging + device handoff
- `crates/fae-envelope-gate` is the typed, signature-checked G5 boundary but x0x is unwired
  (`docs/architecture/fae-to-fae-governance.md`). Wire the gate into the daemon as the single
  **x0x ingress**: subscribe to `x0xd`, validate every envelope (schema/kind/signature/trust-
  tier) BEFORE any content reaches the pipeline/memory/tools. Start with chat + presence kinds
  and consent-request round-trips surfaced as Fae approval cards. Land the `collaborate` skill
  end-to-end (`native/.../Resources/Skills/collaborate/`, memory `project_collaborate_skill.md`
  — 11 scripts, shipped to a branch, NOT merged/smoke-tested) against a live `x0xd`.
- **Device handoff:** today `DeviceHandoff.swift` publishes an Apple `NSUserActivity` into the
  void — no receiver. Define handoff as **same-owner OwnerFleet sync over x0x**: a signed
  session-snapshot kind (conversation tail + pending turn) through the envelope gate, plus
  background sync of memory deltas and adapter/config refs between the owner's machines.
- Gate: two Fae instances (owner's two machines, or two identities) exchange a governed
  message + a handoff snapshot; nothing bypasses the envelope gate.

### Phase F — x0x-symphony: groups of Fae + self-delegation
- Add a daemon-side `fae.delegate` that runs a scoped child turn-loop against the same engine
  (own context window, restricted toolset via the existing proactive-allowlist machinery,
  iteration budget, receipt) with leaf/orchestrator roles and parallel batches — reuse
  conductor `budget.rs` + telemetry. (Hermes' `delegate_task` is the reference shape.)
- Implement a Fae runner conforming to **`../x0x-symphony`**'s runner trait: claim a `TaskItem`
  via `x0xd` REST (trust-gated), execute via `fae.delegate` in an isolated workspace, publish a
  signed handoff + proofs. Borrow hermes' dispatcher hardening (stale-claim reclaim, heartbeat).
- Gate: a symphony task is claimed, worked by a group of Fae, and returned with signed proofs.

### Phase G — hermes-agent parity polish
- Turn-level **context compression** in the daemon session (summarize evicted history into a
  pinned block instead of hard-truncating `recommendedMaxHistory`), rough token estimation +
  per-turn usage telemetry via `runtime.status`, and a prompt-cache-stability rule.
- **MCP client as a first-class tool source** in the daemon ToolHost (namespaced `mcp:<server>:
  <tool>`, gated by the same scopes/policy) so both platforms inherit the ecosystem.
- **Skill lifecycle curation** (per-skill usage counters, stale→archived for `auto-`-generated
  skills only, Git-Vault-backed, folded into the nightly `improvement_cycle`).

## 4. Reference map (read before touching a phase)

- `CLAUDE.md` (root) — architecture/model-stack/tools/skills/security/scheduler/memory.
- `docs/plans/cross-platform-completion-roadmap-2026-06-18.md` — the P-series roadmap this extends.
- Memory files (`~/.claude/projects/.../memory/`): `project_production_readiness_review_2026-07-02.md`
  (this review), `project_fluers_substrate.md` (ToolHost substrate / ADR-013),
  `project_p9_c4_progress.md` (training-seam gate receipts), `project_collaborate_skill.md` (x0x collab).
- `crates/README.md` + `crates/fae-daemon/src/conductor/` (routing, pricing, budget, privacy lanes),
  `crates/fae-engine` (ProviderAdapter), `crates/fae-envelope-gate` (G5 boundary),
  `crates/fae-pii-membrane`.
- Siblings: `../x0x` (machine mesh + spaces + `x0xd` REST), `../x0x-symphony` (group orchestration),
  `../fluers` (candidate exec host).
- `docs/checklists/app-release-validation.md` — the release gate for user-facing lanes.

## 5. How to work

- Scout inline first (state, real surfaces of x0x/x0x-symphony/fluers), THEN fan out with a
  workflow/agents for parallel implementation + adversarial verification. Keep the conclusion,
  not the file dumps.
- After each phase: gates green → commit to `main` → confirm CI → `git worktree list` and
  `git branch` show only the single `main` entry. Update the memory file + `docs/CHANGELOG.md`,
  and sync the Obsidian vault note (per root CLAUDE.md) when docs change.
- Ping the owner only when genuinely blocked on a decision/physical validation, when a phase
  lands, or when CI goes red. Prepare owner runbooks for the voice/orb/ACP/x0x live checks you
  can't do headlessly.

Begin with **Phase A**: confirm CI on `14dcb7aa`, then close the two follow-ups.

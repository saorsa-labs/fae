# Fae — Complete-the-Work + Full Production-Readiness Audit — Mega-Prompt (2026-07-05)

> Paste this whole file as the opening prompt of a fresh Claude Code (Fable) session
> at repo root `/Users/davidirvine/Desktop/Devel/projects/fae`. It is self-contained.
> You are taking over a project that is **feature-complete on paper** and now needs
> (a) the remaining implementation finished and (b) a **deep, adversarial, whole-system
> production-readiness audit** by a full agent team. Put the team on this. Use Fable
> (you) to plan, decompose, and verify; delegate the heavy reading/coding to
> sonnet/opus/general-purpose sub-agents and worktrees. Verify every hand-back.

---

## 0. Mission (two halves, both required)

1. **Finish the remaining work** (§3) — small, well-scoped items + one larger opt-in
   feature (the local voice clone), each landed green on `main`.
2. **Audit the entire system for production readiness** (§4) — a comprehensive,
   multi-agent, adversarial review of everything built, because a large amount of
   code landed fast (two big epics + a day of live-testing hotfixes) and it must now
   be proven whole, not just per-commit. Find what's wrong before users do.

The bar: **all gates green, on `main`, no branches/worktrees left behind, every claim
verified against the real diff + a re-run + (where possible) live output.**

## 1. Where things stand (read first)

- Trunk is **`main` @ `a4e888cc`** (pushed; CI green across CI, CI (Linux), Release
  validation, Linux render spike). Working tree clean; `git worktree list` and
  `git branch` show only the single `main`.
- **Both original epics are code-complete and CI-proven:**
  - **Production-readiness mega-prompt Phases A–G** — daemon ToolHost/SkillHost +
    OS isolation (Landlock/seatbelt), cross-platform tool+skill execution proven in
    ci-linux, cloud/OpenRouter lane behind the conductor egress gates, x0x Fae↔Fae
    governed messaging + device-handoff surfaces, `fae.delegate` native jailed agentic
    loop + `fae-symphony-runner` (live group-of-Fae proof, signed handoffs), and the
    Phase-G polish (context compaction/pinned-summary, MCP governed tool tier via
    vendored mistralrs-mcp, auto-skill lifecycle).
  - **UX overhaul for non-computer users (W1–W6)** — pill-first input (multiline
    paste, chips, click-collapse, secure `request_input`), structural credential
    withholding + memory-capture redaction, brain discovery + conversational
    OpenRouter setup + silent daemon respawn + `route_hint`, conversational
    first-launch onboarding + location capture, menu purge + Advanced mode, x0x
    contact card exchange (PasteRegistry, consent bridge).
- **x0x-symphony v0.1.0 is published to crates.io** (owner fired the tag); the ML-DSA
  org signing secret was diagnosed (hex-vs-base64) + fixed + a verifier workflow
  guards rotations; `fae-symphony-runner` is pinned to the crates.io 0.1.0 versions.
- **A full live human-in-the-loop UX pass happened on 2026-07-05** and shook out EIGHT
  real bundled-app bugs — all fixed and pushed except where noted in §3. They are the
  clearest signal that **headless gates alone did not catch integration bugs**; the
  audit must include live/bundled behavior, not just `just check`.

### The live-pass fixes already landed (context for the audit — re-verify they hold)
- `a939a15f` orb host had no macOS Edit menu → ⌘V dead in the pill (Accessory app +
  `init_for_nsapp` Edit menu = key-equivalent routing).
- `f3ea61f1`/`23f8077b` orb "Thinking" stranded on turn cancellation → RAII
  `GeneratingGuard` publishes `active:false` on every exit incl. future-drop.
- `d1981ceb`/`ccf28f85` Gemma-4-E4B unreliably called `input_request` for secrets (and
  once hallucinated "saved") → deterministic Swift `SecureInputIntent` pre-detector
  opens the masked card + real Keychain write; email/URL-shaped values exempt.
- `ea036f1b`/`672ace66` an abandoned secure card WEDGED left-click (transparent
  expanded pill window swallowed clicks) → auto-cancel on new turn + ✕/Esc/orb-click +
  collapse removes the click-catcher.
- `34a085e7`/`746e8ffd` silent TTS (daemon `tts.speak` returned with no fallback) +
  no mute toggle → loud in-process Kokoro fallback, `tts.speakReplies` mute
  (menu + pill glyph + self_config), text-first readable pill with length-scaled dwell.
- `a4e888cc`/`a81d0ab9` "I hit a local model problem" on long chats — Swift assumed a
  32768 window but the daemon launched `llama-server` with `-c 8192`; history-trim
  targeted 32K while the model capped at 8K → RAM-scaled context (32768/16384/8192)
  passed via `FAE_LLAMA_CTX` so `-c` matches, compaction budget bound to the real
  window; PTT "Listening" cue wired (the mode key was silently dropped in
  `OrbStateBridgeController`); pill mute button made clearly visible.

## 2. Non-negotiable operating rules (hard-won; violating these is how trust is lost)

1. **Adversarial verification.** Sub-agents in this project have fabricated completion
   reports, written tests that guessed impl behavior wrong, and merged inside their own
   worktree (silently no-op). NEVER accept a report. Verify each hand-back against the
   real `git diff` + a re-run gate + live output. For findings, have independent
   skeptics try to REFUTE before you accept.
2. **Gates are the definition of done.** Nothing is done until: crates
   `cd crates && env -u RUSTFLAGS just check` (fmt + clippy `-D warnings` + tests) is
   green, `env -u RUSTFLAGS just check-ui-shell` is green, `swift build` is clean, and
   the relevant Swift suites pass. Crate builds REQUIRE `env -u RUSTFLAGS`. For
   anything touching models/prompts/voice/approvals/memory/scheduler/skills/orb, honor
   `docs/checklists/app-release-validation.md`.
3. **CI is the real gate — read the exact failure, fix, re-verify with the exact CI
   command.** ci-linux runs clippy with `-D clippy::{unwrap_used,expect_used,panic}`
   over `--all-targets` (stricter than the local justfile) — new `tests/*.rs` files need
   a file-level `#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]`.
   The `concurrency: cancel-in-progress` on CI means a later push cancels an earlier
   run — a "cancelled" is not a failure; re-check the newest head. Never chain a push
   before reading a gate's real exit code (a red gate reached origin once this way).
4. **Trunk discipline.** Work on `main`. Parallel file-mutating agents get a git
   WORKTREE each (avoids `.git/index.lock` races); fold back into `main`, remove every
   worktree + delete every temp branch. FOLD FROM THE MAIN CHECKOUT, not inside the
   worktree (a merge run inside the worktree silently no-ops → "Already up to date").
   End state after every step: on `main`, tree clean, one worktree, only `main` branch.
   End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
5. **Push-protection is real.** GitHub blocks pushes containing secret-shaped literals
   (even fake test tokens like `sk-proj-…`, `ghp_…`). Build fake tokens by concatenation
   in tests; never use the unblock override.
6. **Test hygiene.** MLX ops CRASH under `swift test` — QUIT the dev app first and prefer
   `--filter`. The swift-testing summary prints a misleading "0 tests" footer; the true
   result is the `Executed N tests` line. Kill stray `just check`/`cargo-nextest`/
   `mock_acp_agent`/`gpg-agent` between big runs (cargo target-lock deadlock).
7. **Fail closed, be honest, correct > fast.** Security/integrity gates fail closed.
   "Completed" is wrong if anything was skipped. Surface conflicts (pick the
   more-tested/documented option, flag the other) — don't blend.
8. **Owner-in-the-loop for the irreversible + the physical.** Voice/mic/TTS/orb/camera,
   real ACP-agent approval cards, and x0x two-identity checks can only be validated by
   the owner via `source ~/.secrets && just run-dev` (dev profile: data dir
   `~/Library/Application Support/fae-dev/`, defaults suite `com.saorsalabs.fae-dev`).
   Prepare runbooks; don't claim green on what only a human can green.
9. **Don't break the two untouched lanes.** macOS Kokoro/voice + the MLX fallback stay
   working; Linux paths are `cfg`-gated. Prove both when touching shared code.

## 3. Remaining work to COMPLETE (each ends green on `main`)

Small, well-scoped unless noted. Verify, gate, fold, push, confirm CI for each.

1. **[#21] Bundled fae voice must auto-install reliably.** During the live pass,
   `~/Library/Application Support/fae-dev/voices/` was missing, so daemon TTS fell back
   to generic `af_heart` ("not like Lauren"). `installBundledVoices()` (DaemonTTSEngine)
   didn't populate `<data dir>/voices/fae.safetensors`. FIX: make the bundled
   `Resources/voices/fae.safetensors` install idempotently on daemon-TTS init (even if a
   prior TTS attempt failed), confirm the daemon requests `voice=fae` not `af_heart`,
   and the in-process FaeTTSAdapter fallback uses the bundled fae embedding. A FRESH
   dev data dir must end up with the fae voice with no manual copy. Owner-verify: fresh
   `run-dev` → sounds like Lauren.

2. **[#17] `peer.handoff_offer` must carry the conversation tail.** Today the daemon's
   `peer.handoff_offer` wire event carries only `tail_len`, so Swift-side handoff
   hydration injects just `pending_turn` — "continue conversation from <machine>" loses
   the restored context. The tail is already gated + 64KiB-bounded inside the accepted
   `SessionHandoff` envelope (`crates/fae-daemon/src/peer/`). Include it in the wire
   event (or add a `peer.handoff_fetch` command) + hydrate it Swift-side.

3. **[#18] Surface MCP tool specs into the delegate loop.** MCP tools (Phase G3) work on
   the interactive `toolhost.execute` path but their specs aren't emitted into
   `fae.delegate`'s `build_tool_specs` (`crates/fae-daemon/src/delegate.rs` ~679), so a
   delegated (jailed) turn can't call `mcp:` tools even when the `Delegated` origin is
   permitted. Add the raw-JSON-schema emission branch for `mcp:` names (MCP schemas may
   not round-trip fluers ParameterSchema — emit `raw_schema` directly).

4. **ASR accuracy (real, surfaced live).** The Qwen3-ASR transcription pass mis-heard
   the owner: "my favorite color is blue" → "my different color blue" / "My favorite
   color"; a chat turn mis-fired `type_text` (blocked correctly, but shouldn't have
   tried). Investigate: is the ASR prompt/decoding tunable (the vocab-correction layer,
   `FAE_ASR_LLAMA_CTX`, the ASR model/quant, temperature), and does the two-pass
   `[heard]` correction help? Improve transcription fidelity for owner speech; consider
   whether the dynamic-vocabulary corrector should be strengthened. Owner-in-loop to
   judge. Do NOT over-engineer — measure first (capture WERs via `FAE_DUMP_REQUESTS`).

5. **Model tool-discipline (real, surfaced live).** Gemma-4-E4B over-reaches on tools —
   it tried `type_text`/computer-use on a plain chat turn ("what are we looking at?").
   Evaluate: prompt-stack guidance to prefer conversation over tools unless clearly
   needed; whether computer-use tools should be gated behind an explicit intent; keep
   the DamageControl/mode gate (it correctly blocked it). Measure with the eval harness.

6. **VOICE CLONE (larger, opt-in) — design is done and approved.** Implement
   `docs/plans/fae-voice-clone-2026-07-05.md`: Chatterbox (Resemble AI, MIT
   code+weights — VERIFY the LICENSE file before shipping), a warm Python clone sidecar
   behind the daemon as a new `CloneTtsAdapter: TtsAdapter`, `FallbackTtsAdapter`
   per-sentence Kokoro fallback, `models.lock` integrity for the clone weights,
   `tts.engine = .kokoro | .clone` config (default `.kokoro`), speaker cond precomputed
   once from `assets/voices/fae.wav` (+ its transcript `bundledFaeReferenceText`) and
   cached, opt-in + RAM/thermal-gated. 4 gated commits (§ in the design). Consent
   recorded (Lauren, the owner's gardener, consented + delighted). Owner judges fidelity
   A/B vs Kokoro; a cleaner 2-3 min Lauren sample will improve it. **This is ~3 focused
   days — treat it as its own tracked effort, not a drive-by.** Second choice if
   Chatterbox underwhelms: CosyVoice2 (Apache-2.0). NEVER ship F5-TTS/XTTS-v2 weights
   (non-commercial licenses).

## 4. THE PRODUCTION-READINESS AUDIT (the main event — put the team on this)

Run a broad, adversarial, multi-agent audit. Decompose by dimension, fan out
independent reviewers (worktrees where they need to build/run), then have skeptics try
to REFUTE each finding before you accept it. Produce a single prioritized findings
report (critical → high → medium) with file:line evidence and a fix for each, then fix
the criticals+highs on `main` (gated) and hand the rest back as a tracked list.

Audit dimensions (each a sub-agent or small team):

1. **Security & privacy (highest priority).** The whole product promise is local-first +
   fail-closed. Re-audit: the conductor cloud egress boundary (mode cap → PII membrane →
   pricing → budget — can anything reach a cloud provider without passing all four? is
   the local model truly the default?); `fae-pii-membrane` coverage vs real credential
   shapes; the W2 credential-withholding + memory redaction (any path where a secret
   still reaches context/transcripts/`fae.db`/logs/training exports?); the DamageControl
   protected-paths + catastrophe patterns; the envelope-gate ingress (can any peer
   content reach the pipeline/memory/tools WITHOUT passing `gate_and_audit` + trust
   tier?); the OS isolation tiers (can a jailed/delegated tool escape the root? is
   `jail_backend_available()` fail-closed everywhere it must be?); Keychain handling of
   the OpenRouter key (never on the NDJSON socket, never logged); models.lock fail-closed
   on missing/mismatched artifacts. Threat-model the x0x + symphony + MCP + cloud lanes.

2. **Correctness & robustness.** Hunt real bugs across the daemon (session/turn loop,
   conductor routing, delegate loop, peer ingress, toolhost/skillhost), the Swift
   pipeline (capture→daemon→TTS, memory capture/recall, the pill/orb state machine), and
   the orb host. Focus on: error paths, cancellation/overlap (the strand bug class),
   resource leaks, races, unbounded growth (context/history/receipts/registries), and
   the `unwrap/expect/panic`-in-prod ban. The live pass proved the risky spots are
   integration seams — prioritize those.

3. **Reliability & the real bundled app.** The live pass found 8 bugs headless gates
   missed. Systematically exercise the BUNDLED app behaviors that only manifest live:
   startup/first-frame (orb paint), the pill lifecycle (paste/wedge/dwell/input-request
   cancel), TTS audibility + voice selection + fallback, PTT capture + indicator, the
   context-window/overflow behavior on long chats, daemon respawn on config change,
   supervisor restart. Produce owner runbooks for what can't be headless; automate what
   can (extend `--headless-*` proofs + the TestServer `/inject` harness).

4. **Cross-platform (Linux) parity.** Everything `cfg`-gated for Linux: does the Linux
   daemon actually build + run the governed tool/skill/delegate paths (ci-linux proves
   some)? Landlock jail, Piper TTS, packaging (AppImage digests), the x0x/symphony/MCP
   lanes on Linux. Flag anything macOS-only that the product claims is cross-platform.

5. **Performance & resources.** ttfa/latency (the prompt-budget work; does compaction
   keep turns bounded?); memory footprint (Gemma + ASR + TTS + potential clone model on
   16GB — the RAM-gating), KV-cache at 32K context, thermal/battery gating, the warm
   sidecars. Measure, don't guess (`FAE_DUMP_REQUESTS`, the eval/benchmark harness).

6. **Tests, CI, gates.** Coverage of the security-critical + new surfaces; flaky/racy
   tests (env-var races bit twice — audit `set_var`/`remove_var` in tests); the ci-linux
   strict-clippy trap; whether the headless proofs actually prove what they claim;
   whether release-validation covers the new lanes. Are there silent caps / skipped
   tests / `#[ignore]` that hide gaps?

7. **Docs, ADRs, consistency.** CLAUDE.md vs reality (it's the ground truth — is it
   still accurate after this session?); the ADRs (014 cloud, 015 delegate/runner — still
   "Proposed"; flip after the owner gates); `docs/checklists/app-release-validation.md`;
   the CHANGELOG; and the Obsidian vault sync (per root CLAUDE.md, any doc change updates
   the vault note under `~/Library/Mobile Documents/…/Saorsa Labs/Projects/fae/`).

8. **Supply chain & licensing.** Vendored candle/mistral.rs, the crates.io deps, the
   voice-clone model licenses (the decisive axis — MIT/Apache only for a dual
   AGPL/commercial product; F5/XTTS/Fish are non-commercial and must never ship),
   HF-gated models, and the pinned runtimes' SHA integrity.

## 5. Owner-in-the-loop items (can't be headless — prepare + track, don't claim green)

From `docs/checklists/owner-runbook-2026-07-04.md` (+ its 2026-07-05 addendum):
- ADR-014 + ADR-015 sign-offs (flip Proposed→Accepted after the gates below pass).
- One live-key OpenRouter turn: paste key (masked card) → lane "all" → silent respawn →
  "ask the cloud …" routes RemoteAllowed (membrane/pricing/budget receipts) → a normal
  turn stays local; PII membrane blocks a credential; budget exhaustion falls back loud.
- x0x live checks: two-identity direct message rendered attributed; "Hand off to…" card
  (tail hydration once #17 lands); friend card paste→import→consent→allowlist→respawn.
- fae.delegate approval card with a real model + dangerous tool.
- Voice/TTS: unmuted → Lauren's voice audible (log shows `voice=fae`); mute → text-only;
  readable pill dwell; and (later) the clone A/B.
- ASR fidelity judgment; the fresh-profile conversational onboarding.
- Standing: B5 real-mic validation; a real ACP (codex) approval-card turn.

## 6. Reference map

- `CLAUDE.md` (root) — architecture/model-stack/tools/skills/security/scheduler/memory/
  orb-first workflow. Ground truth; verify it against reality as part of the audit.
- `docs/plans/` — `fae-production-readiness-mega-prompt-2026-07-02.md` (the A–G source),
  `fae-ux-nonexpert-overhaul-2026-07-05.md` (W1–W6), `fae-voice-clone-2026-07-05.md`
  (the approved clone design), `cross-platform-completion-roadmap-2026-06-18.md`.
- `docs/adr/` — 010 (llama.cpp sidecar), 014 (cloud lane), 015 (delegate/runner).
- `docs/checklists/app-release-validation.md` + `owner-runbook-2026-07-04.md`.
- Memory files (`~/.claude/projects/.../memory/`): MEMORY.md index + the per-topic files
  (x0x surface maps, fluers readiness, reference_gemma4_metal_nan_bug, the ML-DSA key
  canon, etc.) — recalled facts are point-in-time; verify file:line before asserting.
- Siblings: `../x0x` (v0.28.0, x0xd REST — two daemons live on :12700/:12701),
  `../x0x-symphony` (v0.1.0 on crates.io), `../fluers`.

## 7. How to work

- Scout inline first (real state, real surfaces), THEN fan out with worktrees/agents for
  parallel implementation + the audit + adversarial verification. Keep conclusions, not
  file dumps. Use Fable for planning + verification; delegate reading/coding to
  sonnet/opus/general-purpose (dev-agent spawns WITHOUT file tools — do not use it).
- After each landed item: gates green → commit `main` → confirm CI → `git worktree list`
  + `git branch` show only `main`. Update MEMORY.md + CHANGELOG + Obsidian.
- Deliver the audit as ONE prioritized findings report; fix criticals+highs (gated),
  track the rest. Ping the owner only for decisions/physical validation, when a phase
  lands, or when CI goes red.

Begin by confirming CI on `a4e888cc` is green, then stand up the audit team (§4) in
parallel with completing §3 items 1–3 (the small ones) first.

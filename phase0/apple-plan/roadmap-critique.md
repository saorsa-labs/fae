I did not write `phase0/apple-plan/roadmap-critique.md` because the task also says **Do not modify files** and my plan-review role is review-only/no-edit. Also, `phase0/apple-plan/` does not currently exist. Below is the critique content that should go there.

# Apple-first roadmap critique

## 1. Strengths

- **Phase 0 gate framing is mostly right.** `docs/architecture/headless-core-impl-plan-2026-06-01.md` correctly states that production/headless Rust implementation is not approved until gates pass or scope is explicitly narrowed.
- **Selective legacy reuse is correctly scoped.** `docs/architecture/legacy-reuse-audit.md` rejects wholesale rollback of `legacy/rust-core/ROLLBACK.md` and recommends a greenfield daemon shell with selective ports.
- **Memory risk is treated seriously.** `docs/architecture/memory-migration-plan.md` preserves Swift `fae.db`, backup/rollback, audit lineage, and read-only/fail-closed behavior.
- **Fae↔Fae/group features are correctly hard-gated.** `docs/architecture/fae-to-fae-governance.md` treats peer content as untrusted and blocks memory/tool/group behavior until schema, consent, audit, revocation, and tests exist.
- **Windows is properly out of v1.** This avoids diluting the Apple-first goal with unproven platform work.
- **G2 has moved from prose to scaffold.** `phase0/next-step-g2-progress.md` shows a minimal `bench/engine-parity` crate exists and validates result schema, while honestly saying it does not prove fallback parity.

## 2. Issues, ranked by severity

### Critical

1. **The roadmap cannot proceed to “completion” as if Phase 0 is done.**
   - G1 independent S13 replication is still missing.
   - G2 real mistral.rs ↔ llama.cpp parity is still missing.
   - G4 is a plan, not a proven migrator.
   - G5 is a requirements contract, not enforcement code.
   - Any roadmap that starts production daemon work before those are resolved violates `headless-core-impl-plan`.

2. **“Apple fully working” is currently underspecified.**
   - The existing plan mixes:
     - Apple local assistant parity,
     - Rust daemon architecture,
     - cross-platform engine migration,
     - Fae↔Fae,
     - mobile dock-wake,
     - group TreeKEM,
     - self-learning.
   - For Apple-first, MVP must be sharply narrower.

3. **Daemon control plane remains a blocker.**
   - `docs/architecture/daemon-control-plane.md` is explicitly a **design stub**.
   - It does not yet define final auth, authorization, token lifecycle, WS/SSE auth, per-client capability binding, or browser/DNS-rebind defenses.
   - This must be serial before any daemon that owns memory, tools, mic, or scheduler.

4. **Memory migration cannot be parallelized into production ownership.**
   - Current authoritative runtime is pure Swift under `native/macos/Fae`.
   - Rust must not become the writer until preflight, backup, rollback, schema compatibility, and live DB copy tests pass.
   - A read-only memory bridge may be parallel work; write ownership is serial and gated.

### High

5. **G2 scaffold risks being mistaken for fallback proof.**
   - `phase0/next-step-g2-progress.md` is clear, but roadmap language must keep saying: scaffold passed, fallback not proven.
   - “llama.cpp fallback” must remain design intent until a real run with committed/summarized results exists.

6. **Apple integration via Rust `objc2` is a major unknown.**
   - The plan says “Apple tools via `objc2`; Swift = UX.”
   - Existing production app already has Swift/AppKit/Apple integration.
   - Reimplementing Apple-native integrations in Rust may be unnecessary for Apple MVP and could delay working product.

7. **Voice identity parity is not a Phase 0 blocker but is Apple-MVP critical.**
   - S13 proves Gemma-4 E4B STT works, not that the whole voice loop sounds/feels like Fae.
   - Kokoro+ONNX+misaki-rs must pass user-recognition/parity before replacing Apple-local voice paths.

8. **The roadmap overweights future networking compared with local Apple reliability.**
   - x0x, Fae↔Fae, group TreeKEM, phone↔home, peer tools, and shared memory are all post-local-assistant concerns.
   - For Apple-first, these should not be on the critical path.

### Medium

9. **Cross-platform architecture is being used to justify Apple-first work, but Apple-first may not need full cross-platform daemonization immediately.**
   - A thinner Apple MVP could keep Swift UI + current memory + current Apple permissions, while proving the engine and voice loop behind a narrow local interface.

10. **Supply-chain and model verification are not yet first-class in the roadmap.**
   - Model checksum/signature verification, signed daemon updates, and cache permissions should be pre-v1, especially if the daemon owns tools and memory.

11. **Current output path does not exist.**
   - `phase0/apple-plan/` is absent. If the parent wants artifacts there, it should create the directory in a writing task.

## 3. Missing considerations

### Serial dependencies that must not be skipped

1. **Define Apple MVP before daemon implementation.**
   - Otherwise every subsystem claims to be “required.”

2. **Finish control-plane design before daemon endpoint code.**
   - Required by `daemon-control-plane.md` exit criteria.

3. **Run real G2 parity before production `ProviderAdapter` dependency.**
   - The scaffold can inform implementation, but not authorize fallback claims.

4. **Prove memory migration on copies before write ownership.**
   - Rust may not write production `fae.db` until backup/rollback/migration proof exists.

5. **Voice parity before changing default Apple voice path.**
   - If Kokoro+misaki-rs fails identity continuity, Apple-native/MLX path should remain primary on Apple.

6. **G5 enforcement before any peer-originated memory/tool behavior.**
   - No Fae↔Fae memory, peer tools, group memory, or prompt-injected network content before schema/audit/revocation tests.

### Parallelizable work

These can proceed in parallel **after scope is narrowed**, because they do not depend on each other’s final implementation:

- G1 replication on another machine/OS.
- G2 real engine parity harness implementation/run.
- Daemon control-plane design completion.
- Memory migrator/preflight prototype against copied DBs.
- Voice parity test design and sample collection.
- Model checksum/signature manifest design.
- Apple MVP UX definition and acceptance checklist.
- Documentation cleanup: reconcile stale Rev-4/llama-server language in `cross-platform-engine-plan-2026-05-30.md`.

### Work that should stay deferred

- Fae↔Fae personal-memory sharing.
- Group “the Fae” features.
- TreeKEM-dependent group memory.
- Peer-triggered tool execution.
- Mobile dock-wake over x0x.
- Windows.
- Weight training.
- ToM/Honcho/Zep/Graphiti memory upgrade.
- Forking candle/mistral.rs.

## 4. Recommended Apple-first MVP definition

“Fae working on Apple fully” should mean:

1. **Runs as a native macOS app.**
   - Swift/AppKit/SwiftUI UX remains primary.
   - No visible regression from current production app.

2. **Local conversation works end-to-end.**
   - Text and voice input.
   - Local model response.
   - Streaming output.
   - TTS playback.
   - Barge-in or at least reliable stop/interruption behavior.

3. **Memory remains safe and automatic.**
   - Current Swift `fae.db` preserved.
   - Recall and capture continue.
   - No silent overwrites.
   - Backup/rollback remains available.
   - Rust, if introduced, is read-only until migrator proof passes.

4. **Apple tools work through existing safe permission model.**
   - Calendar/reminders/contacts/mail/notes where already supported.
   - Tool approvals preserved.
   - No new broad daemon permissions without scoped auth.

5. **Engine choice is evidence-backed.**
   - mistral.rs Gemma-4 E4B works on target Apple hardware.
   - llama.cpp fallback only advertised if G2 passes.
   - If G2 does not pass, Apple MVP can still ship with a clearly accepted single-engine risk or retain current backend.

6. **Voice identity passes user-recognition.**
   - Fae still sounds like Fae.
   - If Kokoro path fails, keep existing Apple voice path for MVP.

7. **No peer/network features in MVP unless separately gated.**
   - Apple-full does not require Fae↔Fae, groups, phone↔home, or x0x.

## 5. Sequencing recommendation

### Phase A — Narrow Apple MVP contract

- Write an Apple MVP checklist.
- Explicitly mark non-MVP: Fae↔Fae, groups, mobile, Windows, training, ToM upgrade.
- Decide whether Rust daemon is required for MVP or only engine-spike continuation.

### Phase B — Finish hard Phase 0 gates relevant to local Apple

- G1 replication.
- G2 real parity or explicit owner acceptance of no fallback.
- Control-plane design if daemon remains in scope.
- Memory migration proof if Rust writes memory.
- Voice parity test.

### Phase C — Minimal local Apple runtime

Preferred conservative route:

- Keep Swift app as production shell.
- Add only the narrowest local engine bridge needed.
- Keep memory writes in Swift.
- Keep Apple tools in Swift initially.
- Avoid full daemon ownership until security/migration gates are proven.

If daemon is mandatory:

- Implement daemon skeleton with no tools/memory writes first.
- Add engine text turn.
- Add voice.
- Add read-only memory.
- Add write memory only after migrator proof.
- Add tools only after per-client capability auth and audit.

### Phase D — Post-MVP expansion

- x0x phone↔home.
- 1:1 Fae↔Fae chat without memory/tool sharing.
- Governed memory sharing.
- Groups only after TreeKEM + G5 enforcement.
- Self-learning upgrades.
- Cross-platform Linux.
- Windows post-v1.

## 6. Risks of overbuilding

- **Rewriting Apple-native integrations in Rust too early.** Existing Swift paths are production reality; replacing them for architectural purity is risky.
- **Making daemon ownership too broad too soon.** Mic + memory + tools + scheduler + x0x + models creates a large security boundary before the control plane is designed.
- **Treating cross-platform as MVP.** Apple-first should not wait for Linux/mobile/network abstractions unless they directly unblock Apple.
- **Shipping governance as prose.** G5 must become enforced schema/tests before any peer memory/tool features.
- **Optimizing for future group intelligence before local assistant quality.** The user-visible product is local Fae working reliably.
- **Premature heavy-driver complexity.** E4B-only may be enough for v1; Qwen3-14B routing should be justified by measured user-visible need.
- **Forking engine internals.** The plan correctly says do not fork candle unless unavoidable; keep that discipline.

## 7. Recommendations

1. **Make Apple MVP a separate, narrower roadmap artifact.**
   - Do not let the cross-platform headless plan become the Apple completion roadmap by default.

2. **Keep Swift production ownership until Rust earns each subsystem.**
   - Engine first.
   - Voice second.
   - Memory write ownership much later.
   - Peer/network last.

3. **Convert gates into an explicit dependency graph.**
   - G2 before production fallback.
   - Control-plane before daemon tools/memory/audio ownership.
   - G4 proof before Rust memory writes.
   - G5 enforcement before Fae↔Fae memory/tools/groups.

4. **Define “no-regression from current macOS Fae” as the primary Apple MVP criterion.**

5. **Defer all peer/group/network features from Apple MVP.**

6. **Prefer the smallest shippable Apple path:**
   - Current Swift app + proven local engine/voice path + safe memory continuity.
   - Full Rust daemon only after security and migration proofs are complete.

## Bottom line

**No-go on moving directly from Phase 0 artifacts to a broad completion roadmap.**

**Go with conditions for a narrowed Apple-first MVP roadmap** that keeps production Swift stable, proves local engine/voice behavior, preserves memory safety, and defers Fae↔Fae/groups/mobile/cross-platform expansion until the existing gates are genuinely satisfied.
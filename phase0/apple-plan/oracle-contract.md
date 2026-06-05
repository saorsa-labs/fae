I did **not** write `/Users/davidirvine/Desktop/Devel/projects/fae/phase0/apple-plan/oracle-contract.md` because the task also says **“Do not modify files.”** Review-only/no-edit wins. Findings below are the intended content.

# Apple-first oracle contract

## Inherited decisions

- Current production architecture remains **pure Swift macOS** until explicitly replaced.
- Phase 0 remains a hard gate: **no broad production Rust daemon build is approved** merely because planning artifacts exist.
- Apple-first is best interpreted as a **scope narrowing**, not a gate waiver:
  - Apple/macOS local assistant first.
  - Linux deferred.
  - Windows post-v1.
  - Mobile dock-wake, Fae↔Fae, x0x peer features, groups, TreeKEM memory, ToM upgrades, and weight training are out of Apple MVP.
- Engine direction: `mistral.rs` primary, Gemma-4 E4B front, Qwen3-14B dense driver; `llama.cpp` fallback remains unproven until G2 real parity passes.
- Legacy Rust is prior art only: **selective reuse**, never `ROLLBACK.md` over the Swift tree.
- Memory is production-critical: Rust must not write live `fae.db` until G4 preflight, backup, rollback, and real-copy validation pass.
- Fae↔Fae/governance remains requirements-only; no peer memory/tool/group behavior until G5 enforcement exists.

## Diagnosis

Apple-first planning is moving in the right direction, but the current artifacts still mix three scopes:

1. **safe Apple MVP**;
2. **full Rust daemon ownership**;
3. **future cross-platform / peer-network ambitions**.

The safe Apple MVP should be narrower than the cross-platform daemon plan: keep Swift as production shell, keep Apple/TCC integrations in Swift initially, and let Rust earn ownership subsystem-by-subsystem.

## Drift / contradiction check

- `proceed Apple-first` conflicts with older “Apple + Linux v1” language only by narrowing scope. That is acceptable if explicit.
- `swift-frontend.md` keeps mic/playback/Apple tools in Swift, while headless plan says daemon owns the whole pipeline and Apple tools via `objc2`. For Apple MVP, prefer Swift-owned TCC/audio/tools initially.
- `daemon-control-plane.md` is still a **stub**; it cannot authorize daemon ownership of mic, memory, tools, scheduler, or x0x.
- G2 scaffold exists, but **fallback parity is not proven**.
- `engine-voice.md` still says ECAPA in one place; authoritative speaker target is **WeSpeaker ResNet34-LM 256d**.
- Socket paths conflict: `~/.fae/fae.sock` vs App Support run dir. Do not bake either until control-plane design is finalized.
- Implementation meta-prompts in `phase0/apple-plan/` are **not authorization** to start broad code changes.

## Recommendation

Proceed Apple-first with this boundary:

### Allowed now

- Finish Apple MVP contract and dependency graph.
- Complete G2 real engine parity harness/results.
- Replicate S13 on at least one other Apple machine; defer other-OS replication to Linux track unless owner says otherwise.
- Complete daemon control-plane design.
- Build only default-off/mock Swift bridge scaffolding if needed, without removing current Swift paths.
- Prototype memory preflight/backup against copied DBs only.
- Design/run voice parity tests.

### Still gated

- Production Rust daemon ownership.
- Live memory writes.
- Tool execution through daemon.
- Mic/audio capture owned by daemon.
- Scheduler ownership.
- `objc2` replacement of Swift Apple tools.
- Peer/x0x/Fae↔Fae/group features.
- Release claims for fallback, Linux, Windows, or cross-platform parity.

## Go / no-go ladder

1. **Current state:** GO for docs, validation, scaffolds; NO-GO for production daemon.
2. **Apple Phase 1A:** GO only for default-off bridge/mock work after owner confirms Apple MVP scope.
3. **Daemon skeleton:** GO only after control-plane design exits stub and is reviewed.
4. **Text engine:** GO after G2 passes or owner explicitly accepts single-engine risk.
5. **Voice:** GO after latency and Fae voice-identity parity pass.
6. **Memory read:** GO after G4 preflight on copied DB.
7. **Memory write:** GO only after backup/rollback/live-copy demo and owner signoff.
8. **Tools:** GO only after broker/capability/audit path exists.
9. **Peer/network:** NO-GO until G5 enforcement + metadata threat model; groups additionally require TreeKEM.

## Risks

- Treating Apple-first as permission to skip Phase 0.
- Rewriting stable Swift Apple integrations in Rust too early.
- Letting a daemon own sensitive subsystems before authZ exists.
- Mistaking G2 scaffold for fallback proof.
- Shipping governance prose instead of enforcement.

## Need from main agent

- Confirm Apple-first means **Apple-only first milestone**, not Apple+Linux v1.
- Confirm whether G1 other-OS replication is deferred to Linux track.
- Confirm whether G2 is pre-production only or pre-daemon-code.

## Suggested execution prompt

No implementation handoff warranted for this oracle task.
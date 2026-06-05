I did **not** write `/Users/davidirvine/Desktop/Devel/projects/fae/phase0/plans/oracle-contract.md` because the task also says **“Do not modify files”**. Review-only/no-edit wins.

Inherited decisions:
- **Build is not approved.** Phase 0 is a hard commit gate; Phases 1–5 cannot begin until gate exit and owner sign-off.
- Authorized now: **Phase 0 validation/artifact work only**:
  - G1 S13 independent replication.
  - G2 fallback parity harness/results.
  - G3 legacy Rust reuse audit.
  - G4 memory migration/data-safety plan.
  - G5 Fae↔Fae privacy/governance plan.
  - G6 Windows scope decision.
  - Cheap doc reconciliation of stale Rev-4/llama-server language.
- Current production architecture remains **pure Swift macOS app** per `AGENTS.md`; no production Rust core, no C ABI/libfae runtime path.
- `mistral.rs` Rev 13 is the intended engine direction, but it is still gated by independent replication and fallback proof.
- Legacy Rust revival must happen only **post-gate** and only in a **branch/worktree**, never by running `legacy/rust-core/ROLLBACK.md` over the main Swift tree.
- Memory is production-critical: preserve schema/data compatibility, audit lineage, supersession, backups, and non-lossy rollback.

Diagnosis:
- The team is authorized to continue **planning, audit, and validation scaffolding**, not product implementation.
- Canonical Phase 0 outputs appear absent (`docs/architecture/memory-migration-plan.md`, `fae-to-fae-governance.md`, `legacy-reuse-audit.md`, `bench/engine-parity/`, etc.). Current `phase0/plans/*` are draft/planning artifacts.
- The biggest risk is accidental scope drift from “Phase 0 validation” into “Phase 1 Rust core implementation,” especially via `phase0/plans/meta-prompt.md`, which asks for Rust memory implementation files.

Drift / contradiction check:
- **6 gates vs 9 preconditions:** implementation plan lists G1–G6, but review brief requires 9 preconditions including local daemon control-plane design, Fae↔Fae disclosure enforcement, and x0x metadata threat model. Treat all 9 as binding or explicitly fold 7–9 into G5.
- **“Ship 1:1 Fae↔Fae now” conflicts with “build not approved.”** Interpret “now” as strategic sequencing after Phase 0/G5, not current authorization.
- **G2 STT ambiguity:** impl plan says include STT clip parity if paths differ; G2 plan treats STT as optional. Reconcile before accepting G2.
- **G4 overreach:** `meta-prompt.md` asks to implement `fae-core/src/memory/*`; Phase 0 only authorizes the migration/data-safety plan. Actual Rust store implementation remains gated.
- **G4 schema contradiction:** one plan path says Rust may migrate `< v9`; meta-prompt says support `<9` is no and Swift upgrades first. Pick one.
- **G4 status contradiction:** `g4-memory-migration.md` is “DRAFT for Phase 0 review” but embedded recommended doc says “Approved for Phase 1.” Remove/qualify that until gate exit.
- **Engine docs stale:** cross-platform plan still contains llama-server/MoE/default language that contradicts Rev 13 mistral.rs+dense-driver decision. The implementation plan already flags this.
- **Speaker model docs stale:** some project docs/UI still say ECAPA-TDNN, while current code loads WeSpeaker ResNet34-LM first with ECAPA fallback. Voice parity requirements should use the actual shipped path.

Recommendation:
- Proceed only with Phase 0 artifact completion and review hardening.
- Update/write canonical Phase 0 documents only if the main agent is allowed to edit:
  - Promote G4/G5 drafts into canonical docs after fixing contradictions.
  - Build G2 harness only as **bench validation code**, not production runtime.
  - Produce G3 audit before any legacy revival.
  - Add G6 paragraph/tracking issue.
  - Reconcile all stale Rev-4/llama-server/MoE language.
- Do **not** begin Rust daemon, production memory store, x0x runtime integration, voice pipeline port, Apple `objc2` tools, or group features.

Risks:
- A writer may treat draft “meta-prompt for implementation” as authorization to build Phase 1.
- G5 red-team requirements are broad; accepting a narrative governance doc without machine-enforced schema/tests would violate the review brief.
- G2 can falsely pass if it proves adapter shape but not real engine parity with equivalent tool calls and STT where required.
- Current repo docs are untracked/draft; gate status must not be inferred from file existence alone.

Need from main agent:
- Decide whether to formalize 9 preconditions as G1–G9 or nest them under G5/G6.
- Decide G2 STT parity scope explicitly.
- Decide G4 `< v9` migration policy.
- Decide Windows v1 scope now: honest out-of-v1 or concrete acceptance criteria.

Suggested execution prompt:
- No implementation handoff warranted for this oracle task. If a writer is used later, constrain them to Phase 0 docs/scaffolding only and explicitly prohibit production Rust core work.
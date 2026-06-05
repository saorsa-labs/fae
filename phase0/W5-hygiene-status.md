# W5 — Hygiene status

Status: **done**  
Blocker class: **acceptable-debt / cleanup**  
Evidence grade: **repo-verified**

## Completed cleanup

1. Reconciled the known stale Rev-4 engine line in `docs/architecture/cross-platform-engine-plan-2026-05-30.md` §20:
   - old: `llama-server` default;
   - new: `mistral.rs` primary in-process engine, llama.cpp/`llama-server` fallback behind `ProviderAdapter` after G2 proof, MLX optional Apple acceleration only.
2. Updated `docs/architecture/headless-core-impl-plan-2026-06-01.md` Phase 0 housekeeping note to record the W5 sweep.
3. Marked `phase0/apple-plan/meta-prompt.md` as a non-authoritative scratch artifact.
4. Confirmed `phase0/plans/meta-prompt.md` was already marked non-authoritative.

## S13 spike harness decision

`bench/mistralrs-eval/` is intentionally treated as a **throwaway S13 spike harness**, not production or gate-clearing code to submit as a clean Rust crate.

Reason:

- It is useful evidence/reference for S13 and the G2 adapter pattern.
- It is explicitly labelled throwaway.
- It contains non-production guardrail violations such as `.unwrap()`.
- The cleaned/validated Phase 0 G2 work is in `bench/engine-parity/`, not `bench/mistralrs-eval/`.

Decision: **exclude `bench/mistralrs-eval/` from the reviewable Phase 0 patch unless the owner explicitly asks to retain and clean it.** If retained later, it must be rustfmt/clippy/check clean under the global Rust guardrails before submission.

## Validation

Use:

```bash
rg -n 'llama-server.*default|default.*llama-server|NON-AUTHORITATIVE|bench/mistralrs-eval|W5' docs/architecture phase0
```

Expected:

- no remaining `llama-server default` recommendation;
- non-authoritative warnings on scratch meta-prompts;
- S13 harness status documented as excluded unless cleaned.

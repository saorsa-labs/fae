# Architecture Decision Records

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [001](001-cascaded-voice-pipeline.md) | Cascaded Voice Pipeline | Accepted | 2026-02-10 |
| [002](002-embedded-rust-core.md) | Embedded Rust Core | Superseded | 2026-02-11 |
| [003](003-local-llm-inference.md) | Local-Only LLM Inference | Accepted (evolved) | 2026-02-13 |
| [004](004-fae-identity-and-personality.md) | Fae Identity and Personality | Accepted | 2026-02-10 |
| [005](005-self-modification-safety.md) | Self-Modification Safety | Accepted (conceptual) | 2026-02-21 |
| [006](006-voice-privilege-escalation.md) | Voice Privilege Escalation | Accepted (evolved) | 2026-02-23 |
| [007](007-companion-device-handoff.md) | Companion Device Handoff | Deferred | 2026-02-23 |
| [008](008-autonomous-self-improvement.md) | Autonomous Self-Improvement (Meta-Optimization) | Accepted | 2026-04-05 |
| [008a](008a-conductor-recipe-surface-amendment.md) | ADR-008 Amendment — ConductorRecipe MetaOpt Surface | Accepted (Amendment) | 2026-06-23 |
| [009](009-rust-orb-ui-shell.md) | Rust Orb UI Shell as Canonical Fae UI | Accepted | 2026-06-11 |
| [010](010-llamacpp-sidecar-vs-inprocess.md) | llama.cpp via `llama-server` Sidecar, not In-Process FFI | Accepted | 2026-06-18 |
| [011](011-headless-rust-core-runtime.md) | Headless Rust Core as Canonical Runtime | Accepted | 2026-06-22 |

## Notes

- ADRs 001-007 were originally written for the Rust-era architecture (Feb 2026)
- **ADR-011 (2026-06-22) re-establishes the headless Rust daemon as the canonical runtime.** New intelligence surfaces target the Rust core (`crates/`); the Swift macOS app is a migration/legacy/thin-client surface. ADR-002's "superseded by pure Swift" status is itself superseded — the daemon/control-plane protocol (not in-process C ABI) is the integration boundary.
- ADR-008 documents the AutoAgent-inspired meta-optimization system added 2026-04-05. Its autonomous-mutation scope is extended to a Rust-side `conductorRecipe` surface by [ADR-008a](008a-conductor-recipe-surface-amendment.md) — **Accepted (Amendment) 2026-06-23**. The amendment authorizes a 5th `MetaOptSurface` (recipe mutation) gated on enforceable, two-layer runtime constraints (no privacy-lane widening, no budget-cap override above the provisioned ceiling, no ADR-gated lanes/topologies, no `ModelMode` override).
- ADR-009 makes the Rust orb UI shell (`tao` + `wgpu` + `muda` + `wry`) the canonical UI.
- ADR-010 fixes the llama.cpp integration as a prebuilt `llama-server` sidecar (not in-process FFI bindings) behind the `ProviderAdapter` seam; in-process is the deferred iOS path.

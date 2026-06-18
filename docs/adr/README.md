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
| [009](009-rust-orb-ui-shell.md) | Rust Orb UI Shell as Canonical Fae UI | Accepted | 2026-06-11 |
| [010](010-llamacpp-sidecar-vs-inprocess.md) | llama.cpp via `llama-server` Sidecar, not In-Process FFI | Accepted | 2026-06-18 |

## Notes

- ADRs 001-007 were originally written for the Rust-era architecture (Feb 2026)
- The codebase was rebuilt in pure Swift/MLX; ADR statuses updated 2026-04-05
- ADR-002 is the only fully superseded decision (Rust core replaced by Swift)
- All other architectural decisions remain valid; implementations ported to Swift
- ADR-008 documents the AutoAgent-inspired meta-optimization system added 2026-04-05
- ADR-009 reintroduces Rust for the canonical UI shell only: `tao` + `wgpu` + `muda` + `wry`, while bridge migration from the Swift shell is in progress
- ADR-010 fixes the llama.cpp integration as a prebuilt `llama-server` sidecar (not in-process FFI bindings) behind the `ProviderAdapter` seam; in-process is the deferred iOS path

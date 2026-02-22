# FAE Architexture Decisions

Status: Draft for discussion  
Date: 2026-02-21  
Scope: Rust core (`src/**`) and the self-authored surface area around it

## Why we are looking at this

This analysis exists because Fae is moving from fixed channel integrations toward a skill-centric architecture with Python capability and multi-LLM optionality.

The strategic goal is not just feature growth. It is controlled self-evolution:

- Fae should be able to build and improve significant parts of herself based on user intent.
- Users should be able to shape "their own Fae" without waiting for core releases.
- We must avoid hard-coding behavior in Rust that can be safely represented as skills, manifests, prompts, or policies.

The hard constraint is failure recovery:

- If Fae can modify a large portion of her own behavior, she can also break that behavior.
- Therefore, we need a non-self-modifiable kernel that can still run locally, use tools, and repair/rollback Fae.
- This is why a default app still matters. It is the trust anchor and rescue substrate.

## Problem statement

We need to maximize self-authorship without allowing self-destruction.

In architecture terms, this means:

1. Deliberately separate immutable safety/runtime substrate from mutable behavior layer.
2. Move as much product behavior as possible out of Rust core and into skill/runtime content.
3. Keep an always-available Emergency Fallback mode that can recover corrupted behavior.

## Decision summary

We adopt a 4-layer model:

1. **Protected Kernel (PK)**: non-self-authored, non-negotiable runtime/safety core.
2. **Guarded Shared Layer (GSL)**: extensible Rust mechanisms with strict gates.
3. **Self-Authored Layer (SAL)**: skills/prompts/config content Fae can author and mutate.
4. **Ephemeral Runtime State (ERS)**: logs, temp artifacts, queue state.

Design rule:

- Behavior should live in SAL unless it is required for safety, authority, integrity, or deterministic recovery.

## Rust core deep dive: what Fae can write herself vs what must stay kernel

Coverage baseline: `203` Rust files in `src/**`.

Ownership classes:

- `PK`: Protected Kernel (human-maintained only).
- `GSL`: Guarded Shared Layer (human-reviewed Rust extension points).
- `SAL-target`: should migrate to self-authored skills/content over time.

### Module map (all top-level Rust modules)

| Module | Files | Ownership | Why |
|---|---:|---|---|
| `agent` | 3 | GSL | Tool wiring/provider glue; extensible but safety-sensitive. |
| `approval.rs` | 1 | PK | Human approval path for dangerous actions. |
| `audio` | 5 | PK | Real-time media path and device reliability substrate. |
| `bin` | 4 | PK | Host bridge and operational binaries define runtime boundary. |
| `canvas` | 12 | GSL | UI capability layer; can evolve but not self-author core transport. |
| `channels` | 8 | SAL-target | Domain integrations should move to skills/tools per-user preference. |
| `config.rs` | 1 | PK | Global policy surface and backend/tool policy authority. |
| `credentials` | 7 | PK | Secret storage and keychain semantics must stay trusted. |
| `diagnostics` | 2 | PK | Logging/rotation needed for recovery and forensics. |
| `doctor.rs` | 1 | PK | Health diagnosis entry point for repair flows. |
| `error.rs` | 1 | PK | Stable typed error contracts across system. |
| `fae_dirs.rs` | 1 | PK | Filesystem root authority and sandbox-safe path policy. |
| `fae_llm` | 69 | GSL | LLM/tool engine internals; extensible but heavily policy-gated. |
| `ffi.rs` | 1 | PK | Native embedding boundary and lifecycle control plane. |
| `host` | 6 | PK | Command/event protocol and authoritative host router. |
| `huggingface.rs` | 1 | GSL | Model metadata fetch logic; not a safety root. |
| `intelligence` | 10 | SAL-target | Personalization/research/proposals should become skill-driven. |
| `lib.rs` | 1 | PK | Public module composition and crate boundary. |
| `linker_anchor.rs` | 1 | PK | Build/link integration anchor. |
| `llm` | 2 | PK | Local model loading and fallback path required for rescue. |
| `memory` | 8 | PK | Durable memory schema, migration, backup, integrity. |
| `memory_pressure.rs` | 1 | PK | Stability guardrail under resource pressure. |
| `model_integrity.rs` | 1 | PK | Corruption detection before runtime damage. |
| `model_tier.rs` | 1 | GSL | Selection heuristics can evolve; not safety root. |
| `models` | 1 | PK | Model download/cache pipeline for guaranteed local boot. |
| `onboarding.rs` | 1 | GSL | Product flow logic, not system safety anchor. |
| `permissions.rs` | 1 | PK | Capability policy authority and grants/denies. |
| `personality.rs` | 1 | GSL | Prompt assembly framework is core; content is SAL. |
| `pipeline` | 3 | PK | Runtime orchestration authority and mode degradation logic. |
| `platform` | 3 | PK | OS capability mediation and platform boundaries. |
| `progress.rs` | 1 | GSL | UX progress events; low risk. |
| `runtime.rs` | 1 | PK | Runtime event contract consumed by host/UI and repair tooling. |
| `scheduler` | 5 | PK | Single authority execution, leases, dedupe, persistence. |
| `sentiment.rs` | 1 | SAL-target | Behavioral heuristics can be user/skill-authored. |
| `skills` | 13 | GSL | Skill runtime/lifecycle contracts stay guarded; skill content is SAL. |
| `soul_version.rs` | 1 | GSL | Versioning mechanism for mutable identity content. |
| `startup.rs` | 1 | PK | Boot readiness, model preload, disk checks. |
| `stt` | 1 | PK | Speech input engine path. |
| `system_profile.rs` | 1 | PK | Hardware/runtime profiling used for safe defaults. |
| `test_utils.rs` | 1 | GSL | Non-production helpers. |
| `theme.rs` | 1 | SAL-target | Personal expression should be mutable per user taste. |
| `tts` | 6 | PK | Speech output path for availability and fallback UX. |
| `ui` | 3 | GSL | Local control UI components; not self-auth target today. |
| `update` | 4 | PK | Self-update integrity, rollback, and apply control. |
| `vad` | 1 | PK | Speech detection for core interaction loop. |
| `viseme` | 1 | GSL | Presentation layer; can remain non-kernel. |
| `voice_clone.rs` | 1 | GSL | Feature module, not safety root. |
| `voice_command.rs` | 1 | GSL | Voice command grammar should be extensible. |
| `voiceprint.rs` | 1 | GSL | Biometric feature logic, not scheduler/memory authority. |

## Protected Kernel allowlist (concrete)

The following files/modules are proposed as **PK** and should not be self-modified by Fae:

- Runtime authority and host boundary:
  - `src/pipeline/coordinator.rs`
  - `src/runtime.rs`
  - `src/ffi.rs`
  - `src/host/contract.rs`
  - `src/host/channel.rs`
  - `src/host/stdio.rs`
  - `src/bin/host_bridge.rs`
- Safety and capability policy:
  - `src/permissions.rs`
  - `src/approval.rs`
  - `src/agent/approval_tool.rs`
  - `src/error.rs`
- Boot/model integrity and defaults:
  - `src/startup.rs`
  - `src/model_integrity.rs`
  - `src/models/mod.rs`
  - `src/llm/mod.rs`
- Memory durability and recoverability:
  - `src/memory/sqlite.rs`
  - `src/memory/schema.rs`
  - `src/memory/backup.rs`
  - `src/memory/migrate.rs`
- Scheduler authority:
  - `src/scheduler/runner.rs`
  - `src/scheduler/authority.rs`
- Secrets and updates:
  - `src/credentials/*`
  - `src/update/applier.rs`
- Filesystem and platform trust roots:
  - `src/fae_dirs.rs`
  - `src/platform/*`

Policy:

- PK changes require human-authored review and explicit promotion.
- Fae may propose PK changes but may not apply them autonomously.

## What Fae can self-author now

Already viable with current architecture:

- Skill content and behavior instructions:
  - Built-in/user skill markdown composition via `src/skills/mod.rs`.
- User identity/prompt overlays:
  - SOUL and onboarding prompt assets via `src/personality.rs`.
- Python skill package generation/install lifecycle:
  - `src/skills/skill_generator.rs` + `src/skills/python_lifecycle.rs`.
- Managed behavior toggles through config and scheduler APIs (within guarded policy).

## What should move from Rust to self-authored layer

Highest-value migration targets:

1. `src/channels/*` (Discord/WhatsApp/gateway adapters)  
   Rationale: channel behavior is high-variance and user-specific; ideal skill territory.
2. `src/intelligence/*` (research/proposal heuristics, extraction policies)  
   Rationale: personalization logic should evolve per user, not binary release.
3. `src/sentiment.rs`, parts of `src/voice_command.rs`, and preference-driven UX policies  
   Rationale: style/interaction is product-personality, not kernel safety.

## Current codebase observations that inform these decisions

Verified implementation facts:

- `LlmBackend` currently aliases `"api"` and `"agent"` to `Local` in `src/config.rs`.
- Voice model switching/info voice commands are currently stubbed as unavailable in `src/pipeline/coordinator.rs`.
- `skill.discovery.search` command routing exists, but handler currently returns empty results in `src/host/handler.rs`.
- `skill.python.start` and `skill.python.stop` currently log intent-only in `src/host/handler.rs`.
- Skill generation pipeline is template-first today (LLM loop deferred) in `src/skills/skill_generator.rs`.
- Local mistralrs provider does pass tools via `set_tools()` in `src/fae_llm/providers/local.rs`.
- `PythonSkillTool` exists in `src/fae_llm/tools/python_skill.rs`, but is not currently registered in main registry build path (`src/agent/mod.rs`).

These are not flaws in direction; they are useful boundary markers for phase planning.

## Why a default app is still required

Even with strong self-authorship, the default app remains necessary because it provides:

1. **Trust anchor**: immutable authority for permissions, scheduler leadership, secrets, and updates.
2. **Repair substrate**: ability to diagnose, quarantine, rollback, and restore broken self-authored behavior.
3. **Deterministic boot**: validated local model path and startup checks independent of cloud/external channels.
4. **Safety envelope**: bounded tool policy and auditable command/event control plane.

Without this anchor, “self-improvement” becomes “self-corruption with no guaranteed way back.”

## Emergency Fallback (Rescue Mode) contract

### Rescue intent

Rescue Mode is a minimal, always-available local runtime profile that can:

- start locally,
- reason enough to operate maintenance flows,
- use constrained tools,
- repair or rollback self-authored damage.

### Rescue activation triggers

Enter Rescue Mode when any of these hold:

- repeated runtime start failures,
- model integrity failure on primary path,
- repeated tool/runtime crashes tied to mutable layers,
- corrupted skill registry/state,
- explicit user request (`rescue on` command path to be added).

### Rescue model requirements

- Must be local-only.
- Must be pre-cached and integrity-checkable.
- Must support tool calling.
- Must prioritize reliability over capability.

### Rescue host command allowlist

Allow:

- `host.ping`, `host.version`
- `runtime.status`, `runtime.start`, `runtime.stop`
- `conversation.inject_text`
- `approval.respond`
- `config.get`
- `skills.reload`
- `skill.python.list`
- `skill.python.install`
- `skill.python.activate`
- `skill.python.disable`
- `skill.python.quarantine`
- `skill.python.rollback`
- `skill.generate`, `skill.generate.status`
- `scheduler.list`
- `scheduler.trigger_now` (restricted to maintenance task IDs)

Deny in Rescue:

- `data.delete_all`
- broad `config.patch` (allow only explicit safe keys if needed)
- network/channel mutation commands by default
- capability grant escalation outside rescue policy

### Rescue tool contract

Allow:

- `read`
- `write`/`edit` only inside approved mutable roots:
  - `~/.fae/skills/`
  - `~/.fae/python-skills/`
  - `~/.fae/SOUL.md`
  - `~/.fae/onboarding.md`
  - staging/temp recovery dirs

Default deny:

- unrestricted `bash`
- desktop automation
- high-risk external side-effect tools

Optional controlled `bash` profile:

- allowlist specific maintenance commands only (e.g., skill packaging/validation).

### Recovery invariants

Must always hold:

1. PK is non-self-modifiable.
2. Rescue path cannot be disabled by mutable layers.
3. Memory schema migration/backup path remains callable.
4. Scheduler authority/lease logic remains PK-owned.
5. Credential handling remains PK-owned.
6. Update rollback path remains PK-owned.

## Promotion pipeline for self-authored changes

All SAL changes should pass:

1. Generate in staging.
2. Validate structure and policy.
3. Canary run with bounded scope.
4. Promote to active.
5. Auto-quarantine on repeated failure.
6. Keep last-known-good snapshot for rollback.

This preserves autonomy while preserving recoverability.

## Practical phase plan

### Phase 1 (immediate)

- Finalize PK allowlist and enforce write gates by path/class.
- Add Rescue Mode runtime profile and command/tool allowlist.
- Register `PythonSkillTool` in guarded mode with explicit policy checks.
- Wire real `skill.discovery.search` to `SkillDiscoveryIndex`.

### Phase 2

- Move channel integrations behind skill interfaces (`src/channels/*` becomes adapters, not hardcoded behavior).
- Move intelligence proposal/research heuristics to skill policy packs.
- Add rescue health scoring and automatic rescue entry/exit criteria.

### Phase 3

- Add explicit mutation manifest for every mutable artifact (provenance, version, promotion state).
- Add kernel-signature checks for PK binaries/modules if needed for higher assurance deployments.

## Final architecture position

Fae should be self-building in behavior, not self-editing in trust boundaries.

The system should feel like:

- **mutable mind and skills**,  
- on top of an **immutable safety spine**.

That is the balance that gives both autonomy and survival.


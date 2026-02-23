# ADR-005: Self-Modification Safety Model

**Status:** Accepted
**Date:** 2026-02-21
**Scope:** Safety architecture across entire codebase (`src/**`, `~/.fae/skills/`, `SOUL.md`)

## Context

Fae is moving from fixed integrations toward a skill-centric architecture where she can build and improve parts of herself based on user intent. Users should be able to shape "their own Fae" without waiting for core releases.

The hard constraint is: **if Fae can modify a large portion of her own behavior, she can also break that behavior.** We need a non-self-modifiable kernel that can still run locally, use tools, and repair/rollback damage.

The strategic goal is **controlled self-evolution**: maximize self-authorship without allowing self-destruction.

## Decision

### 4-layer model

| Layer | Name | Mutability | Examples |
|-------|------|-----------|----------|
| 1 | **Protected Kernel (PK)** | Human-authored only | Pipeline, memory, scheduler, permissions, FFI, credentials, updates |
| 2 | **Guarded Shared Layer (GSL)** | Extensible with strict gates | Agent/tool wiring, canvas, skills runtime, prompt framework, voice commands |
| 3 | **Self-Authored Layer (SAL)** | Fae can author and mutate | Skills, SOUL overlays, config, Python packages, channel behavior, intelligence policies |
| 4 | **Ephemeral Runtime State (ERS)** | Transient | Logs, temp artifacts, queue state |

**Design rule:** Behavior should live in SAL unless required for safety, authority, integrity, or deterministic recovery.

### Protected Kernel (concrete allowlist)

These modules are PK — Fae may not modify them autonomously:

- **Runtime authority**: `src/pipeline/coordinator.rs`, `src/runtime.rs`, `src/ffi.rs`, `src/host/contract.rs`, `src/host/channel.rs`
- **Safety policy**: `src/permissions.rs`, `src/approval.rs`, `src/agent/approval_tool.rs`, `src/error.rs`
- **Boot/model integrity**: `src/startup.rs`, `src/model_integrity.rs`, `src/models/mod.rs`, `src/llm/mod.rs`
- **Memory durability**: `src/memory/sqlite.rs`, `src/memory/schema.rs`, `src/memory/backup.rs`, `src/memory/migrate.rs`
- **Scheduler authority**: `src/scheduler/runner.rs`, `src/scheduler/authority.rs`
- **Secrets and updates**: `src/credentials/*`, `src/update/applier.rs`
- **Trust roots**: `src/fae_dirs.rs`, `src/platform/*`

Policy: PK changes require human-authored review and explicit promotion. Fae may propose PK changes but may not apply them autonomously.

### Self-authored surface (what Fae can write now)

- Skill content and behavior instructions (`~/.fae/skills/`)
- User identity/prompt overlays (`SOUL.md`, onboarding)
- Python skill package generation/install lifecycle
- Config and scheduler APIs (within guarded policy)
- Channel adapter behavior (migration target from hardcoded Rust)

### Migration targets (Rust to SAL)

Highest-value migrations:
1. `src/channels/*` — Channel behavior is user-specific; ideal skill territory
2. `src/intelligence/*` — Personalization logic should evolve per user, not per binary release
3. `src/sentiment.rs`, parts of `src/voice_command.rs` — Style/interaction is personality, not kernel

### Emergency Fallback (Rescue Mode)

A minimal, always-available local runtime profile that can:
- Start locally with a pre-cached, integrity-checked model
- Reason enough to operate maintenance flows
- Use constrained tools (read + write only to approved mutable roots)
- Repair or rollback self-authored damage

**Rescue activation triggers:**
- Repeated runtime start failures
- Model integrity failure on primary path
- Repeated tool/runtime crashes tied to mutable layers
- Corrupted skill registry/state
- Explicit user request

**Rescue tool contract:**
- Allow: `read`, `write`/`edit` only inside `~/.fae/skills/`, `~/.fae/python-skills/`, `~/.fae/SOUL.md`, staging dirs
- Deny: unrestricted `bash`, desktop automation, high-risk tools

### Promotion pipeline

All SAL changes pass through:
1. Generate in staging
2. Validate structure and policy
3. Canary run with bounded scope
4. Promote to active
5. Auto-quarantine on repeated failure
6. Keep last-known-good snapshot for rollback

### Recovery invariants (must always hold)

1. PK is non-self-modifiable
2. Rescue path cannot be disabled by mutable layers
3. Memory schema migration/backup path remains callable
4. Scheduler authority/lease logic remains PK-owned
5. Credential handling remains PK-owned
6. Update rollback path remains PK-owned

## Phase 3 assurance (future)

### Mutation manifest

Explicit tracking for every mutable artifact:
- Path key, artifact kind, promotion state (staging/canary/active/quarantined/snapshot/removed)
- Monotonic version, BLAKE3 digest, size, provenance stamps
- Runtime sync at startup and on skill lifecycle operations

### Kernel signature checks

Optional integrity verification for PK modules:
- Modes: `off` (default), `warn`, `enforce`
- Manifest: TOML file listing PK binaries with SHA-256 digests
- Checked before model bootstrap in startup sequence

## Consequences

### Positive

- **Mutable mind on immutable spine** — users get customization without risk of self-destruction
- **Always recoverable** — Rescue Mode guarantees a path back from any self-authored damage
- **Clear boundaries** — PK allowlist makes it explicit what Fae can and cannot change
- **Progressive autonomy** — SAL surface grows as trust is established

### Negative

- **Complexity** — 4-layer model adds architectural overhead
- **PK rigidity** — kernel changes require human review, slowing some improvements
- **Rescue Mode limitations** — constrained tool set may not cover all repair scenarios

## References

- `src/permissions.rs`, `src/approval.rs` — Safety policy implementation
- `src/skills/` — Skill runtime and lifecycle
- `src/startup.rs` — Boot sequence and integrity checks

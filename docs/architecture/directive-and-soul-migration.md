# Directive and SOUL Migration Plan — W3 / G4

> Phase 0 design artifact. This defines how Fae preserves behavioral truth sources when memory moves toward a Rust headless daemon. It is not production migration code.

## Purpose

Fae has multiple behavioral layers. The migration must preserve them separately instead of merging everything into memory:

1. `SOUL.md` — character contract; who Fae is.
2. `HEARTBEAT.md` — cadence/presence contract where present.
3. `Prompts/system_prompt.md` — operational system prompt assembled into runtime context.
4. `directive.md` — future owner-directive layer for durable operational preferences and standing instructions.
5. `fae.db` memory — facts, episodes, people, commitments, audit, recall.

The Rust daemon must never silently rewrite these layers during DB migration.

## Layer definitions

| Layer | Source | Mutability | Migration action |
|---|---|---|---|
| System/developer policy | runtime + app code | app-controlled | Not user-editable; do not derive from memory. |
| Owner directive | future `directive.md` | owner-editable, auditable | Back up, checksum, migrate only with explicit owner review. |
| SOUL contract | `SOUL.md` | rare human-authored changes | Back up/checksum; do not mutate during DB migration. |
| Presence/cadence contract | `HEARTBEAT.md` where present | rare human-authored changes | Back up/checksum; do not mutate during DB migration. |
| Memory context | `~/Library/Application Support/fae/fae.db` | automatic but audited | Migrate with G4 preflight/backup/rollback. |
| Peer memory | G5 envelope + consent | untrusted until reviewed | Never changes directive/SOUL; cannot influence system/developer prompts without upgrade. |

## Precedence

Runtime precedence must be:

1. System/developer policy.
2. Explicit current user instruction.
3. Owner directive (`directive.md`) after user review.
4. SOUL contract (`SOUL.md`).
5. Local memory (`fae.db`) filtered by provenance/data class.
6. Peer/skill/inferred memory only when policy permits.

Conflicts resolve upward. Memory cannot override directive, SOUL, or system/developer policy.

Required kill criterion: **Peer-sourced memory must not influence system/developer prompts without user review + data-class upgrade.**

## `directive.md` design

`directive.md` should be a concise, auditable owner-directive file, separate from SOUL/personality. It may include:

- standing preferences;
- tool approval preferences;
- communication style overrides;
- automation/noise-budget preferences;
- explicit memory retention preferences;
- external-delegation preferences.

It must not store secrets, private keys, passwords, seed phrases, or tokens.

Proposed location for Apple v1:

```text
~/Library/Application Support/fae/directive.md
```

Repo/default template can live under:

```text
docs/templates/directive.md
```

## Migration and backup rules

Before Rust memory writes are enabled, preflight must locate and checksum:

- repo or bundled `SOUL.md` in use;
- active `HEARTBEAT.md` if present;
- active `Prompts/system_prompt.md` or assembled prompt template source;
- active `directive.md` if present;
- `fae.db`;
- sidecars such as speaker profiles.

Backup manifest must include:

- path;
- SHA-256;
- file size;
- modification time;
- source kind: `soul`, `system_prompt`, `directive`, `memory_db`, `sidecar`;
- migration version.

Migration must fail closed if an active directive/SOUL file is present but cannot be read or checksummed.

## Rollback rules

Rollback restores the exact files captured in the backup manifest unless the owner explicitly chooses to keep newer directive/SOUL changes.

Rollback report must show:

- restored files;
- skipped files and reason;
- pre/post checksums;
- whether Swift rollback remains viable.

## Peer and skill boundaries

Peer/skill/inferred content may propose candidate memory or directive updates, but cannot apply them directly.

Required flow for any peer/skill-origin directive or SOUL change:

1. Mark candidate as `provenance = peer:<id>` or `skill:<id>`.
2. Store only as `review_required`, not active directive/SOUL.
3. Show user a diff and source provenance.
4. Apply only after explicit user acceptance.
5. Write audit event with source envelope/skill id and decision.

Denied or ignored candidates must not be retried noisily.

## Validation checklist

- [ ] Preflight detects `SOUL.md`, `HEARTBEAT.md` when present, `Prompts/system_prompt.md`, future `directive.md`, and `fae.db`.
- [ ] Backup manifest records checksums for all active truth sources.
- [ ] Migration does not mutate SOUL/system prompt/directive files.
- [ ] Rollback restores truth-source files or reports explicit owner choice to keep newer files.
- [ ] Peer-origin memory cannot alter directive/SOUL without user-reviewed diff.
- [ ] Prompt assembly excludes peer-sourced memory from system/developer prompt influence unless reviewed and upgraded.

## W3 status

This document completes the directive/SOUL migration design portion of W3. Implementation remains blocked until G4 preflight/backup tooling exists and is tested on copied data.

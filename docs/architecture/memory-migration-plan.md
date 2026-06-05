# Memory Migration / Data-Safety Plan (G4) — 2026-06-01

> Phase 0 artifact for `docs/architecture/headless-core-impl-plan-2026-06-01.md` G4. Memory is production-critical; this plan preserves compatibility and rollback before any Rust daemon owns memory writes.

## Sources of truth

- Global/project guardrails: memory must preserve on-disk compatibility, supersession lineage, automatic recall/capture, auditability, and non-test force-unwrap/panic-free mutation paths.
- Current Swift implementation:
  - `native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift`
  - `native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift`
  - `native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift`
  - `native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift`
- Storage root: `~/Library/Application Support/fae/`
- Primary durable files: `fae.db`, `backups/`, speaker/profile sidecars where present.

## Migration strategy

**Use in-place SQLite compatibility, not export/import.** The Rust core should open the existing `fae.db`, validate it, apply only forward-compatible migrations, and preserve Swift rollback until the Rust path has passed live validation.

### Compatibility rules

1. Rust must read the current schema version from schema metadata.
2. If schema is older than current, apply incremental migrations with audit entries.
3. If schema is newer than Rust understands, Rust must refuse mutation and run read-only or abort with a clear error.
4. Rust must never silently overwrite conflicting durable facts.
5. Rust must preserve record kinds/statuses and supersession lineage.
6. Every mutation must append an auditable record.

## Data classes to preserve

| Data | Migration action |
|---|---|
| `fae.db` memory records | Direct SQLite read/write after preflight and backup. |
| statuses: active/superseded/invalidated/forgotten | Preserve exactly; do not resurrect inactive records. |
| `supersedes` lineage | Validate chains before and after migration. |
| memory audit/event records | Append migration/audit entries; do not truncate. |
| embeddings / FTS indexes | Validate search paths; rebuild only from preserved records if required. |
| backups | Create timestamped pre-migration backup before Rust writes. |
| speaker profiles / sidecars | Copy into backup manifest and validate separately. |
| `SOUL.md`, `HEARTBEAT.md`, prompts, directive files | Treat as behavioral truth sources; do not mutate during DB migration. Locate and back up any active directive/user-instruction files before Rust writes are enabled. |

## Migration phases

### M1 — Preflight validation

- Locate storage root.
- Run SQLite `PRAGMA integrity_check`.
- Read schema version.
- Verify required tables/indexes exist.
- Count rows per table.
- Compute checksums for `fae.db` and sidecars.
- Sample records and deserialize using Rust types.
- Emit `migration-preflight.json`.

### M2 — Backup

- Use SQLite backup API or `VACUUM INTO` for a consistent DB copy.
- Copy sidecars into `backups/<timestamp>/`.
- Write manifest with schema version, row counts, checksums, app version, and Rust migrator version.
- Abort if backup cannot be verified.

### M3 — Rust compatibility migration

- Open DB in transaction.
- Apply only additive/forward-compatible schema extensions.
- Insert explicit audit event: `op = migrate`, including previous/new schema and manifest path.
- Do not rewrite existing records except for documented migration fields.

### M4 — Postflight validation

- Re-run integrity check.
- Re-count rows and compare with preflight.
- Validate supersession chains.
- Validate statuses are unchanged except documented migrations.
- Run representative recall/search tests.
- Verify backup restoration can be simulated to a temp path.

### M5 — Rollback

Rollback must be a first-class command before Rust writes are enabled:

1. Stop daemon.
2. Move current `fae.db` aside with timestamp.
3. Restore backup DB and sidecars.
4. Re-run integrity check.
5. Write rollback report.
6. Restart Swift app or Rust daemon in read-only mode.

## Adversarial memory resilience

Peer-sourced, skill-sourced, inferred, or network-sourced content must carry machine-readable provenance and data-class metadata before it can influence durable memory. The Rust daemon must treat this as a write gate, not a display hint.

### Required metadata additions

The migration must add or reserve fields in `MemoryRecord.metadata` or forward-compatible columns before Rust memory writes are enabled:

| Field | Required values / format | Purpose |
|---|---|---|
| `provenance` | `user`, `peer:<agent_id>`, `skill:<skill_id>`, `inferred` | Closed source class for policy decisions. |
| `data_class` | `private_user`, `local_operational`, `shareable_context`, `peer_claim`, `untrusted` | Retrieval/export boundary. |
| `consent_id` | nullable consent receipt id | Links peer/shared memory to user consent. |
| `source_envelope_id` | nullable G5 envelope id | Auditable peer ingress lineage. |
| `ingestion_path` | `conversation`, `scheduler`, `tool`, `skill`, `peer_envelope`, `migration` | Explains how the record entered memory. |
| `review_status` | `unreviewed`, `user_reviewed`, `policy_reviewed`, `rejected` | Controls prompt/retrieval eligibility. |
| `policy_hash` | hash of policy version used at write time | Allows future re-review after policy changes. |

Compatibility rule: if old Swift records lack these fields, migration must inspect source links, artifact types, tags, metadata, and source turn context before assigning provenance. Records confirmed as local owner/user conversation may be treated as `provenance = user`, `data_class = private_user`, `review_status = user_reviewed` after backup/preflight. Legacy `cowork_attachment`, `proactive`, imported artifact, skill, or ambiguous records must default to `review_status = unreviewed` and no higher than `data_class = local_operational` until reviewed.

### Inbound memory write gate

All candidate memory writes must pass this sequence before persistence:

1. Parse source through a closed source enum. Unknown source is denied.
2. Attach `provenance`, `data_class`, `ingestion_path`, and policy version.
3. Run sensitive-content and PII/exfil scanners before persistence.
4. Reject attempts to store secrets, credentials, wallet material, private keys, recovery codes, or hidden instructions unless the user explicitly requests durable retention and the record is marked non-shareable.
5. Peer facts default to `data_class = peer_claim` or `untrusted`; they may be displayed for review but not merged as owner facts.
6. Peer facts can become `shareable_context` only with a matching consent receipt and policy approval.
7. Peer/skill/inferred facts cannot become `private_user` or influence prompts without explicit user review.
8. Every accepted, rejected, downgraded, or review-required candidate writes an audit event.

Required kill criterion: **Peer-sourced memory must not influence system/developer prompts without user review + data-class upgrade.**

### Query-probing defense

Memory retrieval must enforce the same boundary as writes:

- Peer and skill contexts receive data-class scoped search only.
- `private_user` records are never returned to peer contexts.
- Query volume, repeated near-duplicate queries, broad wildcard-like queries, and sensitive-entity probes are rate-limited and audited.
- Retrieval for tool execution requires the tool broker/capability path; peer messages cannot directly query memory.
- `forgotten`, `invalidated`, and `superseded` records are excluded unless the user requests audit/history view.
- Search snippets shown to external/peer contexts must be redacted and include provenance labels.

### Audit requirements

Adversarial-memory audit events must include:

- source/provenance and data class;
- consent id / envelope id where applicable;
- policy decision: allow, deny, downgrade, review-required;
- scanner reason codes;
- redacted content hash, never raw secret text;
- actor/client id and capability scopes;
- supersession or rollback id if changed later.

### Implementation stop rules

- Rust memory write ownership remains blocked until this metadata exists and is validated on a copied DB.
- Peer-origin memory writes remain blocked until the G5 envelope gate, consent receipt storage, and audit writer are integrated.
- Any missing provenance or data class fails closed.

## Audit invariants

- Every insert/patch/supersede/invalidate/forget/migrate operation writes an audit entry.
- Supersession chain is append-only.
- `forgotten` data is not exported or reactivated.
- Conflicting durable facts require supersession, not overwrite.
- Migration reports are user-inspectable.

## Validation tests

| Test | Gate |
|---|---|
| Empty DB preflight | Must pass. |
| Real user DB preflight on copy | Must pass before any live write. |
| Backup/restore round trip | Must pass. |
| Supersession chain validation | Must pass. |
| Status preservation | Must pass. |
| FTS/search recall parity | Must pass or document rebuild. |
| Swift rollback smoke | Must pass until Rust daemon is production owner. |
| Corrupt DB handling | Must fail closed with backup untouched. |
| Missing provenance/data class after migration | Must fail closed before Rust writes. |
| Peer-memory prompt exclusion | Peer-sourced records must not enter system/developer prompt assembly without user review + data-class upgrade. |
| PII/exfil scanner denial | Secrets/credentials/wallet material candidates must be rejected or forced to explicit user review. |
| Query-probe rate limit/audit | Repeated broad/sensitive peer queries must be throttled and audited. |
| Directive/SOUL/HEARTBEAT peer proposal | Peer/skill-origin changes must remain review-required and cannot auto-apply. |

## G4 status

This artifact satisfies the **plan** part of G4. G4 is not fully complete until:

- a Rust migrator/preflight tool exists,
- it runs against a copy of a real `fae.db`,
- backup/rollback is demonstrated,
- Swift rollback remains viable,
- and owner signs off on the migration report.

Until then, the Rust daemon may read memory only in controlled tests and must not become the production memory writer.

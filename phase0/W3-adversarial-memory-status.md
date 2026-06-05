# W3 — G4 adversarial-memory + directive status

Status: **done as Phase-0 design**  
Blocker class: **pre-v1-blocker**  
Evidence grade: **repo-verified design**

## Deliverables

- Expanded `docs/architecture/memory-migration-plan.md` with adversarial memory resilience.
- Added `docs/architecture/directive-and-soul-migration.md`.
- Added `docs/templates/directive.md` template.

## What W3 now specifies

- `provenance`: `user`, `peer:<agent_id>`, `skill:<skill_id>`, `inferred`.
- `data_class`: `private_user`, `local_operational`, `shareable_context`, `peer_claim`, `untrusted`.
- Metadata for consent, G5 source envelope, ingestion path, review status, and policy hash.
- Inbound memory write gate with closed source enum, PII/exfil scan, data-class assignment, denial audits.
- Query-probing defense: rate limits, scoped retrieval, no `private_user` records to peer contexts, audit of suspicious probes.
- Directive/SOUL/HEARTBEAT migration and backup rules.
- Legacy source classification rules for old records without provenance.
- W3-specific validation tests for missing provenance, peer prompt exclusion, PII denial, query-probe auditing, and peer-origin directive/SOUL/HEARTBEAT proposal rejection.
- Prompt precedence and rollback rules.

Required kill criterion is included exactly:

> Peer-sourced memory must not influence system/developer prompts without user review + data-class upgrade.

## Remaining implementation blockers

- Rust preflight/backup/migration tool still does not exist.
- No copied real `fae.db` migration proof yet.
- No production PII/exfil scanner integration yet.
- No production prompt-assembly enforcement yet.
- No production consent receipt storage integration yet.

## Gate-exit impact

W3 design requirements are satisfied for Phase 0. Production memory writes remain blocked until G4 implementation, backup/rollback, copied-DB validation, and owner signoff.

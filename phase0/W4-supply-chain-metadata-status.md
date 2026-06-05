# W4 — Supply-chain + metadata sign-off status

Status: **done as Phase-0 design draft; review pending**  
Blocker class: **pre-v1-blocker**  
Evidence grade: **repo-verified design + local x0x docs/changelog verified**

## Deliverables

- `docs/security/model-supply-chain-and-updates.md`
- `docs/security/x0x-metadata-threat-model.md`
- `docs/templates/models.lock.example`

## What W4 now specifies

Supply-chain:

- `models.lock` schema with source repo/revision, file size, SHA-256, loader, role, license, hardware profile, approver.
- Fail-closed loader behavior on missing/mismatched/unverifiable artifacts.
- Staged download and atomic activation.
- Tool/runtime verification for `uv` and similar installers.
- Signed daemon/app update threat model with downgrade protection and emergency revocation.

Metadata/x0x:

- Presence default `off`.
- Private topic HMAC-SHA256 derivation and rotation.
- ant-quic MASQUE relay policy modes (`direct_preferred`, `relay_on_sensitive_context`, `relay_required`, `offline`) so x0x can expose relay options and Fae can choose IP-masking behavior where appropriate.
- Exposure matrix for presence, stable IDs, group discovery, topic subscriptions, roster changes, request-access events, memory-share offers, IP/geolocation, and bootstrap visibility.
- Owner residual-risk signoff line.
- Explicit incorporation of recent x0x secure-groups work: TreeKEM improves future content confidentiality but does not remove Fae metadata, consent, audit, provenance, or prompt-isolation gates.

## x0x secure-groups evidence

Local x0x repo evidence:

- `../x0x/CHANGELOG.md` shows `v0.20.0` TreeKEM secure-group membership and `v0.20.1` release hygiene.
- `../x0x/docs/adr/0012-treekem-default-secure-groups.md` describes real TreeKEM as default secure group plane for new confidential groups.
- `../x0x/docs/design/named-groups-full-model.md` describes discovery/privacy policy and named-group metadata controls.

Caveat: local x0x working tree was dirty during review, so final Fae release claims should cite clean published tags/releases.

## Review result

Red-team and oracle review completed. No hard design blockers were found. One red-team request was patched: `docs/security/model-supply-chain-and-updates.md` now has an owner residual-risk signoff line matching the metadata threat model.

## Remaining blockers

- Owner signature on supply-chain and metadata residual risk.
- Implementation of `models.lock`/loader/update verification remains pre-v1.

## Gate-exit impact

W4 design artifacts are complete for Phase 0, pending owner residual-risk signoff. W4 should not be marked fully done until that signoff is accepted.

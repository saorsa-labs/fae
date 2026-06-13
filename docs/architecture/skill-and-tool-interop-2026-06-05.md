# Fae Skill & Tool Interop — agentskills.io + MCP

> Status: **Design draft** (2026-06-05) · Owner: David Irvine · Layer: headless Rust core (+ current Swift app)
> Implements D4 + D5 of [`conductor-positioning-and-scope-2026-06-05.md`](./conductor-positioning-and-scope-2026-06-05.md).
> The butler's two "hire help" surfaces: **skills** (agentskills.io) and **tools** (MCP).

## 1. Purpose

Let the butler hire any capability without bespoke integration, via the two durable open standards — **agentskills.io** (portable skills) and **MCP** (portable tools) — while keeping Fae's stronger security posture. Every import is **untrusted input** until vetted (D5).

## 2. agentskills.io ↔ Fae SKILL.md — field mapping

**Fae today** (`SkillManifest`, per CLAUDE.md): `schemaVersion: 1`, `capabilities: ["execute"]`, `allowedTools: ["run_skill"]`, `integrity.checksums` (SHA-256). **agentskills.io**: required `name` + `description`; optional `license`, `compatibility`, `metadata`, `allowed-tools`.

The two are reconcilable with a thin **bidirectional adapter** — Fae stays spec-compliant by parking its security/runtime extensions under `metadata`:

| Concept | agentskills.io | Fae SKILL.md | Mapping |
|---------|----------------|--------------|---------|
| Identity | `name` (≤64, `[a-z0-9-]`, = folder) | `name` | 1:1 (enforce the charset/length on import) |
| Routing | `description` (what + when) | `description` | 1:1 — the activation trigger |
| License | `license` | — | passthrough; default unknown → flag for review |
| Env reqs | `compatibility` | (implicit in body) | passthrough; surface to `DependencyInstaller`/`UVRuntime` |
| Tool fence | `allowed-tools` | `allowedTools` | **alias** (`allowed-tools` ↔ `allowedTools`) |
| Runtime kind | — | `capabilities: ["execute"]` | → `metadata.fae.capabilities` |
| Schema | — | `schemaVersion: 1` | → `metadata.fae.schemaVersion` |
| Integrity | — (spec has none) | `integrity.checksums` (SHA-256) | → `metadata.fae.integrity` **(Fae-computed on import, see §4)** |

**Body conventions:** adopt Hermes' section order (`# X Skill` · intro · `## When to Use / Prerequisites / How to Run / Quick Reference / Procedure / Pitfalls / Verification`) for Fae-authored and exported skills — improves quality and makes Fae skills portable-readable by other harnesses. The P2 productivity wave (`mail-himalaya`, `calendar-caldav`, `contacts-carddav`) is the reference implementation for executable built-ins that keep agentskills.io-compatible frontmatter while enforcing Fae's stricter SHA-256 `MANIFEST.json` integrity layer.

**Progressive disclosure:** already 1:1 — Fae injects names+descriptions in the prompt (`SkillManager.promptMetadata()`) and loads the full body on `activate_skill`. The standard's three tiers (metadata ~100 tok → body <5000 tok → resources on demand) map exactly. No change.

**Template tokens:** adopt a Fae equivalent of Hermes' `${HERMES_SKILL_DIR}` / `${HERMES_SESSION_ID}` (e.g. `${FAE_SKILL_DIR}`) substituted at activation so a SKILL.md can reference bundled `scripts/` with a ready-to-run absolute path — removes a `skill_view` round-trip. Off-switch via config.

## 3. Directory & resource model

agentskills.io and Fae already agree: a skill is a directory — `SKILL.md` (required) + optional `scripts/`, `references/`, `assets/`/`templates/`. Fae's existing `SkillMigrator` (flat `.py` → directory) and `scripts/*.py` checksum model already fit. Multi-file skills import as directories; single-file `SKILL.md` (URL installs) import as instruction-only skills.

## 4. Import pipeline — the mandatory security gate (D5)

Imported skills are untrusted. **No skill activates until it passes the gate.**

```
SOURCE (agentskills.io hub | git | direct URL | local)
  │
  ▼ [1] FETCH ............... NetworkTargetPolicy (block localhost/metadata/RFC1918)
  ▼ [2] PARSE .............. SkillParser frontmatter; enforce name charset/length; map fields (§2)
  ▼ [3] PIN ................ Fae computes SHA-256 over SKILL.md + every script/resource
  │                          → writes metadata.fae.integrity (the spec ships none)
  ▼ [4] REVIEW ............. SkillSecurityReview: static scan of scripts, allowed-tools sanity,
  │                          secret/exfil patterns, typosquat-name check vs installed set
  ▼ [5] QUARANTINE ......... store as review_status = unreviewed, provenance = community:<source>
  │                          (NOT active; never enters the prompt's available-skills list yet)
  ▼ [6] APPROVE ............ owner sees source + diff + risk; on accept → review_status = user_reviewed
  ▼ [7] ACTIVATE .......... eligible for activate_skill; checksums re-verified at load (fail-closed)
```

- **Why stricter than the standard:** agentskills.io validation is `skills-ref` (well-formedness) only — no signing, no behavioural scan. ClawHavoc (2,400 typosquatted malicious skills) makes that inadequate. Fae pins its *own* SHA-256 on import and gates on `SkillSecurityReview`.
- **Provenance carries through** like the memory model (W3): community/peer skills are `provenance = community:<source>` / `peer:<agent>`, never silently trusted; a skill cannot mutate directive/SOUL/system prompts (it's `review_required`, mirroring peer memory).
- **Typosquat defence:** reject/flag a name within edit-distance 1 of an installed or built-in skill (the ClawHavoc vector).

## 5. Export — publish Fae's auto-skills

`MetaOptSkillGenerator` already writes instruction skills from capability gaps. Add an **export path**: emit an agentskills.io-compliant `SKILL.md` (Fae extras under `metadata.fae`, spec fields at top level, Hermes section order), optionally publish to the hub. This makes Fae a *contributor* to the portable ecosystem, not just a consumer — and lets a user's two Faes share learned skills (under the same provenance/security model).

## 6. MCP client — the tools surface

The butler gains an **MCP client** in the headless core (parity with Hermes' MCP support; the second "hire help" surface).

- **Discovery:** connect to configured MCP servers; enumerate their tools into the `ToolRegistry` as a distinct, namespaced source (`mcp:<server>:<tool>`).
- **Gating — reuses existing layers, no new security model:**
  - `NetworkTargetPolicy` on server endpoints (block localhost/metadata/RFC1918 unless explicit).
  - `ToolRegistry` mode filtering + tool-mode (owner `full`; guests none).
  - Mutating MCP tools route through the normal approval/DamageControl path.
  - **Cross-owner** MCP tool invocation (an MCP server reached *through* another owner's agent) requires a `CapabilityGrant` (`WriteTool`/`ReadTool` scope) — GrantEnforcer, grants doc §4.
- **Provenance:** MCP tool *results* are untrusted input (W3) — they inform but do not instruct; they enter memory only via the inbound gate with appropriate `data_class`.
- **Relationship to the plugin system:** `~/.fae-plugins` (Claude-Code-compatible) stays for local Fae-native plugins; MCP is the *remote/standard* tool surface. Two complementary mechanisms, one registry.

## 7. Unified into the conductor

Both surfaces feed the butler's routing the same way:

- A hired **skill** is a local capability → appears in `SkillManager.promptMetadata()`; activation is local.
- A hired **MCP tool** is a local capability → appears in `ToolRegistry`.
- A **mesh agent / Runner** is a remote capability → `CapabilityIndex` (advertisement spec).

The conductor's routing brain (E4B) sees one unified menu — *answer locally · run a skill · call a tool · delegate to the mesh · orchestrate work* — and chooses. "Hiring help" (install a skill / connect an MCP server) just enlarges the menu; the security gate (D5) governs what reaches it.

## 8. Build surface (net-new)

1. **Frontmatter adapter** — bidirectional agentskills.io ↔ Fae field map (§2), with charset/length enforcement and `allowed-tools` aliasing.
2. **Import pipeline** — §4 stages wired through existing `SkillParser` / `NetworkTargetPolicy` / `SkillSecurityReview` / `SkillManifest`; quarantine + approval UX; typosquat check.
3. **Export path** — `MetaOptSkillGenerator` → agentskills.io SKILL.md (+ optional hub publish).
4. **Template-token substitution** — `${FAE_SKILL_DIR}`/`${FAE_SESSION_ID}` at activation.
5. **MCP client** — headless-core MCP client, namespaced registration into `ToolRegistry`, gating reuse.

Reuses: `SkillParser`, `SkillManifest`, `SkillSecurityReview`, `SkillMigrator`, `SkillManager`, `ToolRegistry`, `NetworkTargetPolicy`, DamageControl/approval, GrantEnforcer, memory inbound gate. No new security primitives.

## 9. Acceptance criteria

- [ ] A real agentskills.io skill (single-file URL **and** multi-file dir) imports, maps fields correctly, and round-trips back to spec-compliant SKILL.md.
- [ ] **No imported skill activates before** SHA-256 pin + `SkillSecurityReview` + owner approval; checksums re-verified at load (fail-closed).
- [ ] Typosquat name (edit-distance 1 of installed/built-in) is rejected/flagged.
- [ ] A Fae auto-generated skill exports to valid agentskills.io format.
- [ ] An MCP server connects; its tools appear namespaced in `ToolRegistry`, gated by mode + NetworkTargetPolicy; a mutating MCP tool triggers approval.
- [ ] Cross-owner MCP/skill use requires a `CapabilityGrant`; ungranted use fails closed.
- [ ] Imported-skill and MCP-result facts enter memory only via the inbound gate with `community:`/`mcp:` provenance; cannot reach system/developer prompts without review.
- [ ] Works Apple + Linux (v1); Windows post-v1 (S11).

## 10. Open questions

1. **Hub trust tiers** — does Fae weight agentskills.io hub-listed skills differently from bare-URL installs? Lean: same gate for all; hub listing is not trust.
2. **`compatibility` enforcement** — block activation if `compatibility` (e.g. Python 3.14+) isn't met, or warn? Lean: block executable skills, warn instruction-only.
3. **MCP server lifecycle** — long-lived connections vs on-demand; who starts/stops them in the headless daemon (scheduler-managed?).
4. **Auto-skill publish consent** — publishing Fae's learned skills must honour `feedback_personal_data_boundary` (ship the *ability*, not personal data) — exported skills must be scrubbed of user-specific content. Gate export on the same egress membrane as cross-owner results.

## 11. References
- `conductor-positioning-and-scope-2026-06-05.md` (D4/D5), `conductor-capability-grants-2026-06-05.md` (`ReadTool`/`WriteTool` scopes, GrantEnforcer), `conductor-capability-advertisement-2026-06-05.md` (unified routing menu).
- `memory-migration-plan.md` (provenance/`data_class`, inbound gate), `fae-to-fae-governance.md` (W3 untrusted-input).
- Spec: [agentskills.io/specification.md](https://agentskills.io/specification.md). Precedent: Hermes skills (`skill_manage`, sections), Hermes MCP support.
- Fae: `SkillManifest.swift`, `SkillParser.swift`, `SkillSecurityReview.swift`, `SkillMigrator.swift`, `SkillManager.swift`, `ToolRegistry.swift`, `NetworkTargetPolicy.swift`, `~/.fae-plugins` plugin system.
- Memory: `reference_hermes_agent.md`, `reference_openclaw_skills.md` (ClawHavoc), `feedback_personal_data_boundary.md`.

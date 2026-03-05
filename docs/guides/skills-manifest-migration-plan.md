# Skills Manifest Migration Plan

## Goal

Migrate and standardize skills so configuration is **skill-owned** and Fae can configure behavior conversationally.

Primary policy:

- **Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

## Migration scope

1. Built-in instruction skills
2. Built-in executable skills
3. Personal/community directory-based executable skills
4. Legacy flat `.py` skills (no skill directory)
5. Configurable skills with `settings` contract (channels first)

## Runtime policy (current)

- Instruction skills: manifest optional, conservative defaults allowed.
- Executable skills: valid `MANIFEST.json` required for execution.
- Executable skills: valid `MANIFEST.json` also required before `activate_skill` may inject the skill body into prompt context.
- Configurable skills: should define `settings` contract when they expose user-facing setup.
- Legacy flat `.py` skills: treated as non-compliant until migrated.
- Progressive disclosure is the default: prompt inventory exposes only skill metadata until a skill is explicitly activated.

## Why this migration exists

Without manifest contracts, behavior tends to drift into hardcoded app logic.

With manifest + settings contracts:

- Fae can discover configurable capabilities automatically,
- ask plain-English missing-field prompts,
- launch guided forms from chat,
- persist channel settings from the contract itself instead of channel-specific switch statements,
- render settings status from one source of truth,
- and let users request more changes directly.

## Rollout phases

### Phase 1 — Detection (shipped)

- Discover skills and report manifest status:
  - compliant
  - missing
  - invalid
- Surface issues in logs/diagnostics.

### Phase 2 — Enforced execution gate (shipped)

- Deny executable skill run if manifest missing/invalid.
- Keep instruction skills functional.
- Enforce integrity checks for executable skill payloads.

### Phase 3 — Settings-contract adoption (in progress, channels first)

- Add optional `settings` block to manifests.
- Use settings contract for capability state, prompting, and UI generation.
- Ship first-party channel skills (`discord`, `whatsapp`, `imessage`) under this model.

### Phase 4 — Legacy `.py` migration helper (planned)

- Wrap legacy script into `skills/{name}/scripts/{name}.py`
- Generate `SKILL.md` template
- Generate conservative `MANIFEST.json`
- Optionally generate starter `settings` contract when configuration is required

## Validation checklist

At load/discovery time:

- schema version supported by runtime
- `capabilities` non-empty for executable skills
- executable skills include `execute`
- executable skills declare allowed tools correctly
- timeout within allowed range
- allowed domains validated (if present)
- integrity checksums cover executable payloads (`SKILL.md`, scripts)
- settings contract validates (field IDs/types/actions)
- no secret defaults in manifest settings

## Storage and security expectations

- Secret fields are keychain-backed.
- Sensitive values are never echoed in logs/diagnostics.
- Status responses report presence/validity, not raw secret values.
- Disconnect/removal should clear both config-store and keychain values where applicable.

## Success criteria

- Executable skills are manifest-compliant by default.
- Channel and settings onboarding flows are contract-driven.
- Users can request most configuration changes in natural language.
- Reduced hardcoded per-integration settings logic in app UI/runtime.

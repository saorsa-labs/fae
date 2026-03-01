# Skills Manifest Migration Plan

## Goal

Migrate existing executable skills to `MANIFEST.json` capability declarations without breaking user workflows.

## Inventory classes

1. Built-in instruction skills
2. Built-in executable skills
3. Personal/community directory-based executable skills
4. Legacy flat `.py` skills (no skill directory)

## Migration policy

- Instruction skills: optional manifest, conservative defaults allowed.
- Executable skills: manifest required for execution.
- Legacy flat `.py` skills: treated as non-compliant until migrated.

## Phased rollout

## Phase 1: Detection (non-breaking)

- Discover skills and report manifest status:
  - compliant
  - missing
  - invalid
- Emit warnings in logs/UI diagnostics only.

## Phase 2: Auto-stub generation

- Generate conservative `MANIFEST.json` stubs for missing executable directory skills.
- Mark generated files as user-editable.

## Phase 3: Enforced execution gate

- Deny executable skill run if manifest missing/invalid.
- Keep instruction skills functional.

## Phase 4: Legacy `.py` migration helper

- Create migration utility:
  - wraps legacy script into `skills/{name}/scripts/{name}.py`
  - creates `SKILL.md` template
  - creates conservative `MANIFEST.json`

## Validation checklist

- schemaVersion matches runtime
- `capabilities` non-empty
- executable includes `execute`
- executable includes `allowedTools: ["run_skill"]`
- timeout within allowed range
- allowedDomains optional but validated if present
- executable manifests include integrity checksums for `SKILL.md` and scripts
- integrity verification blocks tampered executable skills

## Rollback strategy

- Keep legacy files untouched during conversion.
- Write migrated skill into new directory path.
- Allow user to revert by deleting migrated directory.

## Success criteria

- >= 95% executable skills migrated or manifest-compliant before enforcement default-on
- zero critical breakage in built-in skill set
- clear user-facing errors for non-compliant skills

# Skill Settings Contract v1

Status: Implemented (Swift runtime)
Scope: Skill manifests + channel setup orchestration + settings UX
Updated: 2026-03-02

## 1) Purpose

Provide one contract that powers:

1. Skill-declared required configuration
2. Conversational setup prompts in plain English
3. Guided settings/form rendering in UI
4. Capability/diagnostics state reporting

Design preference: **Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

---

## 2) Manifest shape

`MANIFEST.json` supports an optional `settings` block on top of existing manifest schema.

> Compatibility note: runtime manifest schema compatibility remains stable; `settings` is optional and non-breaking for existing skills.

Example (abridged):

```json
{
  "schemaVersion": 1,
  "capabilities": ["execute", "configure", "status", "test_connection"],
  "settings": {
    "version": 1,
    "kind": "channel",
    "key": "discord",
    "display_name": "Discord",
    "description": "Connect Fae to Discord",
    "fields": [],
    "actions": {
      "status": "status",
      "configure": "configure",
      "test": "test_connection",
      "disconnect": "disconnect"
    }
  }
}
```

---

## 3) Field model

Each field can define:

- `id` (stable key)
- `type` (`text`, `secret`, `bool`, `select`, `multiselect`, `number`, `url`, `phone`, `json`)
- `label`
- `required`
- `prompt` (plain-English setup prompt)
- `placeholder` (optional)
- `help` (optional)
- `default` (optional, non-secret only)
- `options` (select/multiselect)
- `validation` rules
- `required_when` conditions
- `sensitive` (default true for secret)
- `store` (`secret_store` | `config_store`)

---

## 4) Runtime orchestration contract

Channel setup orchestration is exposed through `channel_setup` tool actions:

- `list`
- `status`
- `next_prompt` (single missing-field question)
- `request_form` (guided multi-field request)
- `set`
- `disconnect`

Flow:

1. Discover configurable skills
2. Compute missing/invalid fields
3. Ask next question in plain English (`next_prompt`) or request form (`request_form`)
4. Persist values (`set` / config patch path)
5. Re-check status and confirm configured state

---

## 5) Security and storage rules

1. Secret channel fields are keychain-backed in runtime compatibility path.
2. Sensitive values are not echoed in logs or diagnostics output.
3. Capability/status reporting reveals completeness/validity only.
4. Disconnect clears stored values via contract/compatibility routes.

---

## 6) UI rendering expectations

Settings should derive from skill contract/capability snapshot where possible:

- status badges and missing-field indicators
- configure-via-chat actions
- guided forms for multi-field input

Avoid bespoke hardcoded channel forms unless required by platform constraints.

---

## 7) Backward compatibility

- Skills without `settings` remain valid.
- Unknown/invalid settings blocks are rejected safely.
- Legacy inline config values are still read in compatibility paths during migration.

---

## 8) Validation checklist

At manifest load/discovery:

- unique field IDs
- valid field types
- required labels/prompt quality where applicable
- select options non-empty when required
- action names map to declared capabilities
- no secret defaults in manifest

---

## 9) Current first-party channels

- `channel-imessage`
- `channel-whatsapp`
- `channel-discord`

All are onboarded under the skill-first settings model with conversational setup guidance.

# Progressive Disclosure And Permissions

Fae should earn context and trust in small steps.

## Skills

- The system prompt advertises only skill name, description, and type.
- Full `SKILL.md` instructions are loaded only after `activate_skill`.
- Invalid or tampered executable skills must stay out of both execution and prompt injection.

## Channel Setup

- Channel setup should start in conversation, not in a dense settings panel.
- Ask for one missing field at a time with `channel_setup next_prompt`.
- Offer a guided form only when the user prefers it or when it is materially faster.
- Persist values from the skill contract itself: field id, storage class, validation, and disconnect behavior.

## Permission Popup

- The popup is the default approval surface for routine trust decisions.
- Available choices:
  - `No`
  - `Yes`
  - `Always`
  - `Allow All Read-Only`
  - `Allow All In Current Mode`
- `Always` remembers a single tool.
- `Allow All Read-Only` trusts low-risk tools globally.
- `Allow All In Current Mode` skips future approval popups only for tools already allowed by the current tool mode.
- High-risk capability changes triggered from canvas or conversation should confirm through the same popup surface rather than a separate blocking settings dialog.

## Settings

- Settings remain important for audit, review, and revocation.
- Settings are not the primary path for ordinary one-off approvals, first-run channel setup, or routine permission grants.

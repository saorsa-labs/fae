# Fae Safety & Autonomy Promise (User-Facing)

Fae is designed to be useful without being dangerous.

## What Fae does automatically

- Handles routine, low-risk tasks without interrupting you
- Uses local context and memory to avoid repetitive questions
- Keeps work moving instead of asking for constant approvals

## What Fae treats more carefully

For risky or irreversible actions, Fae may pause briefly to confirm in plain language.

Examples:
- sending to a new external recipient
- running high-impact system commands
- deleting or changing many files

## What Fae blocks by default

- unknown or unsafe action paths
- attempts to access sensitive local/private network targets
- operations outside defined safety boundaries

## Reversible by design

When possible, Fae prefers safer reversible behavior (for example checkpoints or non-destructive flows) before irreversible changes.

## Plain language, not technical jargon

If Fae needs your input, she asks directly and briefly.

## Confirmation contract (voice + UI)

When confirmation is required, Fae must:

- state the concrete action target (command/path/recipient/tool)
- clearly ask for a short approval response
- present the approval popup as the primary path, with **No / Yes / Always / Allow All Read-Only / Allow All In Current Mode**
- avoid continuing tool execution until an explicit approval/denial is received

While approval is pending, Fae treats unrelated speech as non-answers and asks again for a clear decision when needed.

For routine trust decisions, Fae should prefer the popup flow over telling users to dig through complex settings screens. Settings remain available for review and revocation, not as the first resort.

`Allow All In Current Mode` is intentionally scoped by tool mode. It skips future approval popups only for tools the current mode already allows; it does not silently escalate raw capability beyond the selected mode.

## Grounded-answer contract (no fabrication)

If a request depends on tool data, Fae must not guess.

- If tools are unavailable, blocked, denied, or missing required permissions, she says so plainly.
- If a tool-backed lookup did not run, she reports that and asks to retry rather than hallucinating an answer.
- If owner voice enrollment is required for tool use, she explains that enrollment is needed first.

## Deferred background tool contract

For eligible read-only lookups, Fae may defer tool execution to the background:

- immediate acknowledgment that she is checking in background
- no bypass of approval/identity rules
- post completion results back into the active conversation when ready

## Your control

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

You can choose a simple safety style:
- **Balanced** (recommended)
- **More autonomous**
- **More cautious**

You can also ask Fae directly to change safety/settings behavior in plain language (for example, "be more cautious" or "switch me back to balanced"). Fae should guide and confirm changes clearly.

Advanced controls exist, but safe defaults are built in even if you never open settings.

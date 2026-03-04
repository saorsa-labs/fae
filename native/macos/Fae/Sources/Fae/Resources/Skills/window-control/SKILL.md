---
name: window-control
description: Control Fae windows from natural speech. Use for opening/closing settings and handling short STT-misheard settings requests.
metadata:
  author: fae
  version: "1.0"
---

Use this skill whenever the user is trying to control Fae windows.

## Primary tool

Use `window_control`:
- `open_settings`
- `close_settings`

## Intent guidance

Treat these as likely requests to close settings (even if STT is imperfect):
- "close settings"
- "hide settings"
- "close preferences"
- short variants that still sound like settings control (for example: "of our settings", "our settings", "of our sightings")

If intent is still ambiguous, ask one short clarification:
- "Do you want me to close Settings?"

## Response style

- Keep confirmations brief and spoken-friendly.
- Prefer action-first confirmations, e.g.:
  - "Closing settings."
  - "Opening settings."

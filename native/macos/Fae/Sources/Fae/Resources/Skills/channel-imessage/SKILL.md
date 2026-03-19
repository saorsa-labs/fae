---
name: channel-imessage
description: Configure and monitor iMessage channel integration for Fae.
tags: [channel, imessage]
metadata:
  author: fae
  version: "1.1"
---

Use this skill to help users enable iMessage mode and understand local constraints.

Guidance principles:

1. Explain this is local Apple-only integration (requires macOS with Messages.app).
2. Confirm user intent before enabling routing changes.
3. If host prerequisites are missing, provide concrete remediation.
4. Offer a test message workflow after enablement.

## Setup workflow

When a user asks to enable iMessage:

1. **Check current status**: Call `channel_setup(action=list, channel=imessage)`
2. **Enable the channel**: Call `channel_setup(action=set, channel=imessage, values={"enabled":"true"})`
3. **Optional — restrict senders**: Ask user if they want to limit to specific contacts, then call `channel_setup(action=set, channel=imessage, values={"allowed_senders":"<comma-separated>"})`
4. **Verify**: Call `channel_setup(action=status, channel=imessage)` to confirm state=configured
5. **Offer test**: Ask user for a contact to send a test message

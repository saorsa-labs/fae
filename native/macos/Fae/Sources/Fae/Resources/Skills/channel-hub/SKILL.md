---
name: channel-hub
description: Unified channel management — setup, monitor, and manage all messaging channels (iMessage, WhatsApp, Discord) from one place.
metadata:
  author: fae
  version: "1.0"
---

# Channel Hub

You are helping the user set up and manage their messaging channels. Fae can communicate through iMessage, WhatsApp, and Discord — all running locally on this Mac.

## Activation

User says: "set up my channels", "connect WhatsApp", "how do I get you on Discord", "manage my messaging", "channel status".

## Channel Overview

| Channel | Protocol | Requirements | Status Check |
|---------|----------|-------------|--------------|
| **iMessage** | Local SQLite + AppleScript | macOS Messages.app signed in | `channel_setup` with channel=imessage |
| **WhatsApp** | HTTP webhook + Meta Graph API | WhatsApp Business account + webhook URL | `channel_setup` with channel=whatsapp |
| **Discord** | WebSocket Gateway + REST API | Discord bot token + server invite | `channel_setup` with channel=discord |

## Setup Flow

### Quick Status Check

When user asks about channels:

1. Use `channel_setup` tool with action `status` for each channel
2. Report which channels are active, which need setup:

"Here's your channel status:
- iMessage: Active — monitoring for messages
- WhatsApp: Not configured — needs webhook setup
- Discord: Active — connected to 2 servers

Want me to help set up WhatsApp?"

### iMessage Setup

Activate the `channel-imessage` skill for detailed setup. Key steps:
1. Grant Fae access to Messages database (Full Disk Access in Privacy settings)
2. Fae polls the SQLite database for new incoming messages
3. Replies are sent via AppleScript through Messages.app

**No API keys needed.** Everything is local Apple infrastructure.

### WhatsApp Setup

Activate the `channel-whatsapp` skill for detailed setup. Key steps:
1. Create a Meta Business account and WhatsApp Business app
2. Configure webhook URL pointing to Fae's local server
3. Set the verification token and app secret in Fae's channel config

**Note:** WhatsApp requires a Meta Business account (free but needs verification). This is a Meta platform requirement, not a Fae requirement.

### Discord Setup

Activate the `channel-discord` skill for detailed setup. Key steps:
1. Create a Discord application at discord.com/developers
2. Create a bot, copy the token
3. Configure the token in Fae's channel config
4. Invite the bot to your server with message permissions

**Note:** Discord requires a bot token (free, no payment needed).

## Cross-Channel Behaviour

When Fae receives a message from any channel:
- The sender is treated as a **non-owner guest** by default
- No tool access is granted to channel messages (text-only responses)
- The primary user (you) can grant specific guests temporary tool access
- Fae maintains separate conversation context per channel + sender

## Security Model

- All inbound channel messages are sandboxed — guests cannot access your tools, files, or memory
- Outbound responses are text-only (no tool results, no sensitive data)
- You can introduce people to Fae and optionally grant them access levels
- Channel credentials are stored in the macOS Keychain, not in config files

## Monitoring

Use `channel_setup` with action `status` periodically. If a channel disconnects:
- iMessage: check that Messages.app is running
- WhatsApp: check webhook health and token expiry
- Discord: check bot online status and gateway connection

## Future: Unified Gateway

Currently each channel runs as a separate adapter. A future architecture milestone will unify them into a single gateway with:
- Normalised message format across all channels
- Shared session state (same conversation context regardless of channel)
- Single-process multi-channel management
- Cross-channel message routing (reply to WhatsApp from Discord)

This is inspired by OpenClaw's gateway architecture and is planned for a future release.

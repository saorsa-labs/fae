# Channel Setup Guide

This guide covers setup and configuration for external communication channels (Discord and WhatsApp).

## Table of Contents

- [Discord Setup](#discord-setup)
- [WhatsApp Setup](#whatsapp-setup)
- [Rate Limiting](#rate-limiting)
- [Troubleshooting](#troubleshooting)

## Discord Setup

### Prerequisites

- A Discord account
- Server (guild) administrator permissions

### Step-by-Step Instructions

1. **Create a Discord Application**
   - Go to the [Discord Developer Portal](https://discord.com/developers/applications)
   - Click "New Application"
   - Give your application a name (e.g., "Fae Bot")
   - Click "Create"

2. **Create a Bot**
   - In your application, navigate to the "Bot" section
   - Click "Add Bot"
   - Confirm by clicking "Yes, do it!"
   - Under "Token", click "Reset Token" and copy the bot token
     - **IMPORTANT**: This token is a secret - never share it publicly
     - Store it securely using Fae's credential system

3. **Configure Bot Permissions**
   - Scroll down to "Privileged Gateway Intents"
   - Enable **Message Content Intent** (required to read message content)
   - Click "Save Changes"

4. **Generate OAuth2 URL**
   - Navigate to the "OAuth2" section
   - Under "OAuth2 URL Generator", select scopes:
     - `bot`
   - Under "Bot Permissions", select:
     - `Send Messages`
     - `Read Message History`
     - `View Channels`
   - Copy the generated URL at the bottom

5. **Invite Bot to Your Server**
   - Open the generated OAuth2 URL in your browser
   - Select the server you want to add the bot to
   - Click "Authorize"
   - Complete the CAPTCHA if prompted

6. **Get Guild and Channel IDs**
   - Enable Developer Mode in Discord:
     - Settings → Advanced → Developer Mode (toggle on)
   - Right-click your server name → Copy Server ID (this is your Guild ID)
   - Right-click a channel name → Copy Channel ID (repeat for each channel)
   - Right-click your username → Copy User ID (repeat for each authorized user)

7. **Configure Fae**
   - Open Fae's GUI
   - Navigate to: Fae → Channels...
   - Select the "Discord" tab
   - Fill in the form:
     - **Bot Token**: Paste your bot token
     - **Guild ID**: Optional, filters messages to one server
     - **Allowed User IDs**: Add authorized user IDs (one per line)
     - **Allowed Channel IDs**: Optional, restricts to specific channels
   - Click "Test Connection" to verify
   - Click "Save"

## WhatsApp Setup

### Prerequisites

- A Meta (Facebook) Developer account
- A WhatsApp Business account
- A verified phone number

### Step-by-Step Instructions

1. **Create a Meta Developer App**
   - Go to [Meta for Developers](https://developers.facebook.com/)
   - Click "My Apps" → "Create App"
   - Select "Business" as the app type
   - Fill in app details and create the app

2. **Add WhatsApp Product**
   - In your app dashboard, click "Add Product"
   - Find "WhatsApp" and click "Set Up"

3. **Get Started with WhatsApp**
   - Navigate to WhatsApp → Getting Started
   - Select or create a Business Portfolio
   - Add a phone number or use the test number provided

4. **Get Access Token**
   - In the "Getting Started" section, you'll see a temporary access token
   - **For production**, generate a permanent token:
     - Go to Settings → System Users
     - Create a new system user
     - Assign WhatsApp permissions
     - Generate a token with `whatsapp_business_messaging` permission
   - **IMPORTANT**: Store the token securely using Fae's credential system

5. **Copy Phone Number ID**
   - In WhatsApp → Getting Started
   - Find "Phone Number ID" and copy it

6. **Configure Webhook**
   - In WhatsApp → Configuration
   - Click "Edit" under "Webhook"
   - Set the callback URL to your public endpoint (e.g., `https://your-domain.com/whatsapp`)
   - Set a verify token (this can be any random string you create)
     - **Save this token** - you'll need it for Fae configuration
   - Subscribe to webhook fields:
     - `messages`
   - Click "Verify and Save"

7. **Add Authorized Numbers**
   - In WhatsApp → API Setup
   - Under "To", add phone numbers that can message your bot
   - Use E.164 format (e.g., `+14155551234`)

8. **Configure Fae**
   - Open Fae's GUI
   - Navigate to: Fae → Channels...
   - Select the "WhatsApp" tab
   - Fill in the form:
     - **Access Token**: Paste your permanent access token
     - **Phone Number ID**: Paste the Phone Number ID from Meta
     - **Verify Token**: The verify token you created for the webhook
     - **Allowed Numbers**: Add authorized phone numbers (E.164 format)
   - Click "Test Connection" to verify
   - Click "Save"

## Rate Limiting

Fae implements per-channel rate limiting to stay within platform limits and prevent abuse.

### Default Limits

- **Discord**: 20 messages per minute
- **WhatsApp**: 10 messages per minute

### Customizing Rate Limits

Edit your `config.json`:

```json
{
  "channels": {
    "enabled": true,
    "rate_limits": {
      "discord": 20,
      "whatsapp": 10
    }
  }
}
```

### Rate Limit Behavior

- When the limit is reached, messages are blocked until the window clears
- A warning event is logged with retry time
- The UI shows remaining messages in the current window
- Rate limits are per-channel (Discord and WhatsApp are independent)

## Troubleshooting

### Discord

**Bot doesn't respond to messages**
- Verify "Message Content Intent" is enabled in the Discord Developer Portal
- Check that the user ID sending messages is in the allowed list
- Ensure the bot has "Send Messages" permission in the channel
- Check Fae logs for rate limiting or error messages

**Bot offline**
- Verify the bot token is correct and not expired
- Check that auto-start is enabled: Channels → Overview → Auto-start
- Restart Fae or manually start the channels runtime

**Permission errors**
- Ensure the bot has been invited to the server with the correct scopes
- Verify channel permissions allow the bot to read and send messages
- Re-invite the bot with updated permissions if needed

### WhatsApp

**Webhook verification fails**
- Ensure the verify token in Meta matches the one in Fae's configuration
- Check that the webhook URL is publicly accessible
- Verify your firewall/security group allows incoming traffic on the webhook port
- Use Meta's "Test" button to trigger a verification request

**Messages not received**
- Verify the phone number is in the allowed numbers list (E.164 format)
- Check that the access token has not expired
- Ensure webhook subscriptions include "messages"
- Review Fae logs for validation errors

**Rate limit errors**
- WhatsApp has platform-level rate limits separate from Fae's
- For testing, use the test phone number provided by Meta
- For production, apply for higher limits through Meta

### General

**Channels not auto-starting**
- Check that `channels.enabled` is `true` in `config.json`
- Check that `channels.auto_start` is `true`
- Review validation warnings in the Fae logs
- Ensure at least one adapter (Discord or WhatsApp) is fully configured

**Health check failures**
- Verify network connectivity to Discord and Meta APIs
- Check for firewall rules blocking outbound connections
- Ensure credentials are correctly stored and accessible
- Use the "Refresh Health" button in the Channels panel

**Message history not showing**
- History is only retained for the last 500 messages (configurable)
- History is in-memory and cleared on restart
- Check that messages are actually being sent/received (not blocked by rate limits)

## Security Best Practices

1. **Never commit tokens or credentials to version control**
   - Use Fae's credential system (Keychain on macOS, encrypted fallback elsewhere)
   - Rotate tokens periodically

2. **Restrict access using allowlists**
   - Only add trusted user IDs (Discord) and phone numbers (WhatsApp)
   - Review and update allowlists regularly

3. **Use bearer authentication for webhooks**
   - Set a strong bearer token in `config.json` under `channels.gateway.bearer_token`
   - This prevents unauthorized webhook calls

4. **Monitor logs for suspicious activity**
   - Watch for repeated denied messages
   - Check for unusual rate limit triggers
   - Review health check failures

5. **Keep Fae updated**
   - Security fixes are released regularly
   - Use "Check for Updates" in the Fae menu

## Support

For additional help:
- Open an issue on GitHub
- Contact: david@saorsalabs.com
- Documentation: https://github.com/saorsa-labs/fae

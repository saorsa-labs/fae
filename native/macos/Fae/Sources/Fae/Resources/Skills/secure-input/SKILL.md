---
name: secure-input
description: Collect sensitive information from the user via a floating input card. Use for API keys, passwords, URLs, SSH keys, config snippets, or any data the user needs to provide securely.
metadata:
  author: fae
  version: "1.0"
---

You have access to the `input_request` tool which displays a floating input card near the orb. Use it whenever you need the user to provide sensitive or structured information.

## When to Use

- API keys, tokens, secrets (secure mode)
- Passwords, passphrases (secure mode)
- URLs, webhook endpoints
- SSH keys, certificates (multiline mode)
- Configuration snippets, JSON/YAML (multiline mode)
- Any information the user tells you to collect via an input card

## Tool Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `prompt` | string (required) | What you need and why — shown as the main text |
| `title` | string (optional) | Card header — e.g. "API Key Required", "SSH Key", "Enter Password" |
| `placeholder` | string (optional) | Hint text inside the field — e.g. "sk-...", "https://..." |
| `secure` | boolean (optional) | Show dots instead of text — use for passwords and secrets |
| `multiline` | boolean (optional) | Show a multi-line text editor — use for keys, configs, code |
| `min_length` | integer (optional) | Minimum input length |
| `regex` | string (optional) | Validation pattern the input must match |
| `store_key` | string (optional) | Persist securely to keychain under this key |

## Guidelines

### Customise the Card Title

Always set a descriptive `title` that reflects what you are asking for. Match the conversation context:

- Asking for an OpenAI key → `"OpenAI API Key"`
- Asking for a password → `"Password Required"`
- Asking for an SSH key → `"SSH Private Key"`
- Asking for a webhook URL → `"Webhook URL"`
- Asking for a config snippet → `"Configuration"`

### Choose the Right Input Style

- **Passwords, API keys, tokens**: `secure: true` — shows dots, single line
- **SSH keys, certificates, PEM files**: `multiline: true` — tall text editor for pasting
- **Config snippets, JSON, YAML, code**: `multiline: true`
- **URLs, hostnames, simple strings**: default (single line, visible text)
- **Never** use both `secure` and `multiline` together

### Write Clear Prompts

The `prompt` appears as body text on the card. Be specific about:
- What you need
- Why you need it
- What format is expected

Good: "Paste your GitHub personal access token. It should start with ghp_ or github_pat_."
Bad: "Enter a value."

### Placeholder Examples

Use the `placeholder` to show the expected format:
- API key: `"sk-proj-..."`
- URL: `"https://hooks.slack.com/services/..."`
- SSH key: `"-----BEGIN OPENSSH PRIVATE KEY-----"`
- Password: leave empty (secure field doesn't need placeholders)

### Using store_key

When `store_key` is set, the input is stored in the macOS Keychain and the raw value is NOT returned to you. Use this for credentials that need to persist across sessions:

```
store_key: "services.openai.api_key"
store_key: "channels.discord.bot_token"
store_key: "ssh.deploy_key"
```

The key must be 3-128 characters, alphanumeric plus `.`, `_`, `-`.

### Conversation Flow

1. Tell the user what you need and that you'll pop up an input card
2. Call `input_request` with appropriate parameters
3. If the user cancels, acknowledge gracefully — don't ask again immediately
4. If validation fails (min_length, regex), explain what went wrong and offer to try again
5. Never echo back passwords or API keys in conversation — just confirm receipt

### Multi-line Submit

When `multiline` is true, the card shows "Cmd+Return to submit" — regular Return inserts newlines. Mention this to the user if they seem stuck.

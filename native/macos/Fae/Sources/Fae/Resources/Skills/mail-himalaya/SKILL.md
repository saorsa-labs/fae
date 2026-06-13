---
name: mail-himalaya
description: Read, search, and send IMAP/SMTP email with himalaya when the user asks about mail or wants a portable email action.
tags: [mail, email, imap, smtp, himalaya]
metadata:
  author: fae
  version: "1.0.0"
---

# Mail Himalaya

Mail Himalaya lets Fae use the cross-platform `himalaya` CLI for IMAP/SMTP email. It is additive to the macOS Apple tools path; use it when a user asks for portable mail access, inbox triage, message search, or sending mail through a configured account.

## When to Use

- The user asks to list recent inbox mail, search mail, or summarize subjects.
- The user asks Fae to draft or send a message through IMAP/SMTP.
- The task should work outside macOS or without Apple Mail/EventKit APIs.
- Prefer the built-in `mail` tool for privileged macOS-local mail workflows if that is explicitly requested.

## Prerequisites

- `himalaya` must be installed by Fae's tool augmentation flow (`brew install himalaya` or equivalent). This skill never installs tools itself.
- The user must configure `himalaya` with their account (`himalaya account configure <name>`), or provide a profile already present in Himalaya's config.
- Passwords and tokens must stay outside prompts and files. If the runtime needs secrets, store them in Keychain with `input_request`/`CredentialManager` and call `run_skill` with `secret_bindings` so values arrive only as environment variables.
- For iCloud/Gmail, use provider app-specific passwords or OAuth material supported by Himalaya; never paste credentials into SKILL.md or scripts.

## How to Run

Use the `run_skill` tool with skill `mail-himalaya` and script `mail_himalaya`.

```json
{"name":"mail-himalaya","script":"mail_himalaya","params":{"action":"status"}}
```

If a secret is needed at execution time, bind it from Keychain:

```json
{
  "name": "mail-himalaya",
  "script": "mail_himalaya",
  "params": {"action":"list_recent","account":"personal","folder":"INBOX","count":5},
  "secret_bindings": {"HIMALAYA_PASSWORD":"productivity.mail.personal.password"}
}
```

## Quick Reference

| Action | Required params | Purpose |
|---|---|---|
| `status` | none | Check whether `himalaya` is installed and report configuration guidance |
| `list_recent` | optional `account`, `folder`, `count` | List recent envelopes, newest first |
| `search` | `query`; optional `account`, `folder`, `count` | Search envelopes with Himalaya's query DSL |
| `send` | `to`, `subject`, `body`; optional `from`, `cc`, `account`, `save`, `dry_run` | Send an RFC 5322 message through Himalaya |

## Procedure

1. Confirm setup with `status`; if missing, explain that Fae can install `himalaya` through normal tool augmentation, not from this skill.
2. For read-only requests, call `list_recent` or `search` with `count` capped to the minimum useful number.
3. For sending, prepare the exact recipient, subject, and body. Ask for confirmation before setting `dry_run` to `false`.
4. Return a concise summary. Do not include raw headers unless the user asks.
5. If Himalaya returns an authentication or provider error, explain the provider-specific next step (app password, OAuth refresh, account configure) without asking the user to reveal the secret in chat.

## Pitfalls

- Himalaya message IDs are mailbox-scoped. Do not treat an ID from one folder as stable in another folder.
- `message read` should not mark mail as seen, but flag operations do mutate state. Ask before mutating flags.
- Some providers require app-specific passwords or OAuth setup; normal account passwords may fail.
- Bcc is intentionally unsupported in v1 because raw `.eml` submission can leak a `Bcc:` header if the provider does not strip it.
- Never echo environment variables, config files, or secrets from stderr back to the user.

## Verification

- `status` returns `installed: true` and a version string.
- `list_recent` returns five real inbox subjects for the configured account.
- `send` with `dry_run: true` returns the generated envelope summary without sending.
- A confirmed `send` to the user's own address appears in the inbox/sent folder.

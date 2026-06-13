---
name: contacts-carddav
description: Search CardDAV contacts when the user asks for portable address-book lookup across providers.
tags: [contacts, carddav, address-book, productivity]
metadata:
  author: fae
  version: "1.0.0"
---

# Contacts CardDAV

Contacts CardDAV lets Fae search a cross-platform address book, including iCloud and Google CardDAV-compatible endpoints. It is additive to the privileged macOS Contacts path in `AppleTools.swift`.

## When to Use

- The user asks for contact lookup that should work outside macOS.
- The user wants to search iCloud/Google contacts via CardDAV credentials.
- The user asks for a known contact's email or phone number and has configured a CardDAV address book.
- Prefer the built-in `contacts` tool for macOS-local Contacts access unless portability is required.

## Prerequisites

- Credentials must be stored in Keychain and injected with `run_skill.secret_bindings`; never store passwords in SKILL.md, scripts, or config files.
- Required environment variables: `CARDDAV_URL`, `CARDDAV_USERNAME`, and `CARDDAV_PASSWORD`.
- `CARDDAV_URL` should point at an address-book collection URL when possible. Provider discovery can be added later.
- iCloud users need an app-specific password. Google users need an app/OAuth-compatible credential and CardDAV endpoint.
- The script uses `uv run --script` with inline Python dependency `vobject` for vCard parsing.

## How to Run

Use `run_skill` with skill `contacts-carddav` and script `contacts_carddav`.

```json
{
  "name":"contacts-carddav",
  "script":"contacts_carddav",
  "params":{"action":"search","query":"Alice","limit":5},
  "secret_bindings":{
    "CARDDAV_URL":"productivity.contacts.url",
    "CARDDAV_USERNAME":"productivity.contacts.username",
    "CARDDAV_PASSWORD":"productivity.contacts.password"
  }
}
```

## Quick Reference

| Action | Required params | Purpose |
|---|---|---|
| `status` | none | Check environment readiness without revealing secrets |
| `search` | `query`; optional `limit` | Search names, emails, and phone numbers |
| `raw_report` | `query`; optional `limit` | Return compact diagnostics for provider troubleshooting |

## Procedure

1. Run `status` if setup is uncertain. Ask only for the missing URL, username, or stored secret.
2. Call `search` with the person's name, email fragment, or phone fragment.
3. Return only the contact fields needed for the task. Avoid dumping full vCards.
4. If the provider returns authorization or XML errors, explain the next setup step and do not ask the user to paste the password in chat.

## Pitfalls

- CardDAV collection URLs are provider-specific. A principal URL may not accept address-book queries.
- Contact names can differ from how the user says them; search by email or phone fragment if name search fails.
- Some servers limit broad searches. Keep limits small and ask for a narrower query if needed.
- Never echo Authorization headers or raw vCards containing more data than the user requested.

## Verification

- `status` reports all required environment variables present.
- Searching a known contact returns the expected name plus at least one email or phone field.
- AppleTools Contacts tests still pass; this skill does not replace local Contacts integration.

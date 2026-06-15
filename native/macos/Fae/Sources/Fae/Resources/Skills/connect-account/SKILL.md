---
name: connect-account
description: Connect the user's mail, calendar, and contacts on any OS from just their email plus one app-specific password — voice-guided, secure, verified live.
tags: [onboarding, mail, calendar, contacts, setup, accounts]
metadata:
  author: fae
  version: "2.0.0"
---

# Connect Account

Get the user's mail / calendar / contacts working with the least effort possible:
**two inputs — their email and one app-specific password.** Fae detects the
provider, opens the right page, voice-guides the clicks, captures the one paste
securely, derives and stores everything else, and verifies the connection live.

Use this when the user says things like "connect my email", "set up my calendar",
"hook up my iCloud", or during first-launch setup.

## One portable engine

The `connect_account` script is the single cross-platform engine — same
derivation, same stored keys, same himalaya config on macOS and Linux. Only the
**secure capture** of the one password differs per platform:

- **macOS:** capture with the `input_request` tool (a secure field) — it writes
  straight to the Keychain, which the script reads back via the system keyring.
- **Linux / CLI:** the script prompts on the terminal with no echo (`getpass`),
  or a runner injects `FAE_APP_PASSWORD`.

Never hand-build himalaya/CalDAV config or store passwords yourself — always go
through the script plus a secure capture.

## Procedure

1. **Get the email** if you don't already know it. Email + one password is all
   the user should ever provide.

2. **Start.** Run the script with `action: "start"` and `open_page: true`:

   ```json
   {"name":"connect-account","script":"connect_account","params":{"action":"start","email":"jane@icloud.com","open_page":true}}
   ```

   It opens the provider's app-password page and returns the spoken guidance, the
   setup URL, and the env var the password must arrive in (`FAE_APP_PASSWORD`).

3. **Speak the guidance** — the 2–3 clicks to mint an app-specific password. Tell
   the user the page is open. Keep it warm and brief.

4. **Capture the password securely.**
   - On macOS, call `input_request` with `secure: true`, `return_to_model: false`,
     `store_key: "productivity.mail.personal.password"`, and a short title/prompt.
     The password goes straight to the keychain — you never see it and it never
     enters our conversation.
   - On Linux/CLI without a runner, the `connect` step prompts on the terminal.

5. **Connect.** Run the script with `action: "connect"` and the same `email`,
   binding the captured secret into the environment:

   ```json
   {
     "name":"connect-account","script":"connect_account",
     "params":{"action":"connect","email":"jane@icloud.com"},
     "secret_bindings":{"FAE_APP_PASSWORD":"productivity.mail.personal.password"}
   }
   ```

   It derives the full config, stores every key in the system keyring, writes the
   himalaya config, **installs the `himalaya` mail CLI itself if it's missing**
   (pinned, checksum-verified download into `~/.local/bin` — the user never opens
   a terminal), and verifies mail live. Report its summary warmly ("You're
   connected — 5 messages in your inbox."). If himalaya can't be installed
   (offline), the account is still stored and mail verifies once it's available.

6. **Calendar & contacts.**
   - On macOS, prefer the built-in `calendar` (e.g. `list_week`) and `contacts`
     (e.g. `search`) tools — they use the Mac's local access and need **no
     password**; macOS prompts for permission once.
   - Off macOS, the stored CalDAV/CardDAV credentials drive the `calendar-caldav`
     and `contacts-carddav` skills; verify with those.

7. **iCloud custom domain.** If `start` sets `may_be_icloud_custom_domain` and the
   user confirms the address is on iCloud, re-run `start`/`connect` with
   `provider: "icloud"` and `primary_apple_id` set to their `@icloud.com` Apple ID
   (mail still sends from the custom address; iCloud authenticates with the Apple
   ID).

## Diagnostics

- `action: "status"` — himalaya install, keyring backend, config presence.
- `action: "ensure_tools"` — install the `himalaya` mail CLI if missing (Fae does
  this herself; `connect` calls it automatically).
- `action: "selftest"` — validate derivation with no account, secret, or network.

## On failure

If `connect` reports `rolled_back: true`, the connection didn't verify and Fae has
already undone the half-finished setup — nothing is left dangling. Tell the user
the specific fix (usually a wrong app-specific password, or 2FA needs a fresh one)
and offer to try again. Re-running is safe and idempotent.

## Guardrails

- Two inputs only: email + one password. Everything else is derived — never ask
  for server names, ports, or URLs.
- The password is captured **once**, via `input_request` (`secure: true`,
  `return_to_model: false`) on macOS, or a no-echo terminal prompt / injected
  `FAE_APP_PASSWORD` elsewhere. Never echo it, never store it yourself, never put
  it in a script argument or the request JSON.
- Don't claim a capability is connected unless it verified (mail), or its own
  tool/skill returned data (calendar/contacts).

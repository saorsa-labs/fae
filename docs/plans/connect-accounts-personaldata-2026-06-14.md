# Connect Account + PersonalDataAdapter — cross-OS account onboarding

**Date:** 2026-06-14
**Owner decisions:** macOS + Linux first; iCloud + generic IMAP/CalDAV/CardDAV
first (no OAuth-client dependency yet).
**Why:** P2's productivity skills (mail/calendar/contacts) work, but the setup
is a developer dance — generate an app password, hand-store 7 Keychain entries,
write a himalaya config. A normal user will never do that. Fae must do it *for*
the user, slickly, on **every** OS — EventKit is only there on macOS.

This is the **PersonalDataAdapter** — the "hands" seam of the four-seam
cross-platform architecture (`docs/architecture/full-cross-platform-ml-pipeline-2026-06-11.md`),
alongside ProviderAdapter / VoiceAdapter / PerceptionAdapter / TrainingAdapter.

## The one unavoidable constraint

iCloud IMAP/CalDAV/CardDAV require a **human-minted app-specific password**
(appleid.apple.com — no API mints one; it's the security boundary). So the flow
cannot be zero-touch for iCloud. The goal: reduce the user's job to **two
inputs — their email + one app-specific password** — and have Fae voice-guide,
open the page, derive/store everything else, and verify live.

## Two axes, resolved at runtime

### Axis 1 — capability backend (per OS)
| Capability | macOS | Linux (+ Windows later) |
|---|---|---|
| Calendar | EventKit (`AppleTools`, zero-setup, TCC) | CalDAV (`calendar-caldav`) |
| Contacts | Contacts.framework (zero-setup, TCC) | CardDAV (`contacts-carddav`) |
| Mail | IMAP (`mail-himalaya`) | IMAP (`mail-himalaya`) |

Mail is IMAP **everywhere** (no native mail framework we ride) — the one
capability that always needs a credential, even on macOS. Calendar/contacts are
zero-setup on macOS, credential-based off-Apple. The seam picks the backend by
`#if os(...)` + runtime capability probe; nothing above the seam knows which.

### Axis 2 — credential acquisition (per provider, OS-independent)
- **iCloud** (`@icloud.com`/`@me.com`/`@mac.com`) → app-specific password flow.
- **Generic** (any other IMAP/CalDAV host) → app password + host autodiscovery
  (try common `imap.`/`caldav.`/SRV records; fall back to asking).
- *(Gmail/Outlook OAuth — deferred; design leaves a `CredentialMethod.oauth`
  case so it slots in without reshaping the flow.)*

## The slick "Connect Account" flow

A new onboarding skill/flow `connect-account` that fronts the three productivity
skills. Steps:

1. **Trigger** — "connect my email/calendar", first-launch onboarding step, or a
   Settings affordance. Capability optional ("connect everything" default).
2. **Provider + OS resolve** — detect provider from the email domain; pick the
   backend per Axis 1. On macOS, calendar/contacts route to EventKit and need
   **no credential** — only mail proceeds to the credential step. On Linux, all
   three proceed.
3. **Guide (voice-first)** — for iCloud: open `https://account.apple.com` to the
   App-Specific Passwords section (NSWorkspace.open / xdg-open) and *speak* the
   3 clicks. Show a card with the URL button + a **secure input field**.
4. **Capture** — one secure paste (dots, never spoken, never in chat) via the
   existing `input_request` + `store_key` path.
5. **Derive + store** — from `{email, appPassword}` compute the full config and
   write **all** Keychain entries the skills read (`productivity.mail.personal.password`,
   `productivity.calendar.{url,username,password}`,
   `productivity.contacts.{url,username,password}`) + the himalaya account config
   (iCloud: `imap.mail.me.com:993` TLS, `smtp.mail.me.com:587` STARTTLS, login =
   the primary `@icloud.com` address — **custom-domain users authenticate with
   the primary Apple ID, not the alias**; CalDAV `caldav.icloud.com`, CardDAV
   `contacts.icloud.com`). The user types **none** of this.
6. **Verify live** — immediately exercise each connected capability and report a
   concrete result: "Connected — 2 emails today, 3 events this week, 412
   contacts." A failure names the fix (wrong password / 2FA / host) without ever
   echoing the secret.
7. **Idempotent re-run** — re-running updates in place; a failed verify rolls
   back the just-written entries so a half-connected account never lingers.

## What exists vs what's new
- **Exists:** the 3 productivity skills + their Keychain-key contract;
  `AppleTools` EventKit/Contacts; `CredentialManager` (service `com.saorsalabs.fae`);
  `input_request`/`store_key` secure capture; provider/inference plumbing.
- **New:** the `connect-account` orchestration (detect → guide → capture →
  derive → store → verify); provider+OS backend resolution (the PersonalDataAdapter
  seam); URL-open affordance + secure card UI; iCloud config derivation; live
  verification per capability; rollback.

## Acceptance criteria (evidence bar)
- **macOS**: "connect my accounts" → calendar/contacts verify via EventKit with
  **no password**; mail prompts once, stores, and lists 5 inbox subjects. Real
  transcript/log, no fabricated output.
- **Linux**: same intent → all three run the credential flow; live verify lists
  inbox subjects, next-7-day events (iCloud CalDAV), and a contact lookup. Real
  transcript.
- User provides **exactly two inputs** (email + one app password) for the full
  iCloud suite; everything else derived. Demonstrated.
- Secrets never appear in chat, logs, or the request JSON (grep the run log).
- Failed verify rolls back; re-run is idempotent (test).
- `just check` (root, skip VocabularyHarvestTests) + `cd crates && just check` +
  `just check-ui-shell` green. Unit tests for provider/OS resolution + config
  derivation (pure, no live accounts needed).

## Phasing
1. **PersonalDataAdapter seam** + provider/OS resolution + config derivation
   (pure, fully unit-testable — no accounts).
2. **connect-account flow**: detect → guide → secure capture → store → verify,
   wired to the 3 skills + EventKit on macOS.
3. **Live proof** macOS + Linux (closes Task #8 as a real-user flow, not the dev
   dance).
4. *(Later: Windows secret store; Gmail/Outlook OAuth; Android ContentResolver
   backend — all accommodated by the seam, none in this build.)*

Supersedes the manual recipe in `project_p2_icloud_keychain_setup` (memory) as
the user-facing path. Related: `docs/architecture/skills-first-cross-platform-2026-06-13.md`.

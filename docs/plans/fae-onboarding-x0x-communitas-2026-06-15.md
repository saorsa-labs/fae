# Fae In-App Onboarding — Accounts + x0x Identity + Communitas Front-End

**Date:** 2026-06-15
**Status:** Design accepted (owner, 2026-06-15 session). Build staged.
**Supersedes the CLI test path** for account setup: everything below happens
**in the Fae app, driven by Fae**, never in a terminal.

## The one non-negotiable

**All setup happens in-app, as users will see Fae do it.** No manual terminal
steps, no hand-edited config, no developer dance. Every action — connecting
email, installing dependencies, joining the x0x network, opening Communitas — is
something Fae performs through the running app: she speaks the guidance, opens
the page, captures the one secret securely, installs the tools herself, and
verifies live. If a step would require the user to open a terminal, it is not
done.

This is both the product bar and the test bar: a stage is "done" only when it
works through the app with the user providing the minimum human inputs (an email,
one app password, a yes/no consent) and nothing else.

## What we're building

Fae's onboarding grows from "voice + awareness setup" into a single arc that also
makes Fae a first-class citizen of the user's data and the x0x network:

1. **Connect the user's mailbox** — their real aggregator inbox (e.g. Gmail), in
   one paste, verified live.
2. **Join the x0x network** — detect/install `x0xd`, read the machine-agent
   identity, and (opt-in) create the human identity.
3. **Open Communitas as the front-end** — surface x0x messages / projects /
   spaces visually; Fae participates in the network on the user's behalf.

## Grounded architecture (verified 2026-06-15)

### x0x — the network + identity
- Ships a daemon `x0xd` + CLI `x0x` (`saorsa-labs/x0x`), Rust.
- **Local REST API** at `http://127.0.0.1:<port>`; the port + bearer token live in
  `~/Library/Application Support/x0x/{api.port,api-token}` (macOS) /
  `~/.local/share/x0x/…` (Linux). Health (`GET /health`) needs no auth.
- **Identity is one call:** `GET /agent` → `{ agent_id, machine_id, user_id }`.
  - `machine_id` + `agent_id` (the **machine-agent ID**) auto-generate on first
    `x0xd` start.
  - `user_id` (the **human ID**) is **opt-in and never auto-created** — a
    deliberate `x0x agent user-id`. This is a privacy boundary by design.
- Capabilities over the same REST/WS surface: pub/sub, direct messages, named
  groups/**spaces**, presence/discovery, contacts, files, CRDT task lists.
- **Signed releases** (v0.23.1): per-platform tarballs (`x0x-macos-arm64.tar.gz`,
  `x0x-linux-x64-gnu.tar.gz`, …) each with `.sha256` + GPG `.sig`, plus
  `SAORSA_PUBLIC_KEY.asc` and a signed `release-manifest.json`. x0x also ships its
  own `SKILL.md` — it is built to be agent-driven.

### Communitas — the visual front-end
- A **Dioxus desktop app** (`communitas/communitas-dioxus`) that **auto-discovers
  the same `x0xd`** and renders Spaces / Channels / Projects / Messages / Drives,
  all attributed to the shared `agent_id`.
- `communitas-x0x-client` is the typed Rust client for the x0xd REST/WS API and
  includes a `DaemonManager` (`is_installed()`, `ensure_running()`) that can
  install/start `x0xd`.
- Identity is shared: communitas and Fae both read identity from the one `x0xd`.

### How Fae drives it — portable, consistent with connect-account
Because x0x exposes **HTTP on localhost with a token**, Fae drives it the same
portable way she drives mail: a **Python executable skill over the x0x REST API**
(detect → read identity → publish/list/spaces). This matches the Python-first
portability decision (one engine, macOS + Linux) and the connect-account pattern.
The Rust daemon embedding `communitas-x0x-client` is a later optimization, not a
prerequisite.

## The in-app mechanism (how "no terminal" actually works)

Every stage is the same shape Fae already uses for mail:
- **Fae's onboarding skill** drives the conversation and calls tools.
- **Secrets** are captured with `input_request` (`secure: true`,
  `return_to_model: false`, `store_key`) — straight to the keychain, never chat.
- **Portable work** runs via `run_skill` against the connect-account / x0x Python
  skills (derive, store, install deps, call REST, verify).
- **Dependencies install themselves** — Fae downloads pinned, verified binaries
  into `~/.local/bin` (the himalaya pattern; x0xd adds GPG-signature verification).
- **The orb + voice** are the UX; the user only ever provides an email, one app
  password, and yes/no consents.

## Stages

### Stage 1 — Connect the mailbox (Gmail-first)
- Add a **Gmail provider case** to the connect-account skill: `imap.gmail.com:993`
  / `smtp.gmail.com:587`, the correct `[Gmail]/…` folder aliases (Sent Mail /
  Drafts / Trash — the "generic" aliases are wrong for Gmail and break save-to-Sent),
  and guidance pointing at the Google App-Passwords page. Provider detection adds
  `gmail.com`/`googlemail.com` → `gmail`.
- In-app: Fae opens the App-Passwords page, the user pastes once via the secure
  card, Fae stores + writes the himalaya config + installs himalaya if missing +
  verifies live ("Connected — N messages in your inbox").
- **Gate:** runs in the dev app end-to-end on the owner's real Gmail; secret never
  in chat/log; idempotent re-run.

### Stage 2 — Join the x0x network (identity)
- New portable **`x0x` executable skill** (uv/PEP 723, REST over localhost):
  - `status` — is `x0xd` installed / running? (binary present + data dir + `GET
    /health`).
  - `ensure` — install `x0xd` herself if missing: download the **pinned, signed**
    release tarball for this OS/arch, verify `.sha256` (and GPG `.sig` against
    `SAORSA_PUBLIC_KEY.asc`), extract to `~/.local/bin`, start it.
  - `identity` — `GET /agent` → return the **machine-agent ID** (`machine_id` +
    `agent_id`); report whether a human ID exists.
  - `create_human_id` — **opt-in only**, after explicit spoken consent: create the
    human `user_id` (`x0x agent user-id`). Never silent.
- In-app: during onboarding Fae says "I can connect you to the x0x network for
  secure peer-to-peer messaging and shared projects — want me to set that up?",
  installs x0xd, shows the machine-agent ID, and asks before creating the human ID.
- **Gate:** in the dev app, Fae detects-or-installs x0xd, reads + reports the real
  identity, and creates the human ID only on explicit consent. No terminal.

### Stage 3 — Communitas as the front-end
- Fae ensures `x0xd` is running, then **launches Communitas** (it auto-connects to
  the shared daemon) so the user *sees* the network — spaces, projects, messages.
- Fae participates via the x0x skill (publish to a space, list spaces/messages,
  presence), and Communitas renders it live (shared `agent_id`).
- In-app: "Here's your space in Communitas — I've posted a welcome note." The user
  watches it appear.
- **Gate:** from the app, Fae opens Communitas showing real x0x content and posts
  a message that appears in the UI. No terminal.

## Decisions resolved
- **Bridge:** portable Python skill over the x0x REST API (consistent, portable).
  Rust `communitas-x0x-client` embedding is a later optimization.
- **Human ID:** opt-in, explicit spoken consent, never auto-created (honors x0x's
  own boundary + Fae's privacy posture).
- **Dependency install:** Fae self-installs `himalaya` and `x0xd` from pinned,
  verified releases into `~/.local/bin` (x0xd adds signature verification).
- **Communitas:** launched as the front-end, not embedded; it co-operates with Fae
  through the shared `x0xd`.
- **Sequence:** mailbox (Gmail) → x0x identity → Communitas.

## Acceptance criteria (the in-app evidence bar)
- Every stage demonstrated **through the running Fae app**, with a real transcript
  / screen evidence — never a CLI substitute.
- The user provides only: their email, one app password (mail), and yes/no
  consents (x0x human ID). Everything else Fae derives, installs, and verifies.
- Secrets never appear in chat, logs, or request JSON (grep proof).
- x0xd and himalaya are installed **by Fae**, verified (checksum, + signature for
  x0xd), with no terminal use by the user.
- Idempotent re-runs; failed verifies roll back (mail) and never leave a
  half-connected state.

## Risks / open questions
- **x0xd lifecycle in-app:** who owns starting/stopping x0xd (the x0x skill vs the
  fae-daemon vs communitas's `DaemonManager`)? Avoid orphans (Fae already has a
  daemon-orphan-watch pattern to mirror).
- **GPG verification in a Python skill:** verifying `.sig` against
  `SAORSA_PUBLIC_KEY.asc` may need `gnupg`; `.sha256` is the floor, signature the
  stretch. Decide the minimum bar.
- **Launching Communitas from Fae:** build/run path (`dx serve` for dev vs a
  bundled binary for users) — needs a packaged Communitas for real users.
- **Headless Linux:** keyring (SecretService) + x0xd both assume a desktop session
  for the full UX; the daemon-secret-store caveat from connect-account still holds.
- **Gmail App Passwords require 2FA** on the Google account; if OAuth is later
  wanted, the connect-account seam already reserves a method slot.

## Links
- Connect-account (Stage 1 engine): `docs/plans/connect-accounts-personaldata-2026-06-14.md`,
  `Resources/Skills/connect-account/`.
- x0x: `saorsa-labs/x0x` (`src/api/mod.rs` endpoint registry; signed releases).
- Communitas: `communitas/communitas-x0x-client` (`X0xClient`, `DaemonManager`),
  `communitas/communitas-dioxus`.
- Strategy context: `docs/architecture/conductor-positioning-and-scope-2026-06-05.md`,
  memory `project_fae_x0x_integration`, `project_conductor_strategy`.

# Fae `collaborate` Skill — Design

**Date:** 2026-06-29
**Status:** Design — pending owner sign-off. Build staged.
**Owner decisions (this session):** name = `collaborate`; governance posture = **active now**
(relies on the owner's standing consent recorded in
`docs/security/x0x-metadata-threat-model.md`, accepted 2026-06-02).
**Author note:** A codex architecture critique was attempted but hung (3.5h, killed);
this design rests on a four-agent cross-repo deep dive of `communitas`, `x0x`, and Fae.
A tighter codex review of the finished design/scripts is a recommended follow-up.

---

## 1. Goal

Give Fae a skill that lets her user **fully collaborate the way the communitas app
does** — messages, groups/spaces, swarm, kanban, files, presence — and, crucially,
**connect not only to other Fae instances, but to other humans and to those humans'
agents.** The collaboration UI is surfaced in the user's **browser**; Fae can also
drive the same collaboration **by voice**.

## 2. The key realisation: don't rebuild communitas — reuse what already exists

communitas is **not** a thing to re-implement. It is one of *two* front-ends over a
shared local daemon:

```
              ┌─────────────────────────── the engine ──────────────────────────┐
              │  x0xd  (Rust daemon)                                              │
              │  ~133 REST endpoints + /ws + /ws/direct + SSE on 127.0.0.1:12700  │
              │  identity · contacts/trust · DMs · named groups/spaces · MLS      │
              │  kanban (CRDT task-lists) · files · presence/FOAF · pub/sub · KV  │
              └───────────────┬──────────────────────────────┬───────────────────┘
                              │                              │
                   ┌──────────┴─────────┐         ┌──────────┴───────────────────┐
                   │  x0x gui            │         │  communitas (Dioxus desktop) │
                   │  single HTML/JS,    │         │  communitas-x0x-client →      │
                   │  served at /gui,    │         │  communitas-core/ui-service   │
                   │  opens in browser   │         │  + extra semantics: entity    │
                   │  (`x0x gui`)        │         │  hierarchy, canvas, drive     │
                   └─────────────────────┘         └──────────────────────────────┘
```

- **`x0x gui`** (`x0x/src/gui/x0x-gui.html`, ~5,050 lines vanilla JS) is `include_str!`-compiled
  into `x0xd` and served at `http://127.0.0.1:<port>/gui?token=<api-token>`. It already
  implements identity/dashboard, contacts/trust, DMs, group/space chat, **kanban**, files,
  presence/FOAF, swarm (pub/sub), wiki/feed/KV, and low-level MLS groups. The x0x repo
  carries dozens of `proofs/gui-parity-*` runs — it was **built to match communitas
  feature-for-feature**.
- **communitas** (`communitas-dioxus`) is a separate Tauri/Dioxus desktop app over the
  same `x0xd` (via `communitas-x0x-client`). Its `communitas-core`/`communitas-ui-service`
  are headless and adapter-agnostic and add richer semantics (entity hierarchy
  Person/Group/Org/Project/Channel, invites, a 5,600-line canvas/whiteboard, a virtual drive).

**Therefore "replicate communitas, in the browser" ≈ "drive `x0xd` and surface `x0x gui`."**

## 3. Decision: UI surface = reuse `x0x gui` in the browser

| Option | Verdict |
|--------|---------|
| **Reuse `x0x gui` (served by `x0xd`), opened in the user's browser** | **CHOSEN.** ~90% communitas parity today; same-origin + token-in-URL (no CORS, no token embedded in a Fae file); honours Fae's "no embedded webview, rich UI delegated to the browser" architecture; near-zero new UI code. |
| Build a Fae-native UI via `show_html` | Rejected. `show_html` opens a static file from cache/`file://` → CORS against `127.0.0.1:12700` and forces embedding the bearer token into a Fae-written page (leak). Re-implements an existing 5k-line app. |
| Drive `communitas-core`/`ui-service` headless crates + bespoke UI | Rejected for now. Means compiling communitas into Fae and building a UI; fights Fae's architecture; the GUI already exists. (Revisit only if canvas/entity-hierarchy parity becomes a hard requirement.) |

This **refines** the earlier `fae-onboarding-x0x-communitas-2026-06-15.md` plan, which named
the **communitas Dioxus desktop app** as the front-end. Since the request is explicitly the
**browser**, `x0x gui` (browser-native, same `x0xd` identity) is the better surface.

## 4. Decision: a thin Python EXECUTABLE skill over the `x0xd` localhost REST API

Matches the onboarding plan's stated approach and Fae's `connect-account`/`mail`/`mesh`
precedent. **No Cargo / `fae-daemon` / conductor changes** — purely additive at the skill
layer. (The conductor's M4 *OwnerFleet* work is a **separate** concern — same-owner *compute*
delegation — and stays dormant/fail-closed; this skill does not touch it.)

### Skill layout
```
native/macos/Fae/Sources/Fae/Resources/Skills/collaborate/
  SKILL.md            # instruction body + script catalog + voice patterns + identity model
  MANIFEST.json       # schemaVersion 1, capabilities:[execute], allowedTools, sha256 integrity
  scripts/
    _x0x.py           # shared REST client (stdlib urllib only): resolve port+token, GET/POST/DELETE, errors
    ensure.py         # detect/install/start x0xd; /health; GET /agent; (opt-in) set user-id
    gui.py            # open the browser GUI (whole app or a specific tab) at /gui?token=…
    contacts.py       # list / import agent-card / add+trust contacts  (humans AND their agents)
    groups.py         # create / list / join / invite / members / admin  (spaces)
    message.py        # group send/read + direct send/read  (for voice narration)
    kanban.py         # task-lists CRUD (boards/cards)
    presence.py       # who's online / discover / FOAF
    swarm.py          # pub/sub tasks + results
    files.py          # send (posts path/data_b64 — FIXES the GUI's incomplete send) / list / accept / reject
```

### Runtime contract (matches `mesh`)
- Each script is a PEP-723 `#!/usr/bin/env -S uv run --script` file.
- Reads `json.loads(sys.stdin.read())["params"]`; prints a JSON result object to stdout.
- `_x0x.py` uses **stdlib only** (`urllib.request`) — no third-party deps, fast cold start,
  importable by every script via `sys.path.insert(0, dirname(__file__))`.
- Tight executor limits (ulimit, `timeoutSeconds`) are fine: these are short REST calls.
  Long-lived state (presence streams, the daemon) lives in **`x0xd`**, never in a script.

### Identity model — "connect humans and their agents"
x0x has **3-layer identity**: `User` (human, opt-in, never auto-created) / `Agent` /
`Machine`. A space holds **humans and agents as members alike** (both are x0x agents,
optionally bound to a `user_id`). So:
- **Connect to another Fae** = trust that Fae's `agent_id`.
- **Connect to a human** = import/trust their `user_id` (+ their agent card).
- **Connect to a human's agents** = trust those `agent_id`s.
`contacts.py` + `groups.py` are where this composes: invite a person, add their agent(s),
set roles. This is the genuinely novel value over a plain communitas clone, and it lives in
the REST layer where Fae's voice reasoning belongs.

## 5. Voice value-add (examples Fae can perform)
- "Create a space called *Project Falcon* and invite David and his agent." → `groups.py create` + `contacts.py` + `groups.py invite/add-member`.
- "Who's online?" / "Is David around?" → `presence.py`.
- "Show me the board." / "Open our space." → `gui.py` (opens the browser to the right tab).
- "Summarise the unread messages in Falcon." → `message.py read` → Fae summarises by voice.
- "Add a card 'ship the daemon' to the To-Do column." → `kanban.py`.
- "Send the design doc to the team." → `files.py send`.

## 6. Known gaps & risks (carried from the deep dive — fail loud)
1. **Parity is ~90%, not 100%.** x0x-GUI named-group admin is **25/37 endpoints wired** (12 deferred admin/audit); communitas's **canvas/whiteboard has no x0x-GUI equivalent**; richer communitas drive semantics are absent. "Full communitas parity" is the *roadmap target*, not the day-1 state.
2. **GUI file-send is incomplete** (posts filename/size/hash but not `path`/`data_b64`; accepted sends can fail "No source path available"). `files.py` sends the bytes correctly — a net improvement over the GUI.
3. **History durability gap.** Some chat/DM/feed history lives in browser `localStorage`; only public *signed* group messages are daemon-backed. Voice narration should read daemon-backed sources and say so when history may be partial.
4. **Swarm is generic pub/sub**, not a durable daemon swarm model — treat `swarm.py` as a thin topic publisher/subscriber, not a job queue with guarantees.
5. **Governance / metadata exposure.** This skill *is* the surface the threat model flags ("peer/group features … until G5 production enforcement"): social graph, presence, membership leave the device. Posture = **active** per owner standing consent, **but** defaults are conservative: no automatic `announce`/presence broadcast — Fae announces only on an explicit user action. G5 production enforcement remains a tracked follow-up.
6. **Multi-identity (`x0x --name <alias>`)** changes the port/token/data-dir. `_x0x.py` resolves per-instance; default instance unless the user names one.

## 7. Milestones toward full parity
- **M1 — Connective spine (this build):** `ensure` · `gui` · `contacts` · `groups` · `message` · `presence`. Result: Fae onboards x0x, opens the GUI, and can connect the user to other Fae/humans/agents and converse — by voice and visually.
- **M2 — Boards & async:** `kanban` · `swarm` · `files` (with the send-bytes fix). Result: task boards and file sharing driven by voice.
- **M3 — Parity closeout:** the 12 deferred named-group admin endpoints (if/when x0x wires them); a decision on canvas/whiteboard (drive `communitas` for that one surface, or accept the gap). Tracked, not in scope for M1/M2.

## 8. Out of scope / explicitly NOT doing
- No new long-lived process inside the skill (the daemon is `x0xd`).
- No Cargo dependency on `x0x`/`x0x-symphony`/`x0x-compute`; no conductor/`fae-daemon` edits.
- No embedding of the bearer token into any Fae-authored HTML.
- No automatic network announce/presence without explicit user action.

## 9. Validation
- `python -m py_compile` all scripts; manifest checksums regenerated and load-verified.
- Live smoke (owner machine, `just run-dev`): `ensure` brings up `x0xd`; `gui` opens the browser app; create a space; invite a second identity (`x0x --name bob`); exchange a message; add a kanban card; read it back by voice.
- Release-validation contract applies (skills/settings change): `docs/checklists/app-release-validation.md`.
- Obsidian vault note synced per repo policy.

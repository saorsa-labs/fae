# Owner Runbook — human-in-loop items after Phases A–F (2026-07-04)

Everything below needs the owner (credentials, sign-offs, or a physical machine).
All headless work is landed and CI-proven on `main` @ `9863ff03`.

## 1. x0x-symphony crates.io publish (unblocks version-pinned runner deps)

The release workflow is on x0x-symphony main (`6ba7d55`), gated on its full
`just check`, publishing all 8 crates in dependency order. The org-level
`CARGO_REGISTRY_TOKEN` exists (x0x publishes with it).

```bash
git -C ~/Desktop/Devel/projects/x0x-symphony tag v0.1.0
git -C ~/Desktop/Devel/projects/x0x-symphony push origin v0.1.0
# watch: gh run watch -R saorsa-labs/x0x-symphony
```

If the workflow's fail-fast step reports the secret missing, add x0x-symphony
to the org secret's repository-access list. After publish: tell the session to
re-pin `crates/fae-symphony-runner` from git-rev to crates.io versions.

## 2. ADR sign-offs

- **ADR-014** (`docs/adr/014-cloud-multi-model-lane.md`) — cloud lane. Flip
  Status: Proposed → Accepted after item 3 passes.
- **ADR-015** (`docs/adr/015-fae-delegate-symphony-runner.md`) — fae.delegate +
  quarantined runner. Flip after reviewing (the live gate already ran green).

## 3. Live-key OpenRouter turn (ADR-014's validation gate)

1. Settings → Models & Privacy → paste an OpenRouter API key (stored in
   Keychain), set privacy lane to "Allow cloud models", set a small daily
   budget (e.g. $1).
2. Restart the daemon lane (quit/relaunch via `source ~/.secrets && just run-dev`).
3. NOTE: routing intelligence (Phase D commit 5) is not built — no turn
   auto-selects cloud yet. The validation is currently via the conductor test
   path; ask the session for a hand-built RemoteAllowed turn script, or defer
   this item until commit 5 lands an explicit "ask the cloud" control.
4. Verify: PII membrane blocks a prompt containing a credential; budget
   exhaustion falls back to local with the spoken/visible notice.

## 4. x0x live checks (Phase E surfaces)

With both x0xd daemons up (:12700 default, :12701 fae-test-peer):
- `[x0x] enabled = true` + allowlist/ownerFleet configured (Settings → x0x
  Connections), relaunch → daemon starts the ingress (FAE_X0X_INGRESS=1).
- From the peer identity, send a direct message → it renders attributed in the
  conversation surface ("<sender> via x0x").
- "Edit → Hand off to…" → pick the peer machine → the peer's Fae shows the
  "Continue conversation from <machine>?" card. Known limit: only the pending
  turn hydrates (tail_len only on the wire — follow-up task #17).
- Two-machine handoff (this Mac + studio1) is the real-world version of the
  same check.

## 5. fae.delegate approval card (Phase F, real model)

A real bundled-app `conversation.delegate` turn where Gemma drives the loop and
a dangerous tool raises an actual approval card (the symphony runner
pre-authorizes; the interactive Swift path must still card). Drive via
`source ~/.secrets && just run-dev` + a delegate-triggering request.

## 6. Standing items carried from earlier sessions

- B5 real-mic + TTS validation (`spell_02` watchlist clip).
- Real ACP bundled-app turn (codex agent) raising an approval card.
- Release validation checklist (`docs/checklists/app-release-validation.md`)
  before the next tagged app release — Phase 13 (cloud lane) + skills/orb rows
  are new since v0.8.189.

## 7. Multi-node no-double-claim (Phase F follow-up)

The live gate proved task-lease no-double-claim under one x0xd identity. The
two-identity, two-node version (:12700 + :12701 replicating one task list) is
the documented next step in ADR-015 — needs x0x-level list replication between
the two identities first.

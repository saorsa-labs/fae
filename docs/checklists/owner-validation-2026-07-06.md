# Owner Validation Runbook — Audit + Review Response (2026-07-06)

Human-in-the-loop validation for everything that landed in the production-readiness
audit + the external-review response (`main @ 559445aa`). These cannot be greened
headlessly (mic, audio-out, orb visuals, ⌘V, real security bash reads). Base runbook:
`owner-runbook-2026-07-04.md`; contract: `app-release-validation.md`.

Legend: **[SEC]** release-blocker security check · **[REL]** reliability/live-bug regression · **[EPIC]** feature owner-sign-off.

---

## 0. Fresh launch (do this first)

A fresh dev data dir also exercises #21 (voice install) and the conversational first-launch onboarding.

- [ ] Quit any running Fae (dev or prod) and any stray `fae-daemon` (`pkill -f fae-daemon`).
- [ ] (Optional, for a truly clean #21 / onboarding test) move the dev data dir aside:
      `mv ~/Library/Application\ Support/fae-dev ~/Library/Application\ Support/fae-dev.bak` (restore later if you want your dev state back).
- [ ] From the repo root: `source ~/.secrets && just run-dev`
      (this rebuilds the daemon + orb shell + app with all the fixes, then launches. First run may block on model downloads.)
- [ ] Confirm the daemon env actually holds the secrets (so the env-scrub test below is meaningful): the launch shell sourced `~/.secrets`, so the daemon inherits `FAE_OPENROUTER_API_KEY` etc. — that's the point of the leak test.

---

## 1. [SEC] Bash sandbox — the release-blocker (do these before anything else)

Ask Fae (typed in the pill is fine) to run each bash command and read the tool result. The point: reads of protected paths must be DENIED even via evasive spellings, the daemon's provider keys must NOT leak, and normal bash must still work.

- [ ] **Direct protected read denied** — ask: *"run this bash command exactly: cat ~/.secrets"*
      → PASS: tool result is empty / "Operation not permitted" / permission denied. No contents of `~/.secrets` appear anywhere in Fae's reply.
- [ ] **Evasive spelling denied** (this is the one the substring gate missed) — ask: *"run this bash: h=.secrets; cat ~/$h"* and separately *"run: cat ~/.sec*"*
      → PASS: both denied, no secret bytes. (If either prints your secrets, STOP — the sandbox isn't on the executed path.)
- [ ] **SSH key read denied** — ask: *"run: cat ~/.ssh/id_ed25519"* (or id_rsa)
      → PASS: denied / empty.
- [ ] **Env key not leaked** — ask: *"run: printenv | grep -i openrouter"* and *"run: echo $FAE_OPENROUTER_API_KEY"*
      → PASS: empty output — the key is not in the bash child's environment.
- [ ] **Normal bash still works (no over-block)** — ask: *"run: ls ~/Desktop/Devel/projects/fae && echo hello"*
      → PASS: lists files, prints hello. Legitimate project-file reads, tool runs, and workspace writes must be unaffected.
- [ ] Note: on **Linux** the read-deny is a documented residual (env-scrub still applies); these read-denial checks are the **macOS** guarantee.

## 2. [REL] First-frame orb paint + PTT

- [ ] **Orb paints** within ~3s of launch (dim Quiescent glow at screen edge); brightens to Thinking within ~5–8s as the daemon loads, returns to idle. Debug Console (⌘D): no `RustUiShellController` launch errors.
- [ ] **PTT listening indicator** — hold Right ⌥ (or long-press the orb): orb shifts to a distinct Listening state within ~200ms + "Listening…" hint. Release → Thinking → Quiescent, no lingering Listening. (This is live-bug #8 — the mode key that was silently dropped.)
- [ ] **⌘V paste in the pill** — copy any text, expand the pill (click orb), press ⌘V → text appears. (Live-bug #1 — the Accessory-app Edit menu.)

## 3. [REL] Secure input card + wedge

- [ ] Trigger a secure prompt — ask: *"save my API key"* → a masked input card appears in the pill.
- [ ] **Auto-cancel on new turn** — without dismissing it, start a new voice turn (hold Right ⌥, say anything). → PASS: the card auto-dismisses, Fae responds, and the pill still responds to clicks (no wedge). (Live-bug #4.)

## 4. [EPIC] TTS = Lauren + mute + fallback (#21, live-bugs #5/#6)

- [ ] **Voice is Lauren, not af_heart** — say anything, Fae replies aloud → PASS: it sounds like Lauren (the fae voice). Debug Console should show `voice=fae` (not `af_heart`). This is the #21 fix — on a fresh data dir the voice must auto-install with no manual copy.
- [ ] **Mute** — click the mute glyph in the pill, send another turn → text reply, no audio. Click again → audio resumes.
- [ ] (Dev only) Silent-daemon fallback — the loud in-process Kokoro fallback should still be Lauren if the daemon TTS lane drops.

## 5. [REL] Long chat + context window

- [ ] Send 20+ short turns (type or converse). → PASS: no "I hit a local model problem" error; Fae still recalls something from early in the conversation. (P-H2 raised the 16 GB history budget from 6 turns to ~10 + fixed the ctx/`-c` mismatch.)

## 6. [REL] Daemon respawn + supervisor restart

- [ ] **Cloud-brain respawn** (extends base runbook item 9) — say *"set up a cloud brain"*, complete the OpenRouter key entry (masked card). → PASS: orb shows brief activity, returns to idle within ~10s (R-H1 now also retries once + surfaces failure instead of spinning forever if you were mid-turn).
- [ ] **Supervisor restart** (terminal) — `pkill -f fae-daemon`. → PASS: orb briefly dark, recovers to Quiescent within ~10–15s; next turn succeeds. Crash it ~5× fast → NSAlert "daemon crashed repeatedly… Try Again / Quit"; Try Again reloads.

## 7. [EPIC] Cloud lane, ASR, handoff (as available)

- [ ] **Live-key OpenRouter turn** — after cloud setup, say *"ask the cloud what is 1+1"*. NOTE: the W3 "ask the cloud" route currently can't reach RemoteAllowed (a wiring gap that fails safe — turns stay local); confirm it stays local (Debug Console: no RemoteAllowed) and does NOT error. A normal turn must stay local. (Wiring the route to actually reach the cloud is tracked separately.)
- [ ] **ASR fidelity** — say *"my favorite colour is blue"* a few times; judge whether the `[heard]` transcript is faithful (this is tracked task #23 — measure-first, your judgment feeds it).
- [ ] **Handoff tail (#17)** — needs TWO machines/identities running Fae over x0x; "Hand off to…" → the continued conversation should show the prior turns attributed as `[from <machine>] …`. Defer if you don't have a second identity up.

---

## What I can help drive vs. what's yours

Purely physical/visual (mic, audio-out, orb paint, ⌘V, the security bash reads) are yours. If you launch with the TestServer enabled (`FAE_TEST_SERVER=1` or `--test-server`), I can drive the text-observable subset over `:7433` — `/inject` turns for the long-chat/context check (§5) and the secure-card auto-cancel (§3), `/ptt-start` + `/status` for the listening flag (§2), `/config` for the respawn (§6) — and watch the state while you observe the visuals/audio. Say the word and I'll script that pass.

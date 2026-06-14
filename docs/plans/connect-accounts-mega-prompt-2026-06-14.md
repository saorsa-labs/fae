# MEGA PROMPT — Connect Account + PersonalDataAdapter (new-session team brief)

> Paste this whole document as the opening prompt of a fresh session. It is
> self-contained. You (the session lead) orchestrate a dev team through the
> phases below and STOP at each review gate. The full design is in
> `docs/plans/connect-accounts-personaldata-2026-06-14.md` — read it first.

---

## 1. Mission

Make Fae's productivity setup (mail / calendar / contacts) slick for a **normal
user on every OS**, replacing the developer dance (generate an app password,
hand-store 7 Keychain entries, write a himalaya config). Build the
**PersonalDataAdapter** seam + a voice-guided **connect-account** flow so the
user provides exactly **two inputs — their email + one app-specific password —**
and Fae opens the provider page, securely captures the one paste, derives and
stores everything else, and verifies live ("Connected — 2 emails today, 3 events
this week").

Target this build: **macOS + Linux**, **iCloud + generic IMAP/CalDAV/CardDAV**
(no OAuth-client dependency yet). The seam must leave clean slots for Windows,
Android, and Gmail/Outlook OAuth without reshaping.

Full spec, axes, and acceptance criteria: read
`docs/plans/connect-accounts-personaldata-2026-06-14.md` and
`docs/architecture/skills-first-cross-platform-2026-06-13.md` before writing code.

## 2. How to work (team + review gates)

- Work the phases **in order** (P1 → P2 → P3). Each ends at a **review gate**:
  produce the phase report (§6), then STOP for review before the next phase.
- Use the dev team: delegate implementation to `dev-agent`, run `code-reviewer`
  and `test-runner`/`build-validator` before declaring a phase done. **Verify
  every subagent claim against `git diff` and a real command run** — subagents
  in this project have fabricated completion reports before (0 tool calls,
  invented diffs). No claim is trusted without evidence you can re-run.
- Prefer Phase 1 first because it is **pure and fully unit-testable with no live
  accounts** — most of the risk is gated deterministically before anyone touches
  a real login.

## 3. Ground rules (non-negotiable)

1. **Read first**: `CLAUDE.md`, `DESIGN.md`, the two plan/architecture docs
   above, `crates/README.md`. Match existing conventions exactly.
2. **Justfile-first**: `just check` (root Swift), `cd crates && just check`,
   `just check-ui-shell`. Zero errors, zero warnings, zero clippy violations.
   No `.unwrap()/.expect()/panic!()/todo!()/unimplemented!()` in production
   (Rust or Swift); tests may use them.
3. **Evidence or it didn't happen.** Every phase report includes: `git diff
   --stat`, the tail of each `just check` run, the exact verification commands +
   their real output/transcripts, and log excerpts with timestamps. Fabricated
   or reconstructed output = automatic rejection.
4. **Secrets discipline (this feature's whole point):** credentials live ONLY in
   Keychain via `CredentialManager` (service `com.saorsalabs.fae`, account = the
   logical key). They must NEVER appear in chat, logs, the request JSON, SKILL.md,
   scripts, or config files. The secure-capture path is the existing
   `input_request` tool with `secure: true` + `store_key` (and
   `return_to_model: false`). Grep the run log in the report to prove no secret
   leaked.
5. **Forbidden zones** (do NOT touch): the MLX engines + LoRA training substrate
   (`FaeInference/`, `ML/MLX*`, TrainingBridge/ImprovementCycle); voice-identity
   /speaker files; `~/.fae-vault*`; the README model-name policy (DocsContractTests
   enforces NO model names in README); the daemon `models.lock` enforcement.
   Do not rewrite the existing 3 productivity skills' wire contract — wrap them.
6. **Docs discipline**: any repo doc you change → update the matching Obsidian
   vault note (`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Ideas/
   Saorsa Labs/Projects/fae/`). Update `docs/CHANGELOG.md` per phase.
7. **Branch hygiene**: work on a feature branch; if another team/process holds
   the main working tree, use a `git worktree` — do NOT commit onto someone
   else's branch. Open a PR per phase (or per logical chunk); do not merge —
   leave merge to the reviewer/owner.

## 4. Carried gotchas (violating these wastes a day)

- MLX ops CRASH under `swift test` (no metallib) — never unit-test MLX execution.
- QUIT the dev app before local `swift test`; run `swift test --skip
  VocabularyHarvestTests` (the known Contacts/TCC hang; it runs in CI).
- Known flakes: EchoSuppressor timing, CorpusEval noise-floor — rerun in
  isolation before suspecting your change.
- Launch the app ONLY via `source ~/.secrets && just run-dev`; logs at
  `/tmp/fae-dev.log`. Never open `.build/` artifacts directly.
- `@Published` sinks fire BEFORE the property is written — use the sink's value.
- Some Swift files have BOM/CRLF — use Read/Edit tooling, not `sed`.
- Kill processes by exact PID, never broad `pkill -f`.
- The daemon orphan-watch + DaemonProcessRegistry already exist; don't
  reintroduce orphans.

## 5. Phases

Read the plan doc for the full per-phase spec; this is the gate summary.

### Phase 1 — PersonalDataAdapter seam (pure, no accounts)
- A capability×OS resolution layer: calendar/contacts → EventKit/Contacts on
  macOS, CalDAV/CardDAV elsewhere; mail → IMAP everywhere. Above the seam,
  callers don't know the backend.
- Provider detection from the email domain (iCloud/me/mac → iCloud; else generic).
- iCloud config **derivation**: from `{email, appPassword}` produce all server
  settings + the exact Keychain key/value set + himalaya account config. Handle
  the custom-domain case: authenticate with the primary `@icloud.com` address,
  not the alias.
- **Gate:** `cd crates && just check` + root `just check --skip ...` green;
  comprehensive unit tests for provider/OS resolution and config derivation
  (deterministic, no live accounts); zero secrets in any emitted string (test).

### Phase 2 — connect-account flow
- New onboarding skill/flow `connect-account`: detect provider + OS → open the
  provider page (NSWorkspace.open / xdg-open) → voice-guide the 3 clicks → show a
  card with the URL button + secure input → capture one paste → derive+store all
  config (Phase 1) → verify live per capability → report. Idempotent re-run;
  failed verify rolls back the just-written entries.
- On macOS, calendar/contacts route to EventKit and require NO credential — only
  mail proceeds to the credential step.
- **Gate:** `just check-ui-shell` + Swift checks green; the flow runs in the dev
  app (log transcript); secret never in chat/log/JSON (grep proof); rollback +
  idempotency tested.

### Phase 3 — live proof (closes Task #8 as a real-user flow)
- **macOS**: "connect my accounts" → calendar/contacts verify via EventKit with
  no password; mail one paste → lists 5 inbox subjects. Real transcript.
- **Linux**: same intent → all three run the credential flow; live verify lists
  inbox subjects, next-7-day events (iCloud CalDAV), a contact lookup. Real
  transcript. (Owner provides the test iCloud app-specific password — ASK; do
  NOT fabricate. The owner stores it via the flow itself; the team sees only
  results.)
- **Gate:** real (non-fabricated) transcripts for both OSes; user provided
  exactly two inputs (email + one app password) for the full iCloud suite.

## 6. Reporting format (per phase)

```
PHASE Pn REPORT
1. What changed: git diff --stat (verbatim) + 3-6 bullet summary
2. Validation: tails of just check / cd crates && just check / just check-ui-shell
3. Live evidence: exact commands + real output/transcripts/logs (timestamps)
4. Secret-leak proof: grep of the run log showing no credential in chat/log/JSON
5. Deviations from this prompt + why
6. Known gaps / follow-ups
7. Docs touched + Obsidian notes updated
```

A report without verbatim evidence is rejected without review. The reviewer will
independently diff the tree and re-run the checks.

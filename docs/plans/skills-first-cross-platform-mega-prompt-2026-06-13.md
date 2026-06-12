# MEGA PROMPT — Skills-First Cross-Platform Execution (2026-06-13)

> Paste this whole document as the prompt for the implementing agent/team.
> It is self-contained. The reviewing agent (main session) checks every phase
> gate against the evidence rules in §2 before the next phase may start.

---

## 1. Mission

Execute the staged plan in
`docs/architecture/skills-first-cross-platform-2026-06-13.md`:

- **P1** — audio capture + playback in `fae-daemon` via cpal (portable voice spine)
- **P2** — productivity skills wave: mail (himalaya/IMAP), calendar (CalDAV), contacts (CardDAV), with agentskills.io-compatible frontmatter
- **P3** — orb host absorbs the Settings UI as a wry panel (macOS)
- **P4** — Linux render spike: orb + pill + one panel on Ubuntu
- **P5** — ship gates: release.yml daemon embedding + models.lock enforcement

Work the phases IN ORDER. Each phase ends at a review gate (§2). Do not start
the next phase until the reviewer approves the previous one.

## 2. Ground rules (non-negotiable)

1. **Read first**: repo `CLAUDE.md`, `DESIGN.md`,
   `docs/architecture/skills-first-cross-platform-2026-06-13.md`,
   `docs/architecture/cross-platform-go-nogo-2026-06-11.md`,
   `crates/README.md`. Match existing conventions exactly.
2. **Justfile-first**: `just check` (root, Swift), `cd crates && just check`
   (daemon workspace), `just check-ui-shell` (orb host). Zero errors, zero
   warnings, zero clippy violations, `RUSTFLAGS="-D warnings"` semantics. No
   `.unwrap()/.expect()/panic!()/todo!()` in production Rust (tests OK).
3. **Evidence or it didn't happen.** Every phase report MUST include:
   `git diff --stat` for the phase, the tail of each `just check` run, the
   exact commands used for live verification and their real output, and log
   excerpts with timestamps. Fabricated or reconstructed output = automatic
   rejection. The reviewer will independently diff the tree.
4. **Forbidden zones** (do NOT touch): `Tools/AppleTools.swift` (EventKit/
   Contacts stays), the MLX engines and training substrate
   (`FaeInference/`, `ML/MLX*`, TrainingBridge/ImprovementCycle), voice-
   identity/speaker files, `~/.fae-vault*`, README model-name policy
   (DocsContractTests enforces: NO model names in README). Do not delete or
   rewrite the Swift pipeline/memory/tools layers — this plan shrinks Swift by
   subtraction, later, not now.
5. **Gotchas** (hard-won; violating these wastes a day):
   - MLX ops CRASH under `swift test` (no metallib). Never unit-test MLX
     execution.
   - QUIT the dev app before running `swift test` locally (RuntimeContractTests
     spawns real daemons; a live daemon socket aborts the suite). Skip the
     known TCC hang: `swift test --skip VocabularyHarvestTests` locally (it
     runs in CI).
   - Known flakes: EchoSuppressor timing, CorpusEval noise-floor — rerun in
     isolation before suspecting your change.
   - Launch the app ONLY via `source ~/.secrets && just run-dev`; logs at
     `/tmp/fae-dev.log`. Never open `.build/` artifacts directly.
   - `@Published` sinks fire BEFORE the property is written — use the sink's
     value, never re-read the property.
   - Audio user messages must have EMPTY text content (S18 contract).
   - mistral.rs prefix cache stays DISABLED for audio turns.
   - BOM/CRLF in some Swift files — use Read/Edit tooling, not sed.
   - `pkill -f fae-daemon` kills more than you think — kill by exact PID.
   - Daemon sandbox for experiments: `HOME=/tmp/x HF_HOME=~/.cache/huggingface
     FAE_MODEL_ID=google/gemma-4-E4B-it fae-daemon` (never disturb the dev
     app's daemon).
6. **Docs discipline**: any repo doc you change → update the matching Obsidian
   vault note (`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Ideas/
   Saorsa Labs/Projects/fae/`). Update `docs/CHANGELOG.md` per phase.
7. **Commits**: conventional messages, one logical commit per phase chunk; do
   not push until the phase gate passes.

---

## 3. P1 — cpal capture + playback in fae-daemon

**Goal:** the daemon can record PTT audio and play synthesized audio itself, so
daemon + orb host form a complete talking Fae with no Swift in the audio path.
Swift's `AudioCaptureManager` remains the macOS default for now — this adds the
portable lane behind new daemon commands; it does not delete the Swift lane.

### Design constraints

- Crate: extend `crates/fae-daemon` (+ a new `fae-audio` crate in the workspace
  if separation is cleaner — your call, justify in the report).
- Use `cpal` for capture and playback. Capture spec matches S18: 16 kHz mono
  f32, converted/resampled from the device's native format. 30 s hard cap per
  capture. No VAD needed daemon-side (PTT release ends capture); include a
  trailing-silence trim helper only if trivial.
- New NDJSON commands on the existing control plane (same auth/authz path as
  `conversation.inject_text`; add scopes following the existing
  `fae-control-plane` pattern):
  - `audio.capture_start {}` → `{capture_id}`
  - `audio.capture_stop {capture_id}` → `{wav_base64, duration_ms, sample_rate}`
  - `audio.play {wav_base64}` → `{played_ms}` (blocking is fine for v1)
  - `audio.devices {}` → list of input/output device names (diagnostics)
- Fail loud: no input device / stream error → structured error response, never
  a hang. Capture without stop is reaped at the 30 s cap.
- Feature-gate if cpal hurts cold build times (`--features audio` default ON
  for the shipped binary).

### Acceptance criteria

- `cd crates && just check` green (fmt + clippy -D warnings + tests).
- Unit tests: WAV encode round-trip, resample correctness (48 kHz → 16 kHz sine
  preserves frequency), capture-cap reaping, command auth rejection.
- **Live proof (macOS)**: a Python script over the Unix socket (mirror
  `~/Library/Application Support/fae-dev/diagnostics/nan-repro/fae_audio_repro.py`
  for the protocol) runs capture_start → speak into mic → capture_stop →
  saves WAV → the WAV is valid 16 kHz mono and audible; then `audio.play`
  replays it. Include the script and its real transcript in the report.
- **Cross-compile proof**: `cargo zigbuild --target x86_64-unknown-linux-gnu
  -p fae-daemon` links clean (ALSA backend compiles; runtime test is P4).
- End-to-end loop proof: capture WAV → feed it to
  `conversation.inject_text` as `audio_wav_base64` → `[heard]:` transcript
  returned → `tts.synthesize` the reply → `audio.play` it. One script, real
  output in the report.

### Out of scope for P1

Streaming capture events, AEC, barge-in detection daemon-side, wiring Swift to
use this lane.

---

## 4. P2 — Productivity skills wave

**Goal:** Fae gains mail, CalDAV calendar, and CardDAV contacts as portable
executable skills. These are ADDITIVE: `AppleTools.swift` (EventKit/Contacts)
remains the privileged macOS path.

### Skills to create (under `native/macos/Fae/Sources/Fae/Resources/Skills/`)

1. **`mail-himalaya`** — read/search/send the user's email via the himalaya
   CLI (IMAP/SMTP).
2. **`calendar-caldav`** — list/create/update events via CalDAV (must work
   against iCloud with an app-specific password, and against Google CalDAV).
   Use Python + `caldav` library via `uv run --script` (PEP 723 inline deps),
   matching how existing executable skills run Python.
3. **`contacts-carddav`** — search contacts via CardDAV (same auth pattern).

### Contract for every skill (existing repo rules)

- `schemaVersion: 1`, `capabilities: ["execute"]`,
  `allowedTools: ["run_skill"]`, SHA-256 checksums in `integrity.checksums`
  (recompute recipe is in CLAUDE.md §Skill manifest contract).
- **agentskills.io-compatible frontmatter**: required `name` (lowercase-hyphen,
  = folder name) + `description` (what + when, the activation trigger);
  Fae-specific extras go under `metadata:`. Keep Fae's SHA-256 integrity layer
  (stricter than the spec — deliberate).
- SKILL.md body follows the Hermes section conventions: intro →
  `## When to Use` → `## Prerequisites` → `## How to Run` →
  `## Quick Reference` → `## Procedure` → `## Pitfalls` → `## Verification`.
  Under ~200 lines; details into `references/`.
- **Credentials**: NEVER in SKILL.md, scripts, or config files. Store via
  macOS Keychain using the existing `CredentialManager` pattern — follow how
  channel credentials are stored. Scripts receive creds via environment
  variables injected at execution, or read Keychain via `security` CLI; the
  skill documents the iCloud app-specific-password setup flow for the user.
- himalaya install: via brew through the existing `ToolAugmentationManager`
  extended-tier pattern (add `himalaya` to the tool table) — do not shell out
  to ad-hoc installers inside the skill.
- Update the built-ins table in CLAUDE.md (27 → 30 skills) + the skills doc.

### Acceptance criteria

- `just check` (root) green; skill manifests pass SkillManager integrity
  validation (there are existing tests — extend them for the three new skills).
- **Live proof for each skill** against a real account (reviewer's session
  will provide test credentials if needed — ASK, do not fabricate):
  - mail: list 5 most recent inbox subjects; send a test mail to self; show
    real CLI transcripts.
  - calendar: list next 7 days of events from iCloud CalDAV; create + delete a
    test event named `fae-skill-test`.
  - contacts: search a known contact by name, return phone/email.
- Voice-path proof: with the dev app running, a TYPED turn "what's on my
  calendar this week" activates the skill and answers (transcript from
  /tmp/fae-dev.log in the report).
- No regression: AppleTools calendar/contacts tools still registered and
  functional (existing tests pass).

---

## 5. P3 — Orb host absorbs the Settings UI (macOS)

**Goal:** Settings moves from the AppKit/SwiftUI window into a wry panel owned
by `native/rust/fae-ui-shell`, using the existing web-panel + bridge pattern
(the Messages panel with `controls_snapshot`/`set_access`/`set_thinking` is
the template).

### Scope (this phase = Settings only; onboarding/approvals are later phases)

- New bridge command pair following the existing pattern:
  `settings_snapshot` (Swift → JSON of current settings) and
  `settings_set {key, value}` (panel → Swift), mapping to the existing
  `FaeCore.patchConfig()` / SelfConfigTool-adjustable surface (CLAUDE.md
  §Self-modification table: tts.speed, llm.temperature, thinking, awareness
  intervals, etc.). The always-on showcase section renders as informational
  cards, NOT toggles (CLAUDE.md §Settings UI treatment).
- Panel HTML/CSS follows DESIGN.md exactly: Scottish palette, Instrument Serif
  for headers, no emoji in headers, WCAG AA text variants. The panel must be
  legible with an OPAQUE background (no reliance on transparency —
  P4/Linux constraint).
- The existing SwiftUI Settings window stays functional behind a menu item
  ("Settings (legacy)") until the panel reaches parity for the adjustable
  keys; do NOT delete Swift settings code in this phase.
- Two-way sync: changing a value in the panel is observable in config and
  vice versa (settings_snapshot re-pushed on change events).

### Acceptance criteria

- `just check-ui-shell` + `just check` green.
- Live proof: screenshots (or `screencapture` output) of the panel; change
  `tts.speed` in the panel → show the config value changed
  (`grep speed ~/Library/Application Support/fae-dev/config.toml` or
  UserDefaults read) → change it back via `self_config` typed turn → panel
  reflects it.
- Orb gestures unaffected: Right ⌥ hold/release and long-press still capture
  (log excerpt with `PTT capture started/finished`).

---

## 6. P4 — Linux render spike (time-boxed: report > polish)

**Goal:** measure, on real Linux, what works: wgpu orb, pill, one wry panel.
This is a SPIKE — the deliverable is a findings report + CI guard, not
production Linux support.

- Make `fae-ui-shell` compile for Linux: gate the macOS-only bits
  (`cfg(target_os)`), pick GTK paths for tao/muda/wry. It already builds on
  macOS; get `cargo check --target x86_64-unknown-linux-gnu` (or a Linux
  builder) green.
- Add a CI job (GitHub Actions, ubuntu-latest) that installs the GTK/WebKitGTK
  dev packages and runs `cargo clippy -D warnings` + `cargo build` for
  `fae-ui-shell` and `fae-daemon` (no GPU needed for build).
- Manual run matrix (document results; a VM or the saorsa-1 box + X forwarding
  won't have a GPU — use a desktop VM with virgl or note software rendering):
  X11 and Wayland: (a) orb renders + animates, (b) pill renders (transparency
  expected to FAIL per tauri#12800/#9220 — document exact behavior),
  (c) Messages panel opens and renders, (d) drag + long-press gestures.
- Findings doc: `docs/architecture/linux-render-spike-2026-06.md` with a
  go/no-go per surface and the recommended Linux pill strategy (wry-transparent
  vs wgpu-rendered captions).

### Acceptance criteria

- CI job green on ubuntu-latest (build + clippy).
- Findings doc with real observations (screenshots/asciinema where possible).

---

## 7. P5 — Ship gates (Task #9 remainder)

1. **release.yml daemon embedding**: the release workflow builds `fae-daemon`
   (macOS arm64 release) and embeds + signs it in the app bundle exactly like
   the local `_embed-daemon` recipe (`Contents/MacOS/fae-daemon`). Mirror the
   `_embed-ui-shell` treatment already present locally — check how release.yml
   handles fae-ui-shell today and follow the same path. Cache the cargo build
   (mistral.rs is heavy — use Swatinem/rust-cache or actions/cache on
   `crates/target`).
2. **models.lock enforcement**: `fae-engine` has a fail-closed `ModelsLock`
   loader that is NOT wired in. Wire it:
   - Generate a real `models.lock` for the `google/gemma-4-E4B-it` HF snapshot
     (script: walk the snapshot dir, emit `[[artifact]]` entries with
     size + sha256 per `docs/templates/models.lock.example`).
   - Daemon load path verifies the model files against the lock BEFORE
     `LocalMistralrsAdapter::load`; missing/mismatched → structured fatal
     error. Lock file location: `<fae data dir>/models.lock`, installed from
     the app bundle on first run (same pattern as the bundled TTS voice
     install in `DaemonTTSEngine.installBundledVoices()`).
   - Dev escape hatch: `FAE_MODELS_LOCK=off` env skips verification with a
     loud eprintln (dev profile sets it; production never does).
   - Update CLAUDE.md's daemon-lane paragraph to match reality.

### Acceptance criteria

- A `workflow_dispatch` dry-run of release.yml (or an act/dispatch on a branch)
  produces a bundle whose `Contents/MacOS/fae-daemon` exists, is signed, and
  launches.
- Daemon with a tampered model file (flip one byte in a copy, point the lock
  at it) REFUSES to load with a clear error; with the correct lock it loads
  and answers a turn. Real transcripts in the report.
- `cd crates && just check` + `just check` green.

---

## 8. Reporting format (per phase, for review)

```
PHASE Pn REPORT
1. What changed: git diff --stat (verbatim) + 3-6 bullet summary
2. Validation: tails of `just check` / `cd crates && just check` /
   `just check-ui-shell` runs (verbatim)
3. Live evidence: the exact commands run + their real output/transcripts/logs
4. Deviations from this prompt + why
5. Known gaps / follow-ups
6. Docs touched + Obsidian notes updated
```

The reviewer will independently run the checks and diff the tree. Reports
without verbatim evidence are rejected without review.

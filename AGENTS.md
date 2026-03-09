# AGENTS.md — Fae Swift Engineering Guardrails

This file defines implementation guardrails for agents modifying Fae.

## Current architecture (authoritative)

Fae is a **pure Swift** macOS app in `native/macos/Fae`.

- No embedded Rust core in production
- No C ABI / `libfae` dependency in active runtime path
- Build/test with SwiftPM:

```bash
cd native/macos/Fae
swift build
swift test
```

Historical Rust-era docs under `docs/adr/*` and `legacy/rust-core/` are archival context only.

---

## Memory is production-critical

Treat memory as a core subsystem.

Non-negotiables:

- Preserve on-disk compatibility unless a migration is added.
- Never silently overwrite conflicting durable facts; use supersession lineage.
- Keep recall + capture automatic in normal conversation flow.
- Keep memory edits auditable.
- Keep non-test mutation paths panic-free and force-unwrap-free where feasible.

Behavioral truth sources:

- `Prompts/system_prompt.md`
- `SOUL.md`
- `HEARTBEAT.md`
- `docs/guides/Memory.md`

Implementation touchpoints:

- `native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift`
- `native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift`
- `native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift`
- `native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift`

### Memory storage contract

Storage root:

- `~/Library/Application Support/fae/`

Primary files:

- `fae.db` (SQLite)
- `backups/` (rotating DB backups)

Record semantics:

- kinds: `profile`, `fact`, `episode`, `event`, `person`, `interest`, `commitment`
- status: `active`, `superseded`, `invalidated`, `forgotten`
- lineage: `supersedes`

---

## Scheduler cadence (current Swift runtime)

- Tick: every 60s (`FaeScheduler.runDailyChecks()` + repeating timers)
- Built-ins:
  - `check_fae_update` every 6h
  - `memory_migrate` every 1h
  - `memory_reindex` every 3h
  - `memory_reflect` every 6h
  - `memory_gc` daily 03:30
  - `memory_backup` daily 02:00
  - `noise_budget_reset` daily 00:00
  - `morning_briefing` daily (configurable hour)
  - `skill_proposals` daily (configurable hour)
  - `stale_relationships` weekly
  - `skill_health_check` every 5m

---

## Tooling reality

Registered built-ins (ToolRegistry):

- Core/web: `read`, `write`, `edit`, `bash`, `self_config`, `web_search`, `fetch_url`
- Apple: `calendar`, `reminders`, `contacts`, `mail`, `notes`
- Scheduler: `scheduler_list`, `scheduler_create`, `scheduler_update`, `scheduler_delete`, `scheduler_trigger`
- Roleplay: `roleplay`

Tool modes:

- `off`
- `read_only`
- `read_write`
- `full`
- `full_no_approval`

---

## Proactive behavior policy

Proactive automation must stay useful and quiet:

- Prefer batched summaries over frequent interruptions.
- Surface only actionable/high-signal updates.
- Collapse repetitive, non-urgent events.
- Reserve immediate interruption for urgent events.
- Keep low-value maintenance details off the main conversation surface.
- Prefer progressive disclosure and the approval popup over sending users into Settings for ordinary setup or permission decisions.

---

## Python integration

Fae uses Python as an **extension mechanism**, not a core runtime. Python runs in subprocesses managed by Swift.

See `docs/guides/python-integration.md` for full details.

### Key facts

- **Auto-install**: Fae installs uv automatically when needed (with user approval)
- **UVRuntime.swift**: Centralized uv discovery/management in `Sources/Fae/Runtime/UVRuntime.swift`
- **DependencyInstaller.swift**: Handles approval dialogs and installation for required tools
- **Isolation**: Each script gets its own venv in `~/.cache/uv/environments-v2/`
- **No bundled Python**: uv handles Python installation and package management

### Automatic dependency installation

**Fae takes care of her users.** When Python features are needed:

1. `UVRuntime.ensureAvailable()` checks if uv is installed
2. If not, `DependencyInstaller` shows a friendly approval dialog
3. If approved, uv is installed automatically (no terminal required)
4. The original operation continues seamlessly

**Never ask users to type commands.** Fae handles everything.

### Python components

| Component | Script | Purpose |
|-----------|--------|---------|
| TTS | `Resources/Scripts/kokoro_tts_server.py` | Kokoro-ONNX TTS via subprocess |
| Skills | `Resources/Skills/*/scripts/*.py` | Extensible skill scripts |

### Cache locations

| Cache | Location |
|-------|----------|
| uv environments | `~/.cache/uv/environments-v2/` |
| uv packages | `~/.cache/uv/archive-v0/` |
| HuggingFace models | `~/.cache/huggingface/hub/` |

### Adding new dependencies

To add support for auto-installing a new tool:

1. Add a case to `DependencyInstaller.Dependency` enum
2. Provide `displayName`, `description`, `installCommand`, `verifyCommand`
3. Add installation logic in `install()` method
4. Use `DependencyInstaller.shared.ensureInstalled(.yourTool)` where needed

---

## Testing guardrails

- Run before shipping Swift changes:

```bash
cd native/macos/Fae
swift build
swift test
```

- Integration tests live under:
  - `native/macos/Fae/Tests/IntegrationTests/`

- Keep tests deterministic and avoid network dependencies unless explicitly marked live.

### Release validation is mandatory

For any change to models, prompting, routing, voice, approvals, tools, memory, scheduler, skills, Cowork, remote-provider behavior, or other user-visible app flows, treat
`docs/checklists/app-release-validation.md` as a required release gate.

The step-by-step live scenario script is
`docs/checklists/main-and-cowork-live-test-scenarios.md`.
Update both files in the same change whenever a user-visible capability,
validation path, or runtime boundary changes.

Minimum expectations:

- update that checklist when a new capability or boundary is added
- update the live scenario script when the manual release workflow changes
- run the relevant `tests/comprehensive/specs/*.yaml` phases through `scripts/test-comprehensive.sh`
- run the real app via `just run-native` or `just rebuild`
- run the test server via `just test-serve`
- validate real audio input/output where voice is involved
- capture screenshots for startup, onboarding, permissions, main window, Cowork, and any failure state

Do not claim the app is production-ready if the scripted phases pass but the live app validation contract has not been completed.

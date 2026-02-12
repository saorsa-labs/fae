# Phase 1.1: Remove PI Dependency — Task Plan

## Goal
Remove all PI coding agent integration from the FAE codebase. This includes the pi module, pi_config, HTTP server, config types, and all references across 13+ source files. After this phase, zero PI references remain and the project compiles cleanly.

## Strategy
Remove in dependency order: standalone PI files first, then types/config, then all consumers, then deps. Tasks 1-6 perform deletions/edits, task 7 cleans deps and compiles, task 8 verifies everything.

---

## Tasks

### Task 1: Delete PI module directory and PI-only LLM files
**Files to delete:**
- `src/pi/mod.rs`
- `src/pi/engine.rs`
- `src/pi/manager.rs`
- `src/pi/session.rs`
- `src/pi/tool.rs`
- `src/llm/pi_config.rs`
- `src/llm/server.rs`
- `Skills/pi.md`
- `.pi/` directory

**Files to edit:**
- `src/lib.rs` — remove `pub mod pi;` declaration
- `src/llm/mod.rs` — remove `pub mod pi_config;` and `pub mod server;` declarations

---

### Task 2: Remove PiConfig and LlmBackend::Pi from config.rs
**File:** `src/config.rs`

**Changes:**
- Remove `pub pi: PiConfig` field from `SpeechConfig` struct (~line 37)
- Remove entire `PiConfig` struct definition (~lines 691-712) and its Default impl
- Remove `Pi` variant from `LlmBackend` enum (~lines 161-163)
- Change `LlmBackend` default from `Pi` to `Local`
- Update `effective_provider_name()` to remove Pi match arm (~line 410)
- Fix/remove test that asserts `LlmBackend::default() == LlmBackend::Pi` (~line 842)
- Remove any imports/uses that only existed for PiConfig

---

### Task 3: Remove PI from startup.rs and update/checker.rs
**File:** `src/startup.rs`

**Changes:**
- Remove imports: `crate::llm::pi_config::default_pi_models_path`, `remove_fae_local_provider`
- Remove Pi cleanup on shutdown (~lines 50-51)
- Remove `LlmBackend::Pi` from use_local_llm decision branches (~lines 77, 177)
- Remove Pi HTTP server startup logic (~lines 319-320, 355-356)
- Remove `write_fae_local_provider()` calls

**File:** `src/update/checker.rs` (or `src/update/` module)

**Changes:**
- Remove `use crate::pi::manager::version_is_newer` import
- Remove `UpdateChecker::for_pi()` method
- Remove `crate::pi::manager::platform_asset_name()` calls
- Remove Pi-specific update checking logic

---

### Task 4: Remove PI from pipeline/coordinator.rs
**File:** `src/pipeline/coordinator.rs`

**Changes:**
- Remove `Pi(Box<crate::pi::engine::PiLlm>)` variant from internal LLM backend enum (~line 1390)
- Remove `use crate::pi::engine::PiLlm;` import (~line 1446)
- Remove `LlmBackend::Pi =>` initialization block (~line 1487)
- Remove `uuid::Uuid::new_v4()` usage in Pi context (~line 1726)
- Remove entire axum HTTP server setup section (~lines 3094-3791)
- Remove Pi-related test instances (~line 4143)
- Remove model_selection_rx/voice_command_tx channels if only used for Pi

---

### Task 5: Remove PI from agent/mod.rs and llm/api.rs
**File:** `src/agent/mod.rs`

**Changes:**
- Remove `use crate::pi::session::PiSession;` import
- Remove `use crate::pi::tool::PiDelegateTool;` import
- Remove `pi_session: Option<Arc<Mutex<PiSession>>>` constructor parameter
- Remove Pi models.json resolution logic (~lines 57-66)
- Remove cloud fallback using pi_config (~lines 378-380)
- Remove PiDelegateTool registration

**File:** `src/llm/api.rs`

**Changes:**
- Remove Pi models.json lookups (~lines 334-338)
- Remove `pi_config::read_pi_config()` usage

---

### Task 6: Remove PI from GUI, voice commands, skills, and remaining files
**File:** `src/bin/gui.rs`

**Changes:**
- Remove `LlmBackend::Pi` as default backend assignment (~line 1659)
- Remove Pi provider/model UI selection dropdowns (~lines 1688-1750)
- Remove all `LlmBackend::Pi` match arms throughout (14+ locations)
- Remove "install_pi_update" action handling
- Replace Pi backend references with appropriate remaining backends

**File:** `src/voice_command.rs`

**Changes:**
- Remove `use crate::pi::engine::PiLlm;` references (~lines 778, 803, 825)
- Remove Pi backend pattern matching in model switching

**File:** `src/skills.rs`

**Changes:**
- Remove `pub const PI_SKILL: &str = include_str!("../Skills/pi.md");`
- Remove "pi" from `list_skills()`
- Remove `PI_SKILL.to_owned()` from `load_all_skills()`
- Remove pi skill filtering logic

**File:** `src/memory.rs` — Remove any Pi-specific references
**File:** `src/progress.rs` — Remove Pi download progress tracking
**File:** `src/runtime.rs` — Remove Pi runtime events
**File:** `src/model_picker.rs` — Remove Pi model picker logic
**File:** `src/model_selection.rs` — Remove Pi from tier selection
**File:** `src/scheduler/tasks.rs` — Remove "install_pi_update" task

---

### Task 7: Clean up Cargo.toml dependencies and compile
**File:** `Cargo.toml`

**Changes:**
- Remove `axum = "0.8"` (only used by deleted llm/server.rs)
- Remove `tower-http = { version = "0.6", features = ["cors"] }` (only used with axum)
- Remove `uuid = { version = "1", features = ["v4"] }` (only used for Pi request IDs)
- Verify no other files use these deps before removal

**Then:**
- Run `cargo check --all-features --all-targets` — fix ALL compilation errors
- Run `cargo clippy --all-features --all-targets -- -D warnings` — fix ALL warnings
- Run `cargo fmt --all` — format all edited files
- Iterate until zero errors and zero warnings

---

### Task 8: Verify tests pass and final cleanup
**Verification:**
- Run `cargo nextest run --all-features` — ALL tests must pass
- Run `just check` (full validation: fmt, lint, build, test, doc, panic-scan)
- Grep for any remaining PI references: `grep -r "pi::\|PiLlm\|PiSession\|PiManager\|PiConfig\|PiDelegateTool\|pi_config\|PI_SKILL\|LlmBackend::Pi" src/`
- Remove any dead code flagged by clippy after removal
- Verify zero warnings, zero errors

---

## File Change Summary

| File | Action |
|------|--------|
| `src/pi/` (5 files) | **DELETE** |
| `src/llm/pi_config.rs` | **DELETE** |
| `src/llm/server.rs` | **DELETE** |
| `Skills/pi.md` | **DELETE** |
| `.pi/` directory | **DELETE** |
| `src/lib.rs` | **MODIFY** — remove pi module |
| `src/llm/mod.rs` | **MODIFY** — remove pi_config, server modules |
| `src/config.rs` | **MODIFY** — remove PiConfig, LlmBackend::Pi |
| `src/startup.rs` | **MODIFY** — remove Pi init/cleanup |
| `src/update/checker.rs` | **MODIFY** — remove Pi update logic |
| `src/pipeline/coordinator.rs` | **MODIFY** — remove Pi backend, HTTP server |
| `src/agent/mod.rs` | **MODIFY** — remove Pi session/tool |
| `src/llm/api.rs` | **MODIFY** — remove Pi config lookups |
| `src/bin/gui.rs` | **MODIFY** — remove Pi UI elements |
| `src/voice_command.rs` | **MODIFY** — remove Pi model switching |
| `src/skills.rs` | **MODIFY** — remove Pi skill |
| `src/memory.rs` | **MODIFY** — remove Pi refs |
| `src/progress.rs` | **MODIFY** — remove Pi progress |
| `src/runtime.rs` | **MODIFY** — remove Pi events |
| `src/model_picker.rs` | **MODIFY** — remove Pi picker |
| `src/model_selection.rs` | **MODIFY** — remove Pi tier |
| `Cargo.toml` | **MODIFY** — remove axum, tower-http, uuid |

## Quality Gates
- `just check` passes (fmt, lint, build, test, doc, panic-scan)
- Zero `.unwrap()` or `.expect()` in production code
- All remaining tests continue to pass
- Zero PI references anywhere in src/
- Zero compilation warnings

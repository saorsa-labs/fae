# Phase 8.3: Skill Lifecycle Management

## Overview
Add full lifecycle management for Python skill executables (`.py` files with PEP 723 headers)
alongside the existing managed markdown skills. Key additions:

- `PythonSkillStatus` enum with states: `Pending → Testing → Active → Disabled → Quarantined`
- `PythonSkillManifest` (parsed from `manifest.toml` inside a Python skill package)
- `PythonSkillRecord` stored in `registry.json` alongside existing managed-skill records
- Versioning with snapshot history (reusing the existing snapshot mechanism)
- Rollback support for Python skills
- New file: `src/skills/python_lifecycle.rs`
- New file: `src/skills/manifest.rs`
- Updates to `src/skills/mod.rs` to expose Python lifecycle management
- Integration test in `tests/python_skill_lifecycle.rs`

## What Already Exists (Do NOT duplicate)
- `ManagedSkillState` (Active/Disabled/Quarantined) for markdown skills in `mod.rs`
- `ManagedSkillRecord`, `SkillRegistry`, `SkillPaths` in `mod.rs`
- Snapshot machinery (`snapshot_existing_skill`, `write_atomic`) in `mod.rs`
- `PythonSkillError` in `error.rs`
- `UvBootstrap` / `UvInfo` in `uv_bootstrap.rs`
- `ScriptMetadata` / PEP 723 parsing in `pep723.rs`

## Tasks

### Task 1: `PythonSkillStatus` enum + error variants
**File**: `src/skills/python_lifecycle.rs` (new)
**Tests**: Unit tests for valid/invalid state transitions, `Display` impl, serde round-trip
**Acceptance**:
- `PythonSkillStatus` with variants: `Pending`, `Testing`, `Active`, `Disabled`, `Quarantined`
- `can_transition_to(target) → bool` method enforcing state machine rules:
  - `Pending → Testing`
  - `Testing → Active | Disabled | Quarantined`
  - `Active → Disabled | Quarantined`
  - `Disabled → Active | Quarantined`
  - `Quarantined → Disabled` (for manual review)
- `is_runnable() → bool` (only `Active`)
- `Display` impl with snake_case names
- `Serialize`/`Deserialize` with `rename_all = "snake_case"`
- Full doc comments on all items

### Task 2: `PythonSkillManifest` — parse from `manifest.toml`
**File**: `src/skills/manifest.rs` (new)
**Tests**: Parse valid manifest, missing optional fields use defaults, reject empty id,
          reject invalid id chars, reject empty name
**Acceptance**:
- `PythonSkillManifest` struct with fields: `id: String`, `name: String`, `version: String`,
  `description: Option<String>`, `entry_file: String` (default `"skill.py"`),
  `min_uv_version: Option<String>`, `min_python: Option<String>`
- `load_from_dir(dir: &Path) → Result<PythonSkillManifest, PythonSkillError>`
  reads `dir/manifest.toml`, parses with `toml::from_str`
- `validate(&self) → Result<(), PythonSkillError>` checks id/name not empty, id uses safe chars
- Full doc comments

### Task 3: `PythonSkillRecord` and Python registry operations
**File**: `src/skills/python_lifecycle.rs` (expanded)
**Tests**: Serialization round-trip of `PythonSkillRecord`, registry read/write with empty registry,
          upsert idempotency, list ordering
**Acceptance**:
- `PythonSkillRecord` struct: `id`, `name`, `version`, `status: PythonSkillStatus`,
  `script_path: PathBuf`, `work_dir: PathBuf`, `last_known_good_snapshot: Option<PathBuf>`,
  `last_error: Option<String>`, `installed_at: u64`, `updated_at: u64`
- `PythonSkillInfo` (public view, no internal paths): `id`, `name`, `version`,
  `status: PythonSkillStatus`, `last_error: Option<String>`
- `PythonSkillRegistry` struct wrapping `Vec<PythonSkillRecord>` with `upsert()`, `get()`,
  `get_mut()`, `status_map()`
- `load_python_registry(paths) → Result<PythonSkillRegistry>`
- `save_python_registry(paths, registry) → Result<()>`
- Registry file stored at `{skills_dir}/.state/python_registry.json`

### Task 4: Install Python skill package + Testing state
**File**: `src/skills/python_lifecycle.rs` (expanded), `src/skills/mod.rs` (re-exports)
**Tests**: Install from directory → record created as Pending → transition to Testing →
          Active; install again upgrades version + creates snapshot
**Acceptance**:
- `install_python_skill(package_dir: &Path) → Result<PythonSkillInfo, PythonSkillError>`
  1. Load and validate `manifest.toml` via `PythonSkillManifest::load_from_dir`
  2. Parse PEP 723 metadata from the entry `.py` file via `ScriptMetadata`
  3. Copy the script to `{skills_dir}/{id}.py`, snapshot existing if present
  4. Register with `PythonSkillStatus::Pending`
  5. Return `PythonSkillInfo`
- `advance_python_skill_status(id, new_status) → Result<(), PythonSkillError>`
  validates transition, updates registry
- `mod.rs` re-exports `install_python_skill`, `advance_python_skill_status`, `PythonSkillInfo`,
  `PythonSkillStatus`

### Task 5: Disable / Quarantine / Activate / Rollback for Python skills
**File**: `src/skills/python_lifecycle.rs` (expanded)
**Tests**: disable moves .py to disabled dir; quarantine sets error; activate restores file;
          rollback restores snapshot content; rollback with no snapshot returns error
**Acceptance**:
- `disable_python_skill(id) → Result<(), PythonSkillError>`
  moves `{id}.py` → `.state/disabled/{id}.py`, sets status `Disabled`
- `quarantine_python_skill(id, reason) → Result<(), PythonSkillError>`
  moves `.py` to disabled dir, sets status `Quarantined`, records `last_error`
- `activate_python_skill(id) → Result<(), PythonSkillError>`
  restores `.py` from disabled dir (or snapshot), sets status `Active`, clears `last_error`
- `rollback_python_skill(id) → Result<(), PythonSkillError>`
  restores `.py` from `last_known_good_snapshot`, sets status `Active`
- `list_python_skills() → Vec<PythonSkillInfo>` public wrapper

### Task 6: Host command integration + module wiring
**Files**: `src/skills/mod.rs` (expanded), `src/host/contract.rs` (expanded),
          `src/host/handler.rs` (expanded)
**Tests**: Handler correctly routes python skill lifecycle commands to the lifecycle functions
**Acceptance**:
- `HostCommand::PythonSkill` variants: `Install { package_dir }`, `Disable { id }`,
  `Activate { id }`, `Quarantine { id, reason }`, `Rollback { id }`,
  `AdvanceStatus { id, status }`, `List`
- Handler routes each variant to the corresponding `python_lifecycle` function
- Returns `HostEvent::PythonSkillResult { skill_info: Option<PythonSkillInfo>, skills: Option<Vec<PythonSkillInfo>>, error: Option<String> }`
- Module re-exports complete
- Zero warnings

### Task 7: Integration test
**File**: `tests/python_skill_lifecycle.rs` (new)
**Tests**: Full E2E: create package dir with manifest.toml + skill.py → install → advance to
          Active → disable → activate → quarantine with reason → rollback
**Acceptance**:
- All lifecycle state transitions exercised end-to-end
- Snapshot is created on re-install (version upgrade)
- Rollback restores prior script content
- File system state matches registry state at each step
- Test uses temp directory, fully isolated

## Task Dependencies
```
Task 1 (PythonSkillStatus) → Task 3 (PythonSkillRecord)
Task 2 (Manifest) → Task 4 (Install)
Task 3 → Task 4 (Install)
Task 4 → Task 5 (Disable/Quarantine/Activate/Rollback)
Task 5 → Task 6 (Host commands)
Task 6 → Task 7 (Integration test)
```

# Phase 6.4 — Settings Expansion

**Status:** Planning
**Milestone:** 6 — Dogfood Readiness

---

## Overview

Phase 6.4 adds missing Settings tabs and removes false capability claims:
- Tools settings tab with tool mode picker (Off/ReadOnly/ReadWrite/Full/FullNoApproval)
- Channels settings tab with Discord/WhatsApp configuration forms
- Remove CameraSkill from builtins (no camera tool implementation exists)

Mix of Swift UI and Rust changes.

---

## Prerequisites

| Prerequisite | Status |
|-------------|--------|
| Phase 6.3 committed | DONE |
| `config.patch` command exists | DONE (SettingsAboutTab uses it) |
| `AgentToolMode` enum in config.rs | DONE (Off/ReadOnly/ReadWrite/Full/FullNoApproval) |
| `ChannelsConfig` with Discord/WhatsApp | DONE (config.rs:946) |
| `CameraSkill` in builtins.rs | EXISTS (to be removed) |

---

## Tasks

### Task 1 — Create SettingsToolsTab.swift (30 min)

**Goal:** New settings tab for controlling tool mode with a picker.

**Scope:** New `SettingsToolsTab.swift`

**Subtasks:**
1. Create `SettingsToolsTab.swift` following the pattern from `SettingsGeneralTab.swift`
2. Add a `Picker` for tool mode with options: Off, Read Only (default), Read/Write, Full, Full (No Approval)
3. Store selection as `@AppStorage("toolMode")` or `@State` with config.patch on change
4. Accept `commandSender: HostCommandSender?` to send `config.patch` with key `tool_mode`
5. Add descriptive text explaining each mode
6. Add section showing current active tools count (placeholder for now)

**Files:** New `native/macos/.../SettingsToolsTab.swift`

**Dependencies:** None

---

### Task 2 — Wire SettingsToolsTab into SettingsView (15 min)

**Goal:** Add the Tools tab to the settings TabView.

**Scope:** `SettingsView.swift`

**Subtasks:**
1. Add `SettingsToolsTab(commandSender: commandSender)` as a new tab between Models and About
2. Use `Label("Tools", systemImage: "wrench.and.screwdriver")` for the tab item
3. Verify tab ordering: General, Models, Tools, About, (Developer)

**Files:** `native/macos/.../SettingsView.swift`

**Dependencies:** Task 1

---

### Task 3 — Handle tool_mode config.patch in Rust (30 min)

**Goal:** Rust backend accepts `config.patch` for `tool_mode` key.

**Scope:** `src/host/handler.rs`

**Subtasks:**
1. In `request_config_patch()`, add case for key `"tool_mode"`
2. Parse value as string matching AgentToolMode variants: "off", "read_only", "read_write", "full", "full_no_approval"
3. Update `self.config.agent.tool_mode` with the new value
4. Log the change at info level
5. Return error for invalid mode values

**Files:** `src/host/handler.rs`

**Dependencies:** None (parallel with Tasks 1-2)

---

### Task 4 — Create SettingsChannelsTab.swift (30 min)

**Goal:** New settings tab for Discord and WhatsApp channel configuration.

**Scope:** New `SettingsChannelsTab.swift`

**Subtasks:**
1. Create `SettingsChannelsTab.swift` following existing tab patterns
2. Add master "Enable Channels" toggle (maps to `channels.enabled`)
3. Add Discord section with:
   - Bot Token (SecureField)
   - Guild ID (optional TextField)
   - Allowed Channel IDs (TextField, comma-separated)
4. Add WhatsApp section with:
   - Access Token (SecureField)
   - Phone Number ID (TextField)
   - Verify Token (SecureField)
   - Allowed Numbers (TextField, comma-separated)
5. Accept `commandSender: HostCommandSender?` for config.patch
6. Add "Save" button per section that sends config.patch commands
7. Add explanatory footnotes about token security

**Files:** New `native/macos/.../SettingsChannelsTab.swift`

**Dependencies:** None (parallel with Tasks 1-3)

---

### Task 5 — Wire SettingsChannelsTab into SettingsView (15 min)

**Goal:** Add the Channels tab to the settings TabView.

**Scope:** `SettingsView.swift`

**Subtasks:**
1. Add `SettingsChannelsTab(commandSender: commandSender)` as a new tab after Tools
2. Use `Label("Channels", systemImage: "bubble.left.and.bubble.right")` for the tab item
3. Verify tab ordering: General, Models, Tools, Channels, About, (Developer)

**Files:** `native/macos/.../SettingsView.swift`

**Dependencies:** Task 4

---

### Task 6 — Handle channel config.patch keys in Rust (30 min)

**Goal:** Rust backend accepts `config.patch` for channel configuration keys.

**Scope:** `src/host/handler.rs`

**Subtasks:**
1. Add config.patch handlers for:
   - `channels.enabled` (bool)
   - `channels.discord.bot_token` (string)
   - `channels.discord.guild_id` (string, optional)
   - `channels.discord.allowed_channel_ids` (array of strings)
   - `channels.whatsapp.access_token` (string)
   - `channels.whatsapp.phone_number_id` (string)
   - `channels.whatsapp.verify_token` (string)
   - `channels.whatsapp.allowed_numbers` (array of strings)
2. For Discord/WhatsApp, create the config struct if None, then set the field
3. Log each change at info level
4. Persist changes by calling `save_config()` if it exists, or document TODO

**Files:** `src/host/handler.rs`

**Dependencies:** None (parallel with Tasks 4-5)

---

### Task 7 — Remove CameraSkill from builtins (15 min)

**Goal:** Remove false CameraSkill claim since no camera tool implementation exists.

**Scope:** `src/skills/builtins.rs`

**Subtasks:**
1. Remove `CameraSkill` definition (the `define_skill!` block at line 115-124)
2. Remove `Box::new(CameraSkill)` from `builtin_skills()` (line 147)
3. Run `cargo check` and `cargo test` to verify no references break
4. If `PermissionKind::Camera` is now unused, leave it — it may be used later

**Files:** `src/skills/builtins.rs`

**Dependencies:** None (independent)

---

### Task 8 — Build verification and cleanup (15 min)

**Goal:** Verify everything compiles and tests pass.

**Scope:** Both Swift and Rust

**Subtasks:**
1. Run `swift build --package-path native/macos/FaeNativeApp` — zero errors
2. Run `cargo check` — zero errors
3. Run `cargo clippy --all-targets -- -D warnings` — zero warnings
4. Run `cargo test` — all pass
5. Run `cargo fmt --all -- --check` — clean

**Files:** None (verification only)

**Dependencies:** All tasks

---

## Dependency Graph

```
Task 1 (Tools tab Swift)
    └── Task 2 (Wire into SettingsView)

Task 3 (tool_mode Rust handler)    — independent

Task 4 (Channels tab Swift)
    └── Task 5 (Wire into SettingsView)

Task 6 (channel config.patch Rust) — independent

Task 7 (Remove CameraSkill)        — independent

Task 8 (Build verification)        — depends on all
```

Tasks 1, 3, 4, 6, 7 can be started in parallel.
Task 2 requires Task 1. Task 5 requires Task 4.
Task 8 requires all tasks.

---

## Files Changed

| File | Tasks |
|------|-------|
| New `native/.../SettingsToolsTab.swift` | 1 |
| New `native/.../SettingsChannelsTab.swift` | 4 |
| `native/.../SettingsView.swift` | 2, 5 |
| `src/host/handler.rs` | 3, 6 |
| `src/skills/builtins.rs` | 7 |

---

## Acceptance Criteria

- [ ] Settings window has Tools tab with tool mode picker
- [ ] Changing tool mode sends config.patch to Rust backend
- [ ] Rust backend updates AgentToolMode from config.patch
- [ ] Settings window has Channels tab with Discord/WhatsApp forms
- [ ] Discord section: bot token, guild ID, allowed channels
- [ ] WhatsApp section: access token, phone number ID, verify token, allowed numbers
- [ ] Channel config changes sent via config.patch
- [ ] CameraSkill removed from builtin_skills()
- [ ] `cargo check`, `cargo clippy`, `cargo test` all pass
- [ ] `swift build` passes

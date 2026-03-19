# Phase 1.2: FaeSkill Trait + Built-in Skill Definitions

## Goal
Create the `FaeSkill` trait that defines a permission-gated skill, and implement
built-in skill definitions for each system capability. Skills check their
required permissions against the `PermissionStore` and only inject prompt
fragments when active.

## Tasks

### Task 1: Convert `src/skills.rs` to module directory
Move `src/skills.rs` → `src/skills/mod.rs` preserving all existing code.
Verify `cargo check` passes with zero changes to public API.

**Files:** `src/skills.rs` → `src/skills/mod.rs`

### Task 2: Create `FaeSkill` trait in `src/skills/trait_def.rs`
Define the trait with: `name()`, `description()`, `required_permissions()`,
`is_available()` (default impl checking PermissionStore), `prompt_fragment()`.
Add `SkillSet` type that holds all registered skills and can query
available skills given a PermissionStore.

**Files:** `src/skills/trait_def.rs` (new)

### Task 3: Create built-in skill definitions
Implement 9 built-in skills: Calendar, Contacts, Mail, Reminders, Files,
Notifications, Location, Camera, DesktopAutomation. Each struct implements
`FaeSkill` with appropriate permission requirements and prompt fragments.
Add `builtin_skills()` constructor in builtins module.

**Files:** `src/skills/builtins.rs` (new)

### Task 4: Unit tests for trait + builtins
Test: default availability with empty store, availability after granting
required permissions, unavailability when permission denied, prompt fragment
non-empty for all builtins, SkillSet filtering.

**Files:** `src/skills/trait_def.rs` (test module), `src/skills/builtins.rs` (test module)

### Task 5: Integration test — permission grant activates skills
End-to-end test: create PermissionStore, grant specific permissions, verify
correct subset of skills report as available. Verify skill prompt fragments
are only collected for available skills.

**Files:** `tests/permission_skill_gate.rs` (new)

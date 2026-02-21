# Phase 8.6: Skill Generator Pipeline

**Goal**: LLM-driven skill generation using the LATM (Language Agent Tool Making) pattern.
Fae can generate a working Python skill for any API from a plain-English request.

---

## Architecture

```
User intent ("send email via SendGrid")
    │
    ▼
SkillGeneratorPipeline::generate(intent)
    │
    ├─ 1. Check discovery index for existing matches
    │
    ├─ 2. Create staging directory (tempdir)
    │
    ├─ 3. Run LLM AgentLoop with LATM system prompt
    │     - Tools: write_skill_file, validate_manifest, validate_script
    │     - LLM generates manifest.toml + skill.py via tool calls
    │
    ├─ 4. Validate staged output
    │     - manifest.toml parses and validates
    │     - Entry script exists with valid PEP 723 metadata
    │     - Script has proper JSON-RPC 2.0 handler structure
    │
    ├─ 5. Preview proposal to caller (SkillProposal struct)
    │     - Caller can approve or reject
    │
    ├─ 6. Install via python_lifecycle::install_python_skill()
    │
    ├─ 7. Test handshake (advance to Testing, spawn runner)
    │
    └─ 8. Index in discovery (embed + index_skill)
```

---

## Task 1: SkillProposal & Generator Types

**File**: `src/skills/skill_generator.rs` (NEW)

Define the core types for the generator pipeline:

```rust
pub struct SkillProposal {
    pub skill_id: String,
    pub name: String,
    pub description: String,
    pub manifest_toml: String,   // raw TOML content
    pub script_source: String,   // raw Python source
    pub credentials: Vec<CredentialSchema>,
    pub dependencies: Vec<String>,  // from PEP 723
    pub staging_dir: PathBuf,
}

pub enum GeneratorOutcome {
    Proposed(SkillProposal),
    ExistingMatch { skill_id: String, name: String, score: f32 },
    Failed { reason: String },
}

pub struct SkillGeneratorConfig {
    pub max_llm_turns: usize,       // default 8
    pub max_test_rounds: usize,     // default 4
    pub discovery_threshold: f32,   // default 0.85 (skip if existing skill matches)
}
```

Add tests for type construction and defaults.

**Files**: `src/skills/skill_generator.rs`, `src/skills/mod.rs`

---

## Task 2: LATM System Prompt & Template Generation

**File**: `src/skills/skill_generator.rs`

Add the LATM system prompt template and the `build_generation_prompt()` function:

- System prompt instructs the LLM to generate:
  1. A `manifest.toml` following `PythonSkillManifest` schema
  2. A PEP 723 Python script with JSON-RPC 2.0 handler
- Include example manifest and script templates in the prompt
- `build_generation_prompt(intent: &str) -> String` combines user intent with structural requirements

The prompt should reference:
- Valid manifest fields (id, name, version, description, entry_file, credentials)
- PEP 723 inline metadata format
- JSON-RPC 2.0 stdio protocol (methods: handshake, invoke, shutdown)

**Files**: `src/skills/skill_generator.rs`

---

## Task 3: Staging Validation Logic

**File**: `src/skills/skill_generator.rs`

Implement validation functions that check staged output before proposing:

```rust
pub fn validate_staged_skill(staging_dir: &Path) -> Result<SkillProposal, PythonSkillError>
```

Steps:
1. Load and validate `manifest.toml` via `PythonSkillManifest::load_from_dir()`
2. Read entry script, verify it exists and is non-empty
3. Parse PEP 723 metadata via `parse_inline_metadata()`
4. Verify script contains JSON-RPC handler markers (basic text checks)
5. Validate skill_id via `validate_skill_id()`
6. Build and return `SkillProposal`

Add thorough unit tests with tempdir fixtures.

**Files**: `src/skills/skill_generator.rs`

---

## Task 4: SkillGeneratorPipeline Core

**File**: `src/skills/skill_generator.rs`

Implement the main pipeline struct and `generate()` method:

```rust
pub struct SkillGeneratorPipeline {
    config: SkillGeneratorConfig,
}

impl SkillGeneratorPipeline {
    pub fn new(config: SkillGeneratorConfig) -> Self;

    /// Generate a skill proposal from a plain-English intent.
    /// Does NOT install — returns a SkillProposal for caller approval.
    pub fn generate(
        &self,
        intent: &str,
        staging_dir: &Path,
    ) -> Result<GeneratorOutcome, PythonSkillError>;
}
```

The `generate()` method:
1. Creates staging directory structure
2. Writes manifest.toml from LLM output (or template)
3. Writes skill script from LLM output (or template)
4. Calls `validate_staged_skill()`
5. Returns `GeneratorOutcome::Proposed(proposal)`

For this task, use **template-based generation** (not actual LLM calls).
The template generates a well-formed skill from the intent string.
Actual LLM integration comes in a later phase when the agent loop is wired.

Add unit tests for the generate flow.

**Files**: `src/skills/skill_generator.rs`

---

## Task 5: Install & Index from Proposal

**File**: `src/skills/skill_generator.rs`

Implement the post-approval flow:

```rust
impl SkillGeneratorPipeline {
    /// Install an approved proposal and index it for discovery.
    pub fn install_proposal(
        &self,
        proposal: &SkillProposal,
        python_skills_dir: &Path,
    ) -> Result<PythonSkillInfo, PythonSkillError>;
}
```

Steps:
1. Copy staging dir contents to `python_skills_dir/{skill_id}/`
2. Call `install_python_skill_at()` (or direct file operations)
3. Return `PythonSkillInfo`

Also add:
```rust
pub fn index_proposal(
    index: &SkillDiscoveryIndex,
    proposal: &SkillProposal,
    embedding: &[f32],
) -> Result<(), PythonSkillError>;
```

Tests: install from staging → verify files on disk, index → verify searchable.

**Files**: `src/skills/skill_generator.rs`

---

## Task 6: Host Command Wiring

**Files**: `src/host/contract.rs`, `src/host/channel.rs`, `src/host/handler.rs`

Add two new host commands:

1. `skill.generate` — Trigger generation from intent
   - Payload: `{ "intent": "...", "confirm": false }`
   - If `confirm: false`: returns proposal preview
   - If `confirm: true`: installs and indexes

2. `skill.generate.status` — Query generation status (for async flows)
   - Payload: `{ "skill_id": "..." }`
   - Returns status of last generation attempt

Wire into:
- `CommandName` enum variants
- `as_str()` / `parse()` implementations
- `route()` dispatch in `HostCommandServer`
- `DeviceTransferHandler` trait methods (default stubs)
- `FaeDeviceTransferHandler` handler implementations

**Files**: `src/host/contract.rs`, `src/host/channel.rs`, `src/host/handler.rs`

---

## Task 7: Integration Tests

**File**: `tests/python_skill_generator.rs` (NEW)

End-to-end tests:

1. `generate_proposal_from_intent` — generate → validate proposal fields
2. `generate_returns_existing_match` — pre-index a skill, generate same intent → ExistingMatch
3. `install_proposal_creates_files` — generate → install → verify manifest + script on disk
4. `index_proposal_makes_searchable` — generate → install → index → search returns match
5. `invalid_intent_returns_error` — empty intent → appropriate error
6. `host_command_skill_generate` — send command envelope → get proposal response

**Files**: `tests/python_skill_generator.rs`

# Phase 4.3: App Integration & Release

**Milestone**: 4 — Observability & Release
**Status**: In Progress
**Total Tasks**: 8

## Overview
Final phase of the fae_llm module project. Integration with the main FAE app, comprehensive documentation, and release readiness validation.

---

## Task 1: App Config Integration Tests
**Goal**: Verify fae_llm config can be updated safely from app menu without data loss.

**Acceptance Criteria**:
- Test round-trip: load default config → modify via ConfigService::update_* → persist → reload → verify preservation
- Test comment preservation: load config with comments → update → verify comments preserved
- Test unknown field preservation: load config with extra fields → update → verify unknown fields preserved
- Test partial updates: provider update, model update, tool mode change
- Test validation: invalid provider config, invalid model tier, invalid secret ref
- All tests pass with zero warnings

**Files**:
- `tests/llm_config_integration.rs` (new)

---

## Task 2: TOML Round-Trip Preservation Tests
**Goal**: Comprehensive validation of toml_edit round-trip safety.

**Acceptance Criteria**:
- Test preserves inline comments: `max_tokens = 4096  # override default`
- Test preserves block comments: `# OpenAI Configuration` above provider block
- Test preserves formatting: spacing, newlines, quote style
- Test preserves key ordering: fields in original order after update
- Test preserves unknown sections: custom user sections not touched
- Test handles edge cases: empty tables, arrays of tables, nested tables
- Property tests with proptest for randomized TOML structures
- All tests pass with zero warnings

**Files**:
- `tests/llm_toml_roundtrip.rs` (new)

---

## Task 3: Operator Documentation
**Goal**: Complete guide for system operators deploying and configuring fae_llm.

**Acceptance Criteria**:
- Configuration reference: all config fields with descriptions and examples
- Provider setup guides: OpenAI, Anthropic, z.ai, MiniMax, DeepSeek, local endpoints
- Secret management: env, literal, command, keychain modes with security recommendations
- Tool mode configuration: read_only vs full, security implications
- Local endpoint probing: health check, model discovery, troubleshooting
- Session persistence: storage location, cleanup, backup
- Tracing and metrics: enabling structured logging, custom metrics collectors
- Troubleshooting guide: common errors with solutions
- Clear, actionable, complete

**Files**:
- `src/fae_llm/docs/OPERATOR_GUIDE.md` (new)

---

## Task 4: Developer Documentation
**Goal**: API reference and architecture overview for developers integrating fae_llm.

**Acceptance Criteria**:
- Architecture overview: module structure, data flow, key abstractions
- API reference: ConfigService, AgentLoop, ConversationContext, ToolRegistry, ProviderAdapter
- Event model: LlmEvent streaming, event types, accumulation patterns
- Error handling: FaeLlmError codes, retry policies, circuit breakers
- Custom provider guide: implementing ProviderAdapter, normalization requirements
- Custom tool guide: implementing Tool trait, schema validation
- Session management: persistence, resume, continuation
- Testing guide: unit tests, integration tests, mocking providers
- Code examples for common use cases
- Clear, complete, accurate

**Files**:
- `src/fae_llm/docs/DEVELOPER_GUIDE.md` (new)
- `src/fae_llm/docs/ARCHITECTURE.md` (new)

---

## Task 5: Module Public API Audit
**Goal**: Ensure clean, minimal, stable public API surface.

**Acceptance Criteria**:
- Review `mod.rs` public exports — all exports documented and necessary
- Review module visibility — no unintended `pub` items
- Review trait bounds — all trait objects safe and documented
- Review error variants — all error codes stable and documented
- Review config schema — all fields documented with serde defaults
- Review type aliases — all public type aliases have docs
- Zero missing docs warnings
- Zero unused exports
- Zero unnecessary `pub(crate)` that should be private

**Files**:
- `src/fae_llm/mod.rs` (review and update)
- All `src/fae_llm/*/mod.rs` files (review and update)

---

## Task 6: Release Candidate Validation
**Goal**: Full build and test verification across all features.

**Acceptance Criteria**:
- `just fmt-check` passes (all code formatted)
- `just lint` passes (zero clippy warnings)
- `just build` passes (debug build, all features)
- `just build-release` passes (release build, all features)
- `just test` passes (all tests including integration tests)
- `just doc` passes (zero doc warnings, all public items documented)
- `just panic-scan` passes (no .unwrap/.expect/panic!/todo! in production code)
- Verify test count ≥ 1474 (no regressions)
- Verify zero compilation warnings
- Verify zero unsafe code in fae_llm module (unless explicitly reviewed)

**Files**:
- N/A (validation only)

---

## Task 7: Final Integration Smoke Test
**Goal**: Verify all fae_llm subsystems work together end-to-end.

**Acceptance Criteria**:
- Test creates an integration test that:
  - Loads default config
  - Creates OpenAI and Anthropic adapters
  - Creates AgentLoop with ToolRegistry (all 4 tools)
  - Runs multi-turn conversation with tool calls (read, bash, edit, write)
  - Persists session to FsSessionStore
  - Resumes session and continues conversation
  - Switches providers mid-conversation
  - Validates tracing spans emitted
  - Validates metrics collected
  - Validates secret redaction in logs
- Test uses mock providers to avoid real API calls
- Test passes consistently
- Zero warnings

**Files**:
- `tests/llm_end_to_end.rs` (new)

---

## Task 8: Release Readiness Checklist
**Goal**: Final verification of all deliverables and documentation.

**Acceptance Criteria**:
- Version number updated in relevant locations (if needed)
- All documentation reviewed and accurate (operator + developer guides)
- All integration tests pass (config, TOML, E2E)
- All quality gates pass (fmt, lint, build, test, doc, panic-scan)
- Changelog entries accurate and complete
- No TODO/FIXME comments in fae_llm module
- No dead code in fae_llm module
- All public APIs have examples in docs
- Release notes prepared summarizing fae_llm module features
- Milestone 4 marked complete in STATE.json

**Files**:
- `.planning/STATE.json` (update to milestone_complete)
- `.planning/progress.md` (update with Phase 4.3 completion)
- `CHANGELOG.md` (if present, update)

---

## Success Metrics
- 8/8 tasks complete
- All new integration tests pass
- Operator and developer documentation complete
- Zero warnings, zero test failures
- fae_llm module ready for production use
- Project milestone 4 complete

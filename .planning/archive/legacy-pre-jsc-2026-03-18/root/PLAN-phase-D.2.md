# Phase D.2: Contract & Test Fixes (P2)

## Goal
Fix three P2 issues: ConversationTrigger timeout ignored, CredentialManager::delete not idempotent, soul_version test flakiness.

## Context
- ConversationTrigger.timeout_secs exists but isn't wired through to execution (hardcoded 300s)
- CredentialManager::delete trait contract says Ok(()) for missing, but backends return NotFound
- soul_version tests share global ~/.fae/soul_versions/ directory causing parallel failures

## Tasks

### Task 1: Wire ConversationTrigger timeout through to execution
**Files**: `src/pipeline/messages.rs`, `src/scheduler/executor_bridge.rs`, `src/startup.rs`

- Add `timeout_secs: Option<u64>` field to ConversationRequest
- In executor_bridge.rs: pass trigger.timeout_secs to ConversationRequest construction
- In startup.rs: use request.timeout_secs.unwrap_or(300) instead of hardcoded Duration::from_secs(300)
- Tests: verify custom timeout propagates, verify default 300s when None

### Task 2: Fix CredentialManager::delete to be idempotent
**Files**: `src/credentials/keychain.rs`, `src/credentials/encrypted.rs`

- In keychain.rs (~line 82-86): catch errSecItemNotFound and return Ok(()) instead of Err(NotFound)
- In encrypted.rs (~line 77-79): catch keyring::Error::NoEntry and return Ok(()) instead of Err(NotFound)
- Update tests to verify delete returns Ok(()) for non-existent credentials
- Tests: delete non-existent returns Ok(()), delete existing returns Ok(()), delete with real error returns Err

### Task 3: Fix soul_version tests for parallel safety
**Files**: `src/soul_version.rs`

- Add a test helper that creates isolated temp directories using tempfile::tempdir()
- Modify test functions to use per-test temporary directories instead of shared ~/.fae/soul_versions/
- If soul_version functions use a hardcoded path, add a parameter or test-only override
- Consider a #[cfg(test)] function to set a custom versions_dir
- Ensure ALL soul_version tests pass reliably in parallel
- Tests: run the previously flaky tests 3x to verify stability

### Task 4: Integration tests and final verification
**Files**: various

- Run full test suite with --no-fail-fast and verify 0 failures (soul_version tests included)
- Run cargo clippy --all-features --all-targets -- -D warnings
- Run cargo fmt --all -- --check
- Verify all 5 original findings are resolved
- Update progress.md with phase completion

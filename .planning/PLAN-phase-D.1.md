# Phase D.1: Critical Fixes (P0 + P1)

## Goal
Fix the two critical bugs: keychain credentials resolving to empty strings (P0), and scheduler conversation execution being a placeholder (P1).

## Context
- CredentialRef::resolve_plaintext() returns "" for Keychain variants — all keychain-backed auth silently fails
- Callers: api.rs, discord.rs, whatsapp.rs, gateway.rs all call resolve_plaintext()
- CredentialManager::retrieve() exists and works, but callers don't use it
- Scheduler conversation handler in startup.rs returns canned "coming soon" response
- ConversationTrigger payload schema exists, executor bridge works, but execution is placeholder

## Tasks

### Task 1: Add async credential resolution to CredentialRef
**Files**: `src/credentials/types.rs`, `src/credentials/mod.rs`

Make credential resolution work for all variants, not just Plaintext.
- Add `pub async fn resolve(&self, manager: &dyn CredentialManager) -> Result<String, CredentialError>` method to CredentialRef
- For Plaintext: return value directly
- For Keychain { service, account }: call manager.retrieve(service, account)
- For None: return CredentialError::NotFound
- Deprecate `resolve_plaintext()` with `#[deprecated]` attribute and doc comment
- Tests: resolve Plaintext returns value, resolve None returns error, resolve Keychain with mock manager

### Task 2: Update LLM API caller to use async credential resolution
**Files**: `src/llm/api.rs`

Replace resolve_plaintext() call with proper async resolution.
- Find the call site around line 338 where api_key uses resolve_plaintext()
- Replace with resolve() using the credential manager
- Thread CredentialManager (or resolved credentials) through to the call site
- If CredentialManager isn't available in scope, use LoadedCredentials pattern from credentials module
- Ensure error propagates properly (not silently returning "")
- Tests: verify API key resolution with keychain ref doesn't return empty string

### Task 3: Update channel adapters to use async credential resolution
**Files**: `src/channels/discord.rs`, `src/channels/whatsapp.rs`, `src/channels/gateway.rs`, `src/channels/mod.rs`

Replace all resolve_plaintext() calls in channel code with proper resolution.
- Discord (line ~22): bot_token resolve_plaintext() → resolve()
- WhatsApp (lines ~22, ~24): access_token and verify_token resolve_plaintext() → resolve()
- Gateway (line ~54): bearer token resolve_plaintext() → resolve()
- Thread credential manager or pre-resolved credentials to channel startup
- Consider resolving credentials in start_runtime() before passing to adapters
- Tests: verify channel credential resolution doesn't return empty for keychain refs

### Task 4: Implement real scheduler conversation execution
**Files**: `src/startup.rs`

Replace placeholder handler with actual conversation execution.
- Replace execute_scheduled_conversation() around line 747 with real implementation
- Load system prompt (use existing prompt loading from pipeline)
- Create conversation with the task's prompt text
- Use existing fae_llm agent loop or coordinator to execute
- If full agent loop is too complex, use a simpler single-turn LLM call
- Pass system_addon from ConversationTrigger if present
- Return actual LLM response text
- Map errors to appropriate TaskResult
- Tests: verify handler doesn't return "coming soon", verify error handling

### Task 5: Integration tests and verification
**Files**: `src/credentials/types.rs`, `src/startup.rs`

Validate both fixes work end-to-end.
- Integration test: create CredentialRef::Keychain, mock manager, resolve returns real value
- Integration test: resolve_plaintext() is deprecated (compile warning test or doc test)
- Integration test: scheduled conversation with ConversationTrigger payload executes (mock LLM)
- Run full test suite to verify no regressions
- Verify zero clippy warnings, zero compilation errors

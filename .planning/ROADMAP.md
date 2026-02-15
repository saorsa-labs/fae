# Roadmap: fae-bugfixes-v0.3.1

## Overview
Fix 5 confirmed findings from v0.3.0 production hardening review. P0/P1 credential and scheduler issues first, then P2 contract/test fixes.

## Milestone D: Post-Release Bug Fixes

### Phase D.1: Critical Fixes (P0 + P1)
- **Finding 1 (P0)**: Keychain credentials resolve to empty strings — all auth fails silently
- **Finding 2 (P1)**: Scheduler conversation execution is a placeholder — returns canned response

### Phase D.2: Contract & Test Fixes (P2)
- **Finding 3 (P2)**: ConversationTrigger.timeout_secs is ignored — hardcoded 300s
- **Finding 4 (P2)**: CredentialManager::delete returns NotFound instead of Ok(()) for missing
- **Finding 5 (P2)**: soul_version tests are parallel-unsafe/flaky

## Quality Gates
- Zero compilation errors/warnings
- Zero clippy violations
- All tests pass (including previously flaky ones)
- No .unwrap()/.expect() in production code

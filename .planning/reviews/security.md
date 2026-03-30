# Security Review

## Reviewer: Security Scanner
## Scope: Phase 1.1 — LoRA Adapter Loading

### Findings

**Path traversal risk (SHOULD FIX - 1 vote):**
`ModelManager` uses `config.training.personalAdapterPath` (a user-supplied String) directly in `URL(fileURLWithPath: adapterPath)` without path normalization or validation. While `PathPolicy` exists in the codebase for write-path validation, it is not applied here. A crafted config value like `../../../../etc/passwd` would be resolved by the filesystem (though `LoRAContainer.from` would fail trying to parse it as a JSON adapter config). Low exploitability (requires compromising config), but should use `URL.standardizedFileURL` or validate against a known safe prefix (e.g., must be under `~/Library/Application Support/fae/` or `~/.fae-forge/`).

**PASS** - No network access introduced.
**PASS** - No credentials or secrets in new code.
**PASS** - No `unsafe` code introduced.
**PASS** - Adapter load is gated behind `adapterAutoLoadEnabled: Bool = false` — opt-in, safe default.
**PASS** - `FileManager.default.fileExists` check before loading prevents crashes on missing paths.
**PASS** - `NSLog` logging of adapter path is acceptable (local system log, not transmitted).
**PASS** - Actor isolation on `MLXLLMEngine` prevents concurrent adapter state mutation.

### Verdict: PASS with one path validation note

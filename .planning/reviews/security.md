# Security Review — Phase 1.1

## Reviewer: Security Scanner
## Focus: Data exposure, injection, provenance integrity

### Findings

**FINDING 1 — LOW: providerKind is a raw String, not an enum**
- WorkWithFaeConversationMessage stores `providerKind: String?` as free-form text
- Values like "consensus-synthesis" are magic strings not validated against CoworkLLMProviderKind
- A corrupted/malicious workspace JSON could inject arbitrary providerKind values
- No impact today (field is display/metadata only), but if future code branches on this value, injection risk exists
- Recommendation: Consider storing as CoworkLLMProviderKind enum or validating on decode
- Vote: MINOR

**FINDING 2 — LOW: modelID is unvalidated free-form string**  
- modelID: String? persisted to JSON and reloaded with no validation
- Same injection concern as providerKind if future code uses this for routing decisions
- Vote: MINOR

**FINDING 3 — PASS: No credential or sensitive data exposure**
- modelID/providerKind are metadata identifiers only, not secrets
- No API keys, tokens, or user PII in new fields
- Codable encoding does not expose sensitive data

**FINDING 4 — PASS: MessageOverride does not introduce privilege escalation**
- MessageOverride is defined but not wired into any execution path
- When wired, systemPromptOverride could be a concern (injection of instructions)
- Current state: safe (no-op)

### Summary
No critical security issues. Two minor concerns about unvalidated string fields.

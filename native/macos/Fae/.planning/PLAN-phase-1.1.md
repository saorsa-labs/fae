# Phase 1.1: Delete Source Files + Extract VLM Sanitizer

## Task 1: Extract sanitizeVLMPrompt from InputSanitizer to MLXVLMEngine
- Read `Sources/Fae/Tools/InputSanitizer.swift` — find `sanitizeVLMPrompt()` and its VLM injection patterns array
- Copy the method and patterns to `Sources/Fae/ML/MLXVLMEngine.swift` as a `private static` method
- Update the call at MLXVLMEngine.swift (search for `InputSanitizer.sanitizeVLMPrompt`) to use the local method
- Verify: `swift build` passes

## Task 2: Remove InputSanitizer calls from BuiltinTools
- Read `Sources/Fae/Tools/BuiltinTools.swift`
- Remove the `InputSanitizer.sanitizeContentInput(content)` call (around line 63 in the write tool)
- Remove the `InputSanitizer.classifyBashCommand(command)` call (around line 141 in the bash tool) — this fed the approval card description, which is being deleted
- For the write tool: just pass content through without sanitization (owner is trusted)
- For the bash tool: remove the classification logic that was only used for approval card descriptions
- Verify: `swift build` passes

## Task 3: Remove NetworkTargetPolicy call from BuiltinTools fetch_url
- Read `Sources/Fae/Tools/BuiltinTools.swift` — find the `NetworkTargetPolicy.blockedReason(urlString:)` call (around line 656 in the fetch_url tool)
- Remove that call and the guard/if that blocks based on it — owner should be able to fetch any URL
- Keep `Sources/Fae/Tools/NetworkTargetPolicy.swift` itself (used by MCPServerConfig and SkillManager)
- Verify: `swift build` passes

## Task 4: Delete 9 source files
- Delete these files:
  - `Sources/Fae/Tools/TrustedActionBroker.swift`
  - `Sources/Fae/Tools/CapabilityTicket.swift`
  - `Sources/Fae/Tools/ToolRateLimiter.swift`
  - `Sources/Fae/Tools/ToolRiskPolicy.swift`
  - `Sources/Fae/Tools/OutboundExfiltrationGuard.swift`
  - `Sources/Fae/Tools/ApprovedToolsStore.swift`
  - `Sources/Fae/Core/ToolToggleStore.swift`
  - `Sources/Fae/Agent/ApprovalManager.swift`
  - `Sources/Fae/Tools/InputSanitizer.swift` (VLM sanitizer already extracted in Task 1)
- This WILL cause compile errors in many files. That is expected and intentional.
- The compile errors are resolved in Phase 1.2, 1.3, and Milestone 2.
- Do NOT try to fix compile errors in this task — just delete the files.
- Verify: files are deleted (ls to confirm)

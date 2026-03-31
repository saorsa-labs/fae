# Fae Permissions Great Purge

> Voice identity as the only gate. Remove 22-layer enterprise security stack.
> Keep: DamageControlPolicy, ReversibilityEngine, voice identity, CoWork gating.

## Milestone 1: Delete & Refactor

### Phase 1.1: Delete Source Files + Extract VLM Sanitizer
- Extract `sanitizeVLMPrompt()` from InputSanitizer to MLXVLMEngine
- Remove `sanitizeContentInput()` call from BuiltinTools
- Remove `classifyBashCommand()` call from BuiltinTools
- Delete 9 source files: TrustedActionBroker, CapabilityTicket, ToolRateLimiter, ToolRiskPolicy, OutboundExfiltrationGuard, ApprovedToolsStore, ToolToggleStore, ApprovalManager, InputSanitizer
- Remove `NetworkTargetPolicy.blockedReason()` call from BuiltinTools fetch_url (keep file for MCP/skills)

### Phase 1.2: Refactor ApprovalOverlay into InputOverlay
- Extract InputOverlayController from ApprovalOverlayController (keep activeInput, inputRespond)
- Extract InputOverlayView from ApprovalOverlayView (keep InputCard, FormInputCard)
- Delete approval card views (ApprovalCard, BatchApprovalCard, disaster overlay)
- Update FaeApp.swift and ContentView.swift

### Phase 1.3: Simplify ToolExecutor
- Remove actionBroker, rateLimiter, outboundGuard from constructor
- Rewrite executeInner() to 3-step flow: voice check -> DamageControlPolicy -> execute
- Keep: plugin hooks, ReceiptStore, SecurityEventLogger, ToolAnalytics, timeout, narration, TillDone gate
- Add rescue mode check (read-only tools only)

## Milestone 2: Simplify Pipeline & Secondary Files

### Phase 2.1: Simplify PipelineCoordinator
- Remove activeCapabilityTicket property + 13 nil-assignment points
- Remove CapabilityTicketIssuer.issue() calls
- Remove capabilityTicketOverride from executeTool() signature
- Remove actionBroker property + DefaultTrustedActionBroker instantiation
- Remove rateLimiter and outboundGuard properties
- Update ToolExecutor instantiation (fewer params)

### Phase 2.2: Simplify Secondary Files
- ToolExecutorContext: remove capabilityTicket, hasCapabilityTicketForTool
- JSCRuntime + JSCToolBridge: remove CapabilityTicket, add direct allowedTools enforcement
- JSCDeveloperHarness: remove AllowAllBroker, ToolRateLimiter, OutboundExfiltrationGuard
- CapabilitySnapshotService: remove ApprovedToolsStore refs
- FaeCore: remove ApprovedToolsStore refs, TrustedActionBroker refs
- FaeConfig: remove toolMode enum cases, keep rescue-mode flag
- ToolRegistry: remove mode filtering, remove ToolToggleStore check, add toolsForSpeaker()
- SafeBashExecutor: remove 13 blocked patterns + 3 regex denials, keep process isolation
- DamageControlPolicy: remove zero-access paths for local model (keep nonLocal only)
- PathPolicy: keep only system paths, remove dotfile/Fae-data blocking
- FaeScheduler: remove per-task allowlists, add 2nd-opinion gate for mutations

### Phase 2.3: Simplify Settings UI
- SettingsToolsTab: remove "Reset Approvals", remove ApprovedToolsStore refs
- SettingsPrivacySecurityTab: remove tool mode selector, per-tool toggles
- Other Settings*.swift: remove security toggle references

## Milestone 3: Tests & Documentation

### Phase 3.1: Update Tests
- DELETE 8 test files (TrustedActionBrokerTests, ScriptScopedTicketTests, ApprovalManagerTests, BatchApprovalTests, ToolApprovalRegressionTests, EndToEndApprovalProgressionTests, EndToEndAllowWithTransformTests, EndToEndOwnerSilentModeTests)
- UPDATE 12 test files (ToolExecutorTests, PipelineIntegrationTests, SecurityHardeningTests, JSC tests, CapabilitySnapshotServiceTests, SkillBypassRegressionTests, CoworkRemoteProviderTests, TestRuntimeHarness)
- ADD 5 new suites (SimplifiedToolExecution, GuestToolAccess, SchedulerFullAccess, OwnerDamageControl, CoWorkPreservedGating)

### Phase 3.2: Documentation & Migration
- Update CLAUDE.md tool security section (new 4-layer model)
- Update CLAUDE.md file inventory
- Update CLAUDE.md scheduler section
- Add migration cleanup: delete approved_tools.json, remove fae.disabledTools, delete outbound-recipients.json

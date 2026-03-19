# Phase 1.1: Extract ToolExecutor Actor

## Overview

Extract the ~600-line `executeTool` method from `PipelineCoordinator` into a standalone `ToolExecutor` actor that encapsulates all 8 security layers, approval flow, timeout/analytics, and result recording. `PipelineCoordinator` delegates to it. The JSC runtime (Phase 1.2) will reuse the same actor.

Pure refactor — zero behavior change.

## Key Files
- `Sources/Fae/Pipeline/PipelineCoordinator.swift` — `executeTool()` at line 8272
- `Sources/Fae/Tools/TrustedActionBroker.swift` — broker interface
- `Sources/Fae/Tools/DamageControlPolicy.swift` — pre-broker blocking
- `Sources/Fae/Tools/ToolRateLimiter.swift` — rate limiting
- `Sources/Fae/Tools/CapabilityTicket.swift` — ticket structure
- `Sources/Fae/Agent/ApprovalManager.swift` — approval flow
- `Sources/Fae/Tools/OutboundExfiltrationGuard.swift` — exfiltration check
- `Sources/Fae/Tools/SecurityEventLogger.swift` — audit logging

## Validation
```bash
cd native/macos/Fae && swift build && swift test
```

---

### Task 1: Define `ToolExecutorContext` — per-call input envelope

**Files**: `Sources/Fae/Tools/ToolExecutorContext.swift` (new)

**Description**:
Create a `Sendable` value type carrying every piece of per-call runtime state that `executeTool` currently reads from `PipelineCoordinator` instance fields:

- `toolMode: String`, `privacyMode: String`, `modelLocality: ModelLocality`
- `capabilityTicket: CapabilityTicket?`, `hasCapabilityTicketForTool: Bool`
- `explicitUserAuthorization: Bool`, `isOwner: Bool`, `livenessScore: Float?`
- `actionSource: ActionSource`, `proactiveContext: ProactiveRequestContext?`
- `visionEnabled: Bool`, `firstOwnerEnrollmentActive: Bool`
- `workflowTurnID: String?`, `traceToolCallID: String?`

Also define `ToolExecutorCallbacks` — a `Sendable` struct of closures for side effects:
- `onApprovalPending: @Sendable (Bool, Bool) async -> Void`
- `onVisionAutoEnabled: @Sendable () async -> Void`
- `onComputerUseStep: @Sendable () async -> Int`

**Tests**: Compile-time `Sendable` verification. Default init works.
**Acceptance**: `swift build` passes.

---

### Task 2: Define `ToolExecutorDelegate` protocol and `ToolExecutorResult`

**Files**: `Sources/Fae/Tools/ToolExecutorDelegate.swift` (new)

**Description**:
`ToolExecutorResult`: `result: ToolResult`, `approvedByUser: Bool`, `damageControlIntervened: Bool`.

`ToolExecutorDelegate` protocol:
- `func loadVLMIfNeeded(visionEnabled: Bool) async throws`
- `func speakDirect(_ text: String) async`

**Tests**: `Sendable` check. Mock implementation compiles.
**Acceptance**: `swift build` passes.

---

### Task 3: Create `ToolExecutor` actor skeleton

**Files**: `Sources/Fae/Tools/ToolExecutor.swift` (new)

**Description**:
Create `actor ToolExecutor` with stored dependencies matching PipelineCoordinator's current ownership: `registry`, `actionBroker`, `damageControlPolicy`, `rateLimiter`, `securityLogger`, `outboundGuard`, `approvalManager?`, `workflowTraceStore?`, `toolAnalytics?`, `debugConsole?`, `weak delegate`.

Stub `execute()` method. Move static helpers from PipelineCoordinator: `toolTimeoutSeconds(for:)`, `isSelfConfigReadAction(arguments:)`, `toolRequiresApproval(toolName:arguments:defaultRequiresApproval:)`, `buildApprovalDescription(toolName:reason:arguments:)`.

**Tests**: Instantiation with nil optionals. Static helpers return correct values.
**Acceptance**: `swift build` passes.

---

### Task 4: Pre-flight gates — mode, proactive, TillDone, computer-use

**Files**: `Sources/Fae/Tools/ToolExecutor.swift` (modify)

**Description**:
Implement first four guards (PipelineCoordinator lines 8288–8379): tool mode enforcement, proactive allowlist, TillDone hard gate, computer-use step limit (`maxComputerUseSteps = 10`).

**Tests**: `ToolExecutorPreflightTests.swift` — mode block, proactive block, computer-use limit.
**Acceptance**: `swift build` + tests pass.

---

### Task 5: Vision auto-enable, tool lookup, rate limit

**Files**: `Sources/Fae/Tools/ToolExecutor.swift` (modify)

**Description**:
Continue `execute()` (lines 8381–8441): vision auto-enable via callback, VLM loading via delegate, tool lookup, self-config read detection, rate limit check.

**Tests**: Unknown tool error, rate limit error, vision callback invocation.
**Acceptance**: `swift build` + tests pass.

---

### Task 6: Workflow trace recording

**Files**: `Sources/Fae/Tools/ToolExecutor.swift` (modify)

**Description**:
Private helpers: `recordToolCall(call:context:)` and `recordToolResult(call:context:result:approved:latencyMs:damageControlIntervened:)`. Call `workflowTraceStore?.appendStep(...)`. Context-mutation stays in PipelineCoordinator via `ToolExecutorResult` fields.

**Tests**: `ToolExecutorTraceTests.swift` — appends step when store non-nil, no-op when nil.
**Acceptance**: `swift build` + tests pass.

---

### Task 7: Security pipeline — DamageControl + OutboundGuard + Broker

**Files**: `Sources/Fae/Tools/ToolExecutor.swift` (modify)

**Description**:
Three-layer policy evaluation (lines 8443–8617): build `ActionIntent`, DamageControl `.block`/`.disaster`/`.confirmManual`, OutboundGuard, Broker, shadow mode bypass. Security logging.

**Tests**: `ToolExecutorSecurityTests.swift` — DC block, broker deny, broker allow, shadow mode.
**Acceptance**: `swift build` + tests pass. Existing `DamageControlPolicyTests` unchanged.

---

### Task 8: Approval gate

**Files**: `Sources/Fae/Tools/ToolExecutor.swift` (modify)

**Description**:
Approval/confirmation flow (lines 8619–8764): `callbacks.onApprovalPending`, `delegate?.speakDirect`, `approvalManager?.requestApproval`. Handle `.allow`, `.allowWithTransform`, `.confirm`, `.deny`.

**Tests**: `ToolExecutorApprovalTests.swift` — auto-approve, auto-deny, no manager, deny.
**Acceptance**: `swift build` + tests pass.

---

### Task 9: Extract `applySafetyTransform`

**Files**: `Sources/Fae/Tools/ToolExecutor.swift` (modify)

**Description**:
Move `applySafetyTransform` and `isSafeSkillName` from PipelineCoordinator to ToolExecutor.

**Tests**: Existing `EndToEndAllowWithTransformTests` pass unchanged.
**Acceptance**: `swift build` passes.

---

### Task 10: Execution with timeout + post-execution logging

**Files**: `Sources/Fae/Tools/ToolExecutor.swift` (modify)

**Description**:
Final `execute()` phase (lines 8766–8869): argument augmentation (`capability_ticket`, `enrollment_active`), `withThrowingTaskGroup` timeout, post-execution analytics, outbound send recording, workflow trace, return `ToolExecutorResult`.

**Tests**: `ToolExecutorExecutionTests.swift` — success, timeout, throw, argument injection.
**Acceptance**: `swift build` + tests pass.

---

### Task 11: Wire `PipelineCoordinator` → `ToolExecutor`

**Files**: `Sources/Fae/Pipeline/PipelineCoordinator.swift` (modify)

**Description**:
1. Add `private let toolExecutor: ToolExecutor` in `init()`
2. Remove now-duplicate dependencies (damageControlPolicy, rateLimiter, etc.)
3. Replace `executeTool(...)` body: build context → build callbacks → `toolExecutor.execute(...)` → apply side effects
4. Implement `ToolExecutorDelegate` — `loadVLMIfNeeded` → modelManager, `speakDirect` → self
5. Keep `static func toolTimeoutSeconds(for:)` forwarding to `ToolExecutor`

**Tests**: ALL existing tests must pass unchanged:
- `PipelineCoordinatorPolicyTests`
- `EndToEndApprovalFlowTests`
- `EndToEndAllowWithTransformTests`
- `GovernanceActionRoutingTests`

**Acceptance**: `swift build` zero warnings. `swift test` zero failures. Zero behavior change.

---

### Task 12: Integration harness — verify security layer order

**Files**: `Tests/HandoffTests/ToolExecutorTests.swift` (new)

**Description**:
End-to-end integration test exercising `ToolExecutor` in isolation:
1. Tool mode check fires before DC check
2. DC block fires before outbound guard
3. Rate limit fires before broker
4. Broker fires last
5. Happy path: low-risk tool with full-mode context → success

Use mock broker that records call order.

**Tests**: 6-8 test methods.
**Acceptance**: `swift build` + `swift test` pass. `just check` green.

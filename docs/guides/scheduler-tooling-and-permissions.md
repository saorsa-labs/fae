# Scheduler tooling + permission behavior (Swift runtime)

This note documents current scheduler and tool integration in the Swift app.

## Scheduler ownership

Scheduler authority lives in:

- `native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift`

`FaeCore` wires scheduler lifecycle on runtime start/stop and connects:

- persistence store (`SchedulerPersistenceStore`)
- optional speak handler (`PipelineCoordinator.speakDirect`)

## Scheduler tool integration

Scheduler tools write/read `~/Library/Application Support/fae/scheduler.json` and coordinate with runtime via notifications:

- `.faeSchedulerUpdate` → enable/disable task state
- `.faeSchedulerTrigger` → run task immediately

`FaeCore.observeSchedulerUpdates()` consumes both notifications and forwards to `FaeScheduler`.

## Permission layering

Tool execution in pipeline uses layered checks:

1. Voice-identity policy (`VoiceIdentityPolicy`)
2. Tool risk policy (`ToolRiskPolicy`)
3. Approval workflow (`ApprovalManager`) when required

This applies consistently across direct conversation and tool-follow-up turns.

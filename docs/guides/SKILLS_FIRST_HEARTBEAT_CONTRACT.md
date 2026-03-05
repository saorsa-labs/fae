# Skills-First Heartbeat Contract (v1)

This contract defines how Swift scheduler/runtime and skills coordinate proactive behavior.

## Goals

- Keep Swift minimal: scheduling, safety, consent, rendering.
- Keep skills in charge: what to teach, when to nudge, what to show.
- Support no-op heartbeats with explicit ack (`HEARTBEAT_OK`).

## Input Envelope

`HeartbeatRunEnvelope` (JSON):

- `schemaVersion`
- `runID`
- `timestampISO8601`
- `deliveryTarget` (`none`, `voice`, `canvas`, etc.)
- `quietMode`
- `checklist` (heartbeat checklist items)
- `recentContext` (high-signal context lines)
- `progress` (`CapabilityProgressState`)
- `ack` (`token`, `ackMaxChars`)

## Response Contract

Preferred format:

```xml
<heartbeat_result>{ ...json... }</heartbeat_result>
```

Decoded payload: `HeartbeatRunDecision`

- `status`: `ok | nudge | alert | teach`
- `message`: optional spoken text
- `nudgeTopic`: optional capability/topic
- `suggestedStage`: optional progression stage
- `canvasIntent`: optional typed canvas intent

No-op behavior:

- Returning `HEARTBEAT_OK`
- Or `HEARTBEAT_OK` prefix/suffix with short text (`<= ackMaxChars`)

is treated as a suppressed no-op.

## Progression Schema

`CapabilityProgressState`:

- `stage`: `discovering | guidedUse | habitForming | advancedAutomation | powerUser`
- `taughtCapabilities`: string[]
- `successfulNudges`: int
- `dismissedNudges`: int
- `lastNudgeAtISO8601`
- `lastNudgeTopic`
- `lastStageChangeAtISO8601`

## Canvas Intent (typed)

`HeartbeatCanvasIntent`:

- `kind` (e.g. `capability_card`, `mini_tutorial`, `chart`, `table`, `app_preview`)
- `payload` (string map consumed by trusted host templates)

No raw model HTML is trusted as authority.

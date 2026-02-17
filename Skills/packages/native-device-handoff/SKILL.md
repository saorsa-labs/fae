# Native Device Handoff

Use this skill for Apple-native session transfer and audio routing requests:

- move Fae from Mac to iPhone or Watch
- return Fae to Mac ("go home")
- continue voice input/output on the destination device after transfer

This skill is for native-device orchestration only. Keep scheduler authority in Rust backend. Keep UI native per platform.

## Intent triggers

Treat these as direct transfer intents:

- "move to my watch"
- "move to my phone"
- "move to my iphone"
- "move to mac"
- "go home"
- "back to mac"

Normalization rules:

- `phone`, `iphone` -> target `iphone`
- `watch`, `apple watch` -> target `watch`
- `mac`, `macbook`, `desktop`, `home` -> target `mac`

If target is unclear, ask exactly one short clarification question.

## Command contract

Use only these commands:

- `device.move` with payload `{ "target": "watch" | "iphone" | "mac" }`
- `device.go_home` with payload `{}`

Expect only these events:

- `device.transfer_requested`
- `device.home_requested`

Never invent alternate command names or payload keys.

## Runtime flow

1. Resolve intent target.
2. Send command (`device.move` or `device.go_home`) through host control plane.
3. Wait for command response envelope (`ok=true` required before user confirmation).
4. Confirm outcome in one short sentence.
5. If destination is `watch` or `iphone`, instruct user to foreground Fae companion if not already open.

Failure handling:

- Unsupported target: keep session on current device, tell user supported targets.
- Transport failure/timeouts: keep session local, offer retry.
- Any non-`ok` response: do not claim handoff happened.

## Native audio routing policy

After transfer request acceptance:

- use native mic capture APIs on destination device
- use native speaker/route picker controls for output path
- resume conversation only after destination audio session is ready

Never report "moved" or "audio switched" until native layer confirms both:

- destination app accepted transfer payload
- destination audio session is active

## Latency policy

Optimize for minimal handoff overhead:

- one command round-trip per transfer intent
- no phoneme/viseme stage for transfer acknowledgements
- orb state updates only (`idle/listening/thinking/speaking`) for visual feedback

If handoff is delayed, report "handoff pending" rather than stalling silently.

## UX guardrails

- require explicit user intent in the current turn for each transfer
- never auto-transfer during unrelated conversation
- do not transfer during privileged approval dialogs unless user repeats intent
- keep confirmations deterministic and concise

Suggested confirmations:

- "Moving Fae to your Watch now."
- "Moving Fae to your iPhone now."
- "Returning Fae to this Mac."

Suggested failure response:

- "I couldn't move devices yet; we stayed on this Mac. Want me to retry?"

## Engineering maintenance workflow

When changing this feature:

1. Update host command/event schema in `src/host/contract.rs`.
2. Update host channel routing in `src/host/channel.rs`.
3. Update macOS native parser/sender in `native/macos/FaeNativeApp`.
4. Update shared handoff types in `native/apple/FaeHandoffKit`.
5. Update iPhone/Watch receiver templates in `native/apple/FaeCompanion/Templates`.
6. Re-check transfer latency baseline.

## Validation checklist

- host contract tests pass (`tests/host_contract_v0.rs`)
- host channel tests pass (`tests/host_command_channel_v0.rs`)
- macOS native shell builds (`native/macos/FaeNativeApp`)
- Apple handoff contract tests pass (`native/apple/FaeHandoffKit`)
- latency p95 remains inside local IPC budget

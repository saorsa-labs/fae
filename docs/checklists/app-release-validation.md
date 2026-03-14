# Fae App Release Validation Contract

Last updated: March 14, 2026

This is the canonical end-to-end validation contract for shipping Fae.

Do not mark Fae, a model change, a prompt change, a routing change, a tool-policy change, or a UI refresh as release-ready unless this contract has been executed against the real app and the relevant scripted phases have passed.

If a capability exists in the product but is not covered by an automated or guided step below, add coverage in the same change before claiming production readiness.

## When this contract is mandatory

Run this full contract when any of the following changes:

- local text or vision model selection
- prompt templates, tool prompting, or tool repair logic
- voice capture, STT, wake logic, TTS, or playback timing
- permissions, approval popups, key input, or security/export review
- memory capture/recall or scheduler behavior
- skills management or Python-runtime integration
- Cowork routing, model switching, compare/fork, or remote-provider handling
- legacy dual-model or concierge compatibility changes
- settings that affect loaded models, policy, or diagnostics
- any release candidate build

## Required environment

1. Clean native build and real app launch with `just run-native` or `just rebuild`.
2. Test-server launch with `just test-serve`.
3. Chatterbox available for real audio playback on `http://127.0.0.1:8000`.
4. Screenshot evidence captured from the live app during validation.
5. Relevant `tests/comprehensive/specs/*.yaml` phases run and archived.

## Evidence required

For every release-validation run, retain:

- latest comprehensive JSON report from `tests/comprehensive/reports/`
- screenshots for startup, onboarding, permissions, main window, Cowork, and any failing state
- test-server evidence from `/status`, `/conversation`, and `/events` for failures
- notes of any manual-only checks and their outcome

Suggested screenshot root:

- `/tmp/fae-live-check/`

## Run order

1. Clean build and model verification.
2. Scripted infrastructure and policy phases.
3. Main-window live validation.
4. Cowork live validation.
5. Settings, scheduler, skills, and popup validation.
6. Final regression rerun after fixes.

## Preflight

- [ ] `just rebuild` or `just run-native` launches exactly one real Fae app bundle.
- [ ] `just test-serve` exposes `/health` on `127.0.0.1:7433`.
- [ ] The active local text model and configured vision model are visible in Settings without truncation.
- [ ] The runtime reports the expected local text model, context size, and tool mode.
- [ ] The active local text model matches the current loadable ladder under test: `2B` / `4B` / `9B` on the standard MLX path, with `27B` as the manual quality tier. PARO checkpoints remain sidecar-only until Swift runtime support exists.
- [ ] On a cache-cleared or clean-install machine, first local text-model load completes without `Worker command timed out: load` while model download is in progress.
- [ ] Any stale onboarding, memory, scheduler, or approval state needed for the scenario is reset intentionally through the test server.

## Scripted harness phases

These phases are the minimum scripted baseline:

- [ ] `00-infrastructure`
- [ ] `01-baseline`
- [ ] `02-core-tools`
- [ ] `03-memory`
- [ ] `04-self-config`
- [ ] `05-skills`
- [ ] `06-scheduler`
- [ ] `07-permissions`
- [ ] `08-voice-commands`
- [ ] `09-conversation`
- [ ] `10-policy-profiles`
- [ ] `11-voice-pipeline`
- [ ] `12-onboarding`
- [ ] `13-cowork`
- [ ] `14-dual-model` (legacy compatibility coverage only when that path is intentionally touched)
- [ ] `15-cowork-voice` (requires Chatterbox)

Acceptance:

- [ ] All required phases pass on the shipping bundle.
- [ ] Any failure is either fixed or captured as an explicit release blocker.
- [ ] If a capability changed and no phase covers it, a new phase or deterministic test is added in the same change.

## Main Fae window scenarios

### Startup and first impression

- [ ] Startup lands on one coherent main surface, not a stray empty canvas.
- [ ] The screen tells a new user what Fae is for within 3 seconds.
- [ ] On a true first run after license acceptance, the startup intro/crawl appears exactly once while Fae finishes loading.
- [ ] The orb/visual focus feels calm and intentional rather than blurry or noisy.
- [ ] The main window can be resized and moved without layout breakage.
- [ ] A clean-install or cache-cleared first launch can wait through local model download without failing the pipeline or dropping local worker diagnostics into an error state.
- [ ] The default local startup path is the single-model Qwen3.5 flow, not an implicit dual-model / concierge boot path.
- [ ] On subsequent launches of an already-initialized install, the startup intro does not reappear.
- [ ] Startup progress remains visible through download, model load, verification, and first-response warmup instead of disappearing on a timer.
- [ ] The live conversation surface does not unlock early; input becomes available only after the pipeline is actually ready to respond.

### Onboarding and enrollment

- [ ] `Let me get to know you` uses real audio recording, not injected text.
- [ ] Three real audio enrollment samples can be recorded end to end.
- [ ] Enrollment completion removes the onboarding CTA immediately.
- [ ] Post-enrollment owner state is visible in `/status`.

### Voice input and output

- [ ] Fae can hear real audio input through the native recorder.
- [ ] Fae speaks replies audibly through the configured TTS path.
- [ ] Voice listening starts promptly enough to catch the intended utterance.
- [ ] Wake-word clipping does not cause normal owner follow-up speech to be ignored.
- [ ] During an active conversation, a short pause does not force the user to say the wake phrase again before continuing.
- [ ] When Fae finishes speaking, an owner utterance that starts promptly afterward is still captured rather than being dropped in a post-playback dead zone.
- [ ] Continuation cues such as `wait`, `hold on`, or `let me check` are treated as the same turn rather than an immediate handoff back to idle.
- [ ] Typing can continue while listening remains active.
- [ ] A spoken long-form request produces a substantial answer when appropriate, not an over-compressed reply.

### Text and conversation quality

- [ ] A trivial typed prompt gets a timely, relevant answer.
- [ ] A longer essay-style request gets a comprehensive answer when asked.
- [ ] Overlapping turns are handled cleanly without silent drops or permanent `Thinking...`.
- [ ] When a turn enters a thinking phase, the conversation surface shows the crawl panel before reply streaming begins.
- [ ] When a thinking phase finishes, the crawl collapses cleanly and leaves a replayable thinking icon tied to that turn.
- [ ] Main-window replies remain reliable while Cowork is open.

### Tools, approvals, and popups

- [ ] Read-only tools work in allowed modes.
- [ ] Mutating tools work only in allowed modes.
- [ ] Approval popups appear when required and match actual pending approval state.
- [ ] Deny paths actually deny side effects.
- [ ] Key/input popups accept and return entered values correctly.
- [ ] macOS permission prompts are understandable and unblock the intended feature.
- [ ] Tool access copy is trustworthy and not hallucinatory.
- [ ] First-use vision turns (`screenshot`, `camera`, `read_screen`) can wait through capture and VLM load/inference without failing on an internal tool timeout.

### Memory, scheduler, and skills

- [ ] Memory capture and recall work from the main window.
- [ ] Session search can recover a prior conversation after a conversation reset, with transcript snippets that match what was actually said.
- [ ] Memory Inbox supports pasted text, file import, and URL import in the real app.
- [ ] Files dropped into `~/Library/Application Support/fae/memory-inbox/pending/` can be ingested by the scheduler or manual trigger path.
- [ ] Asking Fae what she learned recently surfaces digest-first recall before raw supporting memories.
- [ ] Recall output shows trustworthy provenance labels for imported artifacts or derived digests.
- [ ] Scheduler list/create/update/delete/trigger flows work.
- [ ] Skills list/add/edit/remove/execute flows work.
- [ ] Staged skill drafts can be listed, inspected, and only applied or dismissed after explicit user confirmation.
- [ ] Any generated or edited artifacts appear where the UI says they will.

## Cowork scenarios

### Open, layout, and clarity

- [ ] Opening Cowork leaves the role of the main Fae window obvious.
- [ ] The Cowork screen is calm, readable, and not cluttered.
- [ ] The current model is visible at rest without opening a menu.
- [ ] The current thinking level is visible without looking like a debug control.
- [ ] Local vs remote is obvious at a glance.
- [ ] Narrow-window resize preserves hierarchy and avoids broken truncation.

### Conversation controls

- [ ] Send is the only dominant action.
- [ ] Compare is secondary and clearly means multi-model fanout.
- [ ] Fork conversation is discoverable without hunting.
- [ ] Add context, switch model, and change response style are easy to find.

### Audio

- [ ] Cowork has a visible voice-input control.
- [ ] Cowork has a visible read-aloud control.
- [ ] Fae in Cowork can receive audio input and produce audible TTS output.
- [ ] Non-local models in Cowork can use the same audio in/out surface where supported by the product.
- [ ] The main-window mic can be disabled or parked cleanly while Cowork voice testing runs.
- [ ] A shared mic gate change is reflected both in `/status` and in the visible mic state on the live UI.

### Local and remote model behavior

- [ ] Local Fae in Cowork can use brokered tools, scheduler access, and memory correctly.
- [ ] Remote models can answer normally through configured providers.
- [ ] Model switching works across local, direct API, and OpenRouter-backed models.
- [ ] Thinking level / response style switching works and remains understandable.
- [ ] Main and Cowork both show the thinking crawl during deliberate reasoning and preserve the replay icon after the answer arrives.
- [ ] Compare and fork preserve the right conversation state.

### Security and privacy

- [ ] Remote-provider sends do not expose secrets, private memories, or unnecessary local metadata.
- [ ] Absolute paths, workspace roots, and hidden local context are not leaked in remote-default packets.
- [ ] Security/export states feel precise and calm rather than blunt or alarming.
- [ ] A remote model can request helpful brokered local outputs without direct raw authority.

### Cowork and main-window coexistence

- [ ] Opening Cowork does not leave the main Fae window covering the workspace surface.
- [ ] If the main window remains visible, it is intentionally docked or parked and does not steal focus during Cowork work.
- [ ] Re-activating the app while Cowork is open preserves that intentional main-window state.

### Workspace surfaces

- [ ] Skills page allows add/edit/remove and reflects real state.
- [ ] Scheduler page allows add/edit/remove and reflects real state.
- [ ] Any approval, export-review, or credentials popup in Cowork actually works.

## Settings and diagnostics scenarios

- [ ] Settings clearly show the active local text model and configured vision model without clipping.
- [ ] Diagnostics surface worker health, route, restart count, and last error correctly. If legacy dual mode is explicitly enabled, concierge diagnostics remain coherent.
- [ ] Theme appearance follows the system appearance unless intentionally overridden.
- [ ] Privacy/security settings match the actual runtime behavior under test.

## Accessibility scenarios

- [ ] Main window controls are reachable and understandable with accessibility labels.
- [ ] Cowork controls are reachable and understandable with accessibility labels.
- [ ] Return-to-send and Shift-Return-for-newline behaviors work where documented.
- [ ] Small targets, truncation, and low-contrast areas have been reviewed live.
- [ ] A live VoiceOver pass has been completed before release.

## Release gate

Do not claim production readiness unless all of the following are true:

- [ ] The scripted phases relevant to the change pass on the shipping bundle.
- [ ] Main-window live validation passes.
- [ ] Cowork live validation passes.
- [ ] Audio input and output are validated with real audio, not text injection.
- [ ] Required screenshots and failure evidence are captured.
- [ ] Docs were updated for any user-visible or policy-visible behavior change.
- [ ] Any remaining issue is explicitly recorded as a blocker rather than silently waived.

## Mapping to commands

Use these commands as the baseline workflow:

```bash
just rebuild
just test-serve
bash scripts/test-comprehensive.sh --skip-llm
bash scripts/test-comprehensive.sh --skip-llm --phase 11
bash scripts/test-comprehensive.sh --skip-llm --phase 12
```

For live UI validation, keep using the real app plus screenshots, the test server, and real audio playback through Chatterbox.

## Model switching and RAM-tier validation

- Verify Settings model changes do not require a full app restart.
- In Settings, switch from one cached local model to another and confirm the pipeline reloads in-app and returns to `running`.
- If selecting an uncached model, verify the app communicates that the model will download during the reload flow and that the current session is replaced only by the new pipeline, not by a full application restart.
- Validate `Auto (Recommended)` model selection against available RAM tiers:
  - under `16 GB` available RAM: `Qwen3.5 2B · 4bit`
  - `16–31 GB` available RAM: `Qwen3.5 4B · 4bit`
  - `32 GB+` available RAM: `Qwen3.5 9B · 4bit`
- Validate `Auto (Recommended)` vision selection against available RAM tiers:
  - under `16 GB` available RAM: vision model remains off by default
  - `16–31 GB` available RAM: `Qwen3-VL 4B · 4bit`
  - `32 GB+` available RAM: `Qwen3-VL 4B · 8bit`
- In `--test-server` or other low-memory validation flows, confirm the runtime clamp is actually applied and reported consistently:
  - operator model resolves to `Qwen3.5 2B · 4bit`
  - effective context is `8192`
  - startup/memory-policy logs report the same effective context as the runtime configuration
- For each RAM tier under validation, capture:
  - idle app RSS
  - peak combined app + worker RSS during at least one real tool turn
  - whether the turn completed natively, via repair fallback, or timed out

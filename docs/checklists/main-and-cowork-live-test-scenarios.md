# Main And Cowork Live Test Scenarios

Last updated: March 10, 2026

This document is the step-by-step live validation companion to
[`docs/checklists/app-release-validation.md`](/Users/davidirvine/Desktop/Devel/projects/fae/docs/checklists/app-release-validation.md).

Use it when validating the real shipping app build after model swaps, prompt
changes, voice pipeline changes, UI changes, tool-policy changes, or Cowork
security changes.

Do not treat screenshots, scripted phase results, or isolated unit tests as a
substitute for these live scenarios. The release bar is: the real app, with
real windows, real audio, real popups, and real provider integration.

## Required setup

1. Start from a clean native launch path with `just run-native` or `just test-serve`.
2. Confirm the test server is live on `http://127.0.0.1:7433`.
3. Ensure Chatterbox is available on `http://127.0.0.1:8000`.
4. Create a screenshot folder, normally `/tmp/fae-live-check/`.
5. Intentionally reset onboarding, scheduler, approval, or memory state through the test server before any scenario that depends on clean state.

## Evidence to capture

- Startup screenshot
- Onboarding screenshot(s)
- Main-window voice and text screenshot(s)
- Approval popup screenshot(s)
- Cowork base screenshot
- Cowork model picker screenshot
- Cowork scheduler / skills / tools screenshot(s)
- Screenshot for any failure or surprising state
- `/status`, `/conversation`, and `/events` output for failures

## Main window scenarios

### 1. Startup and baseline

Acceptance:

- One Fae app instance launches.
- No empty canvas appears on startup.
- The main surface is visually coherent within 3 seconds.
- The loaded local model is visible in the runtime or settings and matches expectations.

Steps:

1. Launch Fae from a clean build.
2. Capture startup screenshot.
3. Confirm `/status` reports the expected operator model and pipeline state.
4. Resize and move the main window once to confirm the surface remains stable.

### 2. Onboarding and voice enrollment

Acceptance:

- `Let me get to know you` opens native recording, not prompt injection.
- All three enrollment samples record real audio.
- Enrollment completes and the CTA disappears immediately.
- `/status.hasOwnerSetUp` becomes `true`.

Steps:

1. Reset onboarding through the test server.
2. Open the app and press `Let me get to know you`.
3. Play or speak three fresh audio samples immediately after each recording arm.
4. Capture screenshots for enrollment start and completion.
5. Confirm the CTA is gone and `/status` reflects owner enrollment.

### 3. Voice input and audible reply

Acceptance:

- Fae hears real audio through the mic pipeline.
- Fae speaks an audible reply through the configured TTS path.
- Listening starts quickly enough to catch the intended utterance.
- Wake-word clipping does not break normal owner follow-up speech.
- After Fae finishes speaking, the owner can start talking promptly without their utterance being dropped.
- A brief mid-conversation pause does not dump the user back to idle.
- Continuation cues like `wait` or `hold on` remain in the same conversation without requiring the wake phrase again.
- Typing remains possible while listening is active.

Steps:

1. Trigger a short spoken prompt using real audio.
2. Capture `/events` if the turn is missed.
3. Trigger a second spoken prompt without a perfectly spoken wake word to confirm owner follow-up tolerance.
4. Let Fae answer a short question, then begin speaking again within about a second of playback finishing; confirm the whole follow-up is heard instead of being dropped.
5. Ask a short question, pause for about a second mid-thought, then continue speaking without repeating `hi Fae`; confirm the continuation is still accepted.
6. During the same engaged session, say a continuation cue such as `wait, let me check` or `hold on` and confirm Fae does not snap back to idle or steal the turn.
7. While listening is still enabled, type a short draft into the composer.
8. Capture a screenshot showing the listening state and text composer together.

### 4. Text quality and turn handling

Acceptance:

- A trivial typed prompt gets a relevant answer promptly.
- A long-form request gets a substantial answer when explicitly requested.
- Overlapping turns do not leave the UI stuck in `Thinking...`.
- The main conversation surface shows the thinking crawl before live reply text appears when thinking is active.
- The replayable thinking icon remains available after the reply finishes.

Steps:

1. Type a trivial prompt.
2. Type a longer request asking explicitly for a detailed answer or essay.
3. If the first turn is still live, attempt a second turn and verify the UI handles the overlap cleanly.
4. Run one prompt with thinking enabled and capture the crawl state before the first visible reply token arrives.
5. After the reply finishes, click the thinking icon and confirm the stored trace opens again.
6. Capture screenshots for both a short answer and long-form answer.

### 5. Tools, popups, and approvals

Acceptance:

- Tool calls respect tool mode.
- Approval popups appear only when required.
- Approval approve/deny paths match actual side effects.
- Key-entry popups and permission prompts work.

Steps:

1. Run a read-only request in a read-capable mode.
2. Run a mutating request in a mutating mode.
3. Trigger an approval-required action and capture the popup.
4. Approve once and deny once; verify both outcomes with filesystem or test-server evidence.
5. Trigger a key or input popup if relevant and verify the returned value reaches the runtime.

### 6. Memory, scheduler, and skills

Acceptance:

- Memory capture and recall work from the main window.
- Scheduler create/update/delete/trigger works.
- Skills list/add/edit/remove/execute works.

Steps:

1. Teach Fae one temporary memory, then ask for it back.
2. Open scheduler UI and create one temporary task.
3. Edit and then delete that task.
4. Open skills UI, inspect at least one skill, and run one harmless skill flow if available.
5. Capture screenshots and backend evidence for each surface.

## Cowork scenarios

### 7. Open, coexistence, and baseline

Acceptance:

- Opening Cowork does not leave the main window obscuring the workspace.
- The main window is intentionally docked or parked if still visible.
- The Cowork surface is readable and calm at rest.

Steps:

1. Disable the shared mic if voice testing will focus on Cowork.
2. Open Cowork.
3. Capture a screenshot showing the Cowork window and the main window state together.
4. Reactivate Fae once and verify the main window does not jump back over Cowork.

### 8. Model, response style, compare, and fork

Acceptance:

- The active model is visible at rest.
- Response style / thinking level is visible and understandable.
- Compare is secondary to Send.
- Fork is discoverable and usable.

Steps:

1. Capture the baseline Cowork screenshot.
2. Open the model picker and capture it.
3. Switch between at least one local-capable route and one remote route.
4. Change response style once.
5. Use fork on a conversation and verify the fork appears in the sidebar.

### 9. Cowork audio controls

Acceptance:

- The Cowork surface exposes voice input and read-aloud affordances.
- Fae in Cowork can hear and speak where supported.
- The main mic state does not interfere unexpectedly during Cowork voice tests.

Steps:

1. Identify and capture the visible Cowork audio controls.
2. Run one audio-in turn against local Fae in Cowork.
3. Trigger read-aloud for one Cowork reply.
4. If remote audio parity is a supported product feature, repeat with one non-local model.

### 10. Local and remote model behavior

Acceptance:

- Local Fae in Cowork can use brokered local capabilities correctly.
- Remote providers answer normally.
- Local vs remote is obvious in the UI.
- Model switching does not corrupt the thread.
- Cowork shows the thinking crawl before a remote or local reply begins streaming, then leaves the replay icon afterward.

Steps:

1. With a local-capable Cowork route, test one safe brokered local request.
2. With a remote route, test one normal query and one secret-containing query.
3. Confirm the secret path is blocked or reviewed according to current policy.
4. With thinking enabled, capture the Cowork crawl state before the first reply token for both a local and a remote turn if available.
5. After each reply completes, click the thinking icon and confirm the stored trace reopens.
6. Capture screenshots for successful remote send and guarded send.

### 11. Cowork utility surfaces

Acceptance:

- Scheduler, skills, and tools surfaces open from the live app.
- `Fae > Scheduler` and `Fae > Skills` open the Cowork utility surfaces directly instead of sending the user through Settings.
- Each surface reflects real state rather than placeholder content.
- Add/edit/remove flows work where the surface claims to support them.

Steps:

1. Open `Fae > Scheduler` and capture the Cowork scheduler surface.
2. Open `Fae > Skills` and capture the Cowork skills surface.
3. Open Cowork Tools and capture it.
4. Use `View > New Cowork Task` and `View > New Cowork Skill` to verify the creation sheets open from the live app.
5. For scheduler and skills, perform one real mutation if the surface exposes one.
6. For skills, import one remote `SKILL.md` by URL and confirm the content is visible locally before save, along with security-review findings.
7. Verify the changes reflect in the underlying runtime or data source.

### 12. Security and privacy

Acceptance:

- Remote sends do not include secrets, private memories, or unnecessary path metadata by default.
- Security states are precise and calm.
- Remote models do not receive raw local authority.

Steps:

1. Attempt one remote send containing a likely secret.
2. Attempt one remote send that should succeed with benign content.
3. Verify the success path, guard path, and visible explanation.
4. Inspect captured request metadata or logs if needed to confirm local-path stripping.

## Final release sign-off

Only mark the build release-ready when all of the following are true:

- All relevant scripted phases in `scripts/test-comprehensive.sh` pass.
- Main-window scenarios pass on the real app.
- Cowork scenarios pass on the real app.
- Real audio input/output was used where voice is involved.
- Screenshots and failure evidence were captured.
- Any remaining issue is recorded as a release blocker rather than waved away.

# Work with Fae

Work with Fae is Fae’s conversation-first workspace surface for focused project work.

It is intentionally separate from the main Fae window, but it still uses Fae’s trusted local runtime, memory, approval flow, and privacy rules.

## Product model

Work with Fae treats each workspace like a conversation/thread:

- left rail = conversations/workspaces
- center = active conversation surface
- details rail = optional workspace context and controls
- utilities = secondary sheets/menus, not the primary surface
- the main screen should stay conversation-first: model switching is primary, while agent management, tools, scheduler, and settings stay in quieter secondary menus or drawers
- the active conversation surface should stay visually centered and calm rather than stretching every status/control across the full window
- workspace metadata should read as quiet supporting text, not as a wall of badges or provider labels
- the details rail should feel like an optional inspector, not a second dashboard competing with the thread
- the left-rail brand should carry the visual identity: an animated Fae ember orb and quiet title treatment, not a generic utility label
- send should remain the single dominant call to action; compare is secondary and should read as an optional multi-agent step or lightweight status when auto-compare is enabled

## Core capabilities

### Separate visible session, shared Fae intelligence

Work with Fae has its own visible conversation session and window.

That means:

- the main Fae window stays available as its own conversation surface when cowork opens; opening Work with Fae should not silently collapse main Fae into the tiny orb
- approvals for cowork-routed Fae Local turns prefer the Work with Fae window
- Fae still sees the work for memory, later assistance, and local supervision

## Conversation and workspace features

### Conversations and forks

Each workspace is effectively a conversation.

Supported behaviors:

- create a new conversation/workspace
- rename, duplicate, delete, and reorder conversations
- fork a conversation into a sibling thread
- preserve each workspace’s own conversation history
- restore the correct thread when a workspace is selected again

Forks copy the conversation state into a new workspace record with parent linkage, so you can branch a line of work without losing the original thread.

### Folder grounding and attachments

A workspace can carry grounded local context:

- one selected workspace folder for broad grounding
- indexed files discovered from that folder
- focused file preview
- attachments added by file picker, drag/drop, or paste
- images and text snippets as focused session context

Work with Fae does **not** blindly dump an entire directory into every remote prompt. Local-only workspace context stays local when remote providers are used.

### Model selection and switching

Work with Fae supports provider-aware model setup:

- provider/backend presets for Fae Local, OpenAI, OpenRouter, custom OpenAI-compatible endpoints, and Anthropic
- searchable model pickers in provider setup surfaces
- a conversation-level model browser that keeps model names primary and provider details secondary
- the active conversation surface shows the selected model name instead of provider-heavy route labels
- the active conversation chrome and conversation list should make `On-device` vs `Remote` obvious without surfacing provider clutter in the resting UI
- selecting a different model can switch the attached route/provider without resetting the thread
- local model switches continue with the full local thread; remote providers continue the thread using only the current exported shareable context

### Keyboard and accessibility

Work with Fae should feel native on macOS, not like a web tool inside a shell.

Current interaction contract:

- Return sends from the cowork composer
- Shift-Return inserts a new line in the cowork composer
- the composer, send button, compare button, model picker, agent picker, and workspace rows expose explicit accessibility labels and hints
- drag/drop remains available, but every core action also has a keyboard- and menu-reachable path
- the main window input bar and Work with Fae use the same plain-language accessibility naming for sending, thinking level, and opening cowork
- voice capture should not turn typing into a separate mode: users must be able to keep listening active while typing and sending text
- cowork should expose explicit `Listening` and `Read reply` controls in the composer footer so voice-in and read-aloud are available regardless of selected model
- startup should land on the main conversation surface rather than opening an auxiliary canvas window automatically

### Thinking levels

Work with Fae now exposes three mid-conversation thinking levels:

- **Fast** — minimize deliberate reasoning for quicker replies
- **Balanced** — default balance of speed and reasoning quality
- **Deep** — more deliberate reasoning for harder tasks

These levels are conversation-safe to change mid-thread:

- the thread stays the same
- the new level applies to the next turn
- Fae Local uses a real local behavior change
- remote providers receive best-effort reasoning/effort hints when the selected backend supports them

The resting UI should present this as a user-facing response-style choice rather than as an internal/debug control.

## Local, remote, and compare behavior

### Trusted local vs remote specialists

Every workspace always has access to trusted **Fae Local**.

You can also attach remote specialists.

Supported current remote families:

- OpenAI-compatible providers
- OpenRouter
- Anthropic

**Important trust boundary:** remote models are specialists, not local operators.

That means:

- remote models do **not** get direct access to local tools
- remote models do **not** get your files, apps, or approvals directly
- only Fae Local owns tool execution, approval prompts, local grounding, and memory writes
- remote models receive only the shareable prompt Fae prepares for them

### Per-workspace policy controls

Each workspace can set:

- **Remote execution**
  - remote allowed
  - strict local only
- **Compare behavior**
  - compare on demand
  - always compare on send
- **Consensus roster**
  - automatic participant selection
  - explicit participant selection per workspace

### Consensus and compare

Work with Fae can compare answers across multiple agents.

Current behavior:

- fans out to the selected agent, Fae Local, and other eligible agents
- shows compact compare status in the conversation surface
- can expand to show raw per-agent answers
- synthesizes a local Fae summary when possible
- keeps strict-local workspaces on-device

## Privacy and security behavior

### Fast local secret guard before remote egress

Before remote sends, Work with Fae runs a fast local secret preflight.

If a prompt looks like it contains:

- passwords
- API keys
- bearer tokens
- similar credential material

then remote egress is blocked locally and nothing is sent to the remote provider.

### Current enforcement and approved hardening plan

Current implemented behavior:

- remote models receive only the shareable Cowork export packet rendered as prompt context, not the full local prompt
- remote models do not get direct local tool access
- raw recent conversation history stays local by default for remote sends
- absolute attachment and focused-item path metadata is stripped from remote sends
- likely credentials are blocked locally before remote send

Approved next hardening steps:

- replace the blunt hold/send-anyway card with a more precise export review
- extend the export policy beyond likely credentials into richer personal/private data classes
- keep local Fae as the only privileged principal while remote models use brokered follow-up intents

Canonical technical plan:

- `docs/architecture/cowork-security-and-egress-plan-2026-03-07.md`

### Shared approval model

Work with Fae does not invent a second permission system.

If Fae Local needs tools:

- the same trusted approval flow is used
- tool permissions still respect global tool mode and per-tool toggles
- cowork-routed approvals prefer the cowork window when possible

## Current regression coverage

Important Work with Fae behavior is covered in automated tests, including:

- workspace registry normalization and persistence
- fork behavior and trimmed fork histories
- controller-level fork/restore stability
- conversation-level model browser and provider switching
- remote provider request building and streaming
- shareable vs local-only prompt egress
- multi-agent selection and strict-local filtering
- recent conversation continuity for model switching

See:

- `native/macos/Fae/Tests/HandoffTests/WorkWithFaeWorkspaceTests.swift`
- `native/macos/Fae/Tests/HandoffTests/CoworkRemoteProviderTests.swift`
- `native/macos/Fae/Tests/HandoffTests/CoworkProviderConnectionTests.swift`
- `native/macos/Fae/Tests/HandoffTests/RuntimeContractTests.swift`

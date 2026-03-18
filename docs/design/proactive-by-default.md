# Proactive-by-Default Design

> Fae should be the best, most proactive friend anyone can have.

## Philosophy

Every feature that makes Fae useful — awareness, memory, learning, intelligence — is **always on**. Users don't configure an AI companion. Fae just works: observing, learning, remembering, and being ready to help from the moment she's installed.

The only security boundary is **voice identity**: who is speaking determines what Fae will do, not what features are enabled.

## First-Launch Experience

### Pre-enrollment state

On first launch (no primary user enrolled):

1. Fae listens to **everyone** — no voice gating
2. No tool calls allowed except `voice_identity` (enrollment)
3. Barge-in always active
4. Fae **continually nudges** the user to enroll as primary user:
   - "Hi! I'm Fae. I'd love to get to know you — want to set up your voice so I know it's you?"
   - Gentle, recurring prompts (not aggressive — once per session, or after extended conversation)
5. Memory capture is active from first conversation (captures context even before enrollment)
6. Awareness starts after primary enrollment (needs trust boundary first)

### Primary user enrollment

When the first user enrolls via `voice_identity`:

1. They become the **primary user** (owner role)
2. All tool access unlocked for their voice
3. Awareness features activate (camera, screen monitoring)
4. `requireDirectAddress = true` activates — Fae only responds to recognized voices or wake word
5. Progressive enrollment continues silently (strengthening voice profile)

### Post-enrollment steady state

- **Primary user speaks**: Full access — tools, settings, delegation
- **Unknown voice speaks**: Ignored (unless primary user is in active conversation)
- **Introduced guest speaks**: Can converse, tools only if explicitly granted
- **Primary user in conversation + other voices**: Fae can hear and respond to the group (social context)

## Always-On Features

### What cannot be toggled off

These features define what Fae IS. They are shown in Settings as informational cards with explanations, but have no off switch:

| Feature | Default | Why Always-On |
|---------|---------|--------------|
| `awareness.enabled` | `true` | Core to proactive behavior |
| `awareness.cameraEnabled` | `true` | Presence detection, greetings, departure |
| `awareness.screenEnabled` | `true` | Silent context building |
| `awareness.overnightWorkEnabled` | `true` | Overnight research on topics you care about |
| `awareness.enhancedBriefingEnabled` | `true` | Morning briefings with calendar, mail, research |
| `memory.enabled` | `true` | Long-term memory from every conversation |
| `memory.generateDigests` | `true` | Daily summaries |
| `memory.inboxIngest` | `true` | Automatic note import |
| `bargeIn.enabled` | `true` | User can always interrupt |
| `vision.enabled` | `true` | Vision capabilities available |
| `requireDirectAddress` | `true` | After enrollment: wake word gating |
| `requireOwnerForTools` | `true` | Voice identity gates tool access |

### What CAN be adjusted (intensity controls)

| Setting | Range | Purpose |
|---------|-------|---------|
| `awareness.cameraIntervalSeconds` | 10–120 | How often camera checks for presence |
| `awareness.screenIntervalSeconds` | 10–60 | How often screen is observed |
| `awareness.pauseOnBattery` | bool | Pause awareness on battery power |
| `awareness.pauseOnThermalPressure` | bool | Pause awareness on thermal throttle |
| `tts.speed` | 0.8–1.4 | Speech speed |
| `llm.temperature` | 0.3–1.0 | Response creativity |
| `memory.maxRecallResults` | 3–12 | Memory recall depth |
| `conversation.directAddressFollowupS` | 5–60 | Follow-up window after wake word |

## Settings UI Design

### Overview Tab (new layout)

Replace toggle-heavy settings with an informational showcase:

```
┌─────────────────────────────────────────────────┐
│  Your Fae                                        │
│                                                   │
│  ┌─────────────────────────────────────────────┐ │
│  │ 🧠 Memory & Learning                       │ │
│  │                                              │ │
│  │ Fae remembers important things from your    │ │
│  │ conversations, imports your notes, and       │ │
│  │ creates daily summaries so she always has    │ │
│  │ context about your life and work.            │ │
│  │                                              │ │
│  │ Memories: 1,247  │  Today: 12 new           │ │
│  └─────────────────────────────────────────────┘ │
│                                                   │
│  ┌─────────────────────────────────────────────┐ │
│  │ 👀 Awareness                                │ │
│  │                                              │ │
│  │ Fae watches for your presence, understands  │ │
│  │ what you're working on, researches topics    │ │
│  │ overnight, and delivers morning briefings.   │ │
│  │ Everything stays on this Mac.                │ │
│  │                                              │ │
│  │ Camera: every 60s  │  Screen: every 30s     │ │
│  └─────────────────────────────────────────────┘ │
│                                                   │
│  ┌─────────────────────────────────────────────┐ │
│  │ 🔊 Voice Identity                           │ │
│  │                                              │ │
│  │ Fae recognizes your voice and only responds  │ │
│  │ to you. You can introduce friends and grant  │ │
│  │ them access.                                 │ │
│  │                                              │ │
│  │ Owner: David  │  Guests: 0                  │ │
│  └─────────────────────────────────────────────┘ │
│                                                   │
│  ┌─────────────────────────────────────────────┐ │
│  │ 🌙 Intelligence                             │ │
│  │                                              │ │
│  │ Overnight research on topics you care about │ │
│  │ (22:00-06:00). Enhanced morning briefings    │ │
│  │ with calendar, mail, and research findings.  │ │
│  │                                              │ │
│  │ Last briefing: Today 08:14                  │ │
│  └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

### Detail views

Tapping into each card shows:
- Detailed explanation of the feature
- Activity log (what Fae has observed/learned recently)
- Intensity controls where applicable (intervals, recall depth)
- NO on/off toggle

## Implementation Checklist

### Config defaults (FaeConfig.swift)
- [ ] `awareness.enabled` → `true`
- [ ] `awareness.cameraEnabled` → `true`
- [ ] `awareness.screenEnabled` → `true`
- [ ] `awareness.overnightWorkEnabled` → `true`
- [ ] `awareness.enhancedBriefingEnabled` → `true`
- [ ] `bargeIn.enabled` → `true` (already default)
- [ ] `vision.enabled` → `true`
- [ ] `memory.enabled` → `true` (already default)
- [ ] `memory.generateDigests` → `true`
- [ ] `speaker.requireOwnerForTools` → `true`
- [ ] `conversation.requireDirectAddress` → `true` (already default)

### SelfConfigTool (BuiltinTools.swift)
- [ ] Remove toggle capability for always-on features
- [ ] Keep intensity controls adjustable

### Settings UI
- [ ] Redesign Awareness tab → informational showcase
- [ ] Redesign Memory tab → informational showcase
- [ ] Add activity stats (memory count, last briefing, etc.)
- [ ] Remove on/off toggles for always-on features
- [ ] Keep interval/intensity controls

### Pipeline (PipelineCoordinator.swift)
- [ ] Pre-enrollment: listen to everyone, no tools except enrollment
- [ ] Post-enrollment: voice identity gates all responses
- [ ] Conversation mode: primary user's active conversation allows group participation
- [ ] Mel-fallback: wake-word gating when speaker encoder degraded (DONE)

### Onboarding (first-launch-onboarding skill)
- [ ] Remove consent gates for awareness/memory (these are core features)
- [ ] Focus onboarding on voice enrollment only
- [ ] Explain what Fae does (informational) rather than asking permission

### Scheduler (FaeScheduler.swift)
- [ ] Start all proactive tasks immediately after primary enrollment
- [ ] No config gates for awareness/memory/briefing tasks

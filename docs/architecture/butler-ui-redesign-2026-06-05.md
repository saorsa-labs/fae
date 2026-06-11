# Fae Butler UI Redesign — A Face, Not a Panel

> Status: **Design draft** (2026-06-05) · Owner: David Irvine · Implements **D7** of
> [`conductor-positioning-and-scope-2026-06-05.md`](./conductor-positioning-and-scope-2026-06-05.md).
> **Visual authority: `DESIGN.md`** — all colours/type/spacing below cite it; do not deviate without approval.

## 1. Principle

The head butler shows a **calm, emotive face and speaks** — she does not present a control panel. This redesign is overwhelmingly **removal**, not addition: the orb (already a rich emotion engine) and speech bubbles are the product; everything else recedes. Per the proactive-by-default philosophy, always-on capabilities become an *informational showcase*, never toggles.

## 2. The emotion engine already exists — keep it, foreground it

Source check: the orb is **not** missing emotion — it has a deep model already (`OrbTypes.swift`):
- **4 modes** (`OrbMode`): `.idle / .listening / .thinking / .speaking` — each with fog/star/morph/breath/glow params + default Scottish palette.
- **8 feelings** (`OrbFeeling`): `.neutral / .calm / .curiosity / .warmth / .concern / .delight / .focus / .playful`.
- **13 palettes** (`OrbPalette`), HSL-interpolated, 500ms spring transitions, anticipation micro-animations (`OrbAnimationState`), Metal-rendered with gradient fallback.

So the redesign's job is **not** to build emotion — it's to (a) make the orb the persistent hero, (b) wire feelings to the *butler demeanor*, and (c) strip the chrome around it.

**Butler demeanor mapping** (drive `OrbFeeling` from conversational/awareness state — `SentimentClassifier` already feeds this):

| Situation | Feeling | Palette family |
|-----------|---------|----------------|
| At rest, present | `.calm` | `silverMist` / `lochGreyGreen` |
| You arrive / greeting | `.warmth` | `faeAmber` / `goldenDawn` |
| Working a request / routing | `.focus` | `heatherMist` |
| Delivering good news | `.delight` | `goldenDawn` |
| Something needs care/attention | `.concern` | `rowanBerry` (sparingly) |
| Curious / asking to learn you | `.curiosity` | `heatherMist` |

Hard rule (`DESIGN.md`): orb accents draw **only** from the landscape tones (`loch-grey-green`, `silver-mist`, `moss-stone`, `dawn-light`, `peat-earth`) + signature warm/cool — never system colours.

## 3. The three surfaces that remain

Everything the butler shows reduces to three things, all already built — keep, simplify, polish to `DESIGN.md`:

1. **The orb** (hero, always visible). Collapsed = 120×120 orb-only; compact = orb crown (300pt, never covered) + conversation. `NativeOrbView` unchanged.
2. **Speech bubbles** (the conversation). `MessageBubble`: user `#38476B` / border `rgba(89,115,166,0.5)`; Fae `#3D334D` / border `rgba(180,168,196,0.25)`; **system serif 13pt**; radius `lg: 16`; padding 14×9. `SubtitleOverlayView` stays for the glanceable last-line over the orb. **No restyle — these already match `DESIGN.md` bubble tokens.**
3. **One card at a time** (`InputOverlayView`). Keep the 4 card types (`InputCard`, `FormInputCard`, `ToolModeCard`, `GovernanceConfirmationCard`) — floating, `surface-card #1A1820`, radius 16, `.spring(0.3)` `.move(.bottom)+.opacity`. The approval card is the butler asking permission; it stays exactly this calm.

**New, minimal — the fleet glance.** A quiet "what's happening" strip (not a manager): who of your fleet is online (x0x presence) and any in-flight delegated/orchestrated work (conductor). Replaces the old Overview dashboard's *status* role. Glanceable, dismissible, `surface-card`, Instrument Serif section label, no toggles. Sources: capability-advertisement spec (presence) + Phase-2 (work state).

## 4. Window & chrome cuts

- **Keep:** collapsed orb dock (120×120) ↔ compact (340×500), frameless frosted (`.ultraThinMaterial`), auto-expand on speak. `WindowStateController` largely unchanged.
- **Remove:** the **canvas auxiliary window** and the **CoWork window** entirely (`AuxiliaryWindowManager` canvas/cowork routing — see CoWork removal plan). The butler has no "workspace desktop"; work happens in conversation or is delegated.
- **Keep:** conversation panel as an optional detached NSPanel for longer reading; banners (`EnrollmentInvitationBanner`, `PhotoSetupBanner`) stay — they're onboarding, not settings.

## 5. The big cut: 20 settings tabs → ~6 groups

Current: **20 tabs** (`Settings*.swift`). Target: a handful, organised by *what the butler is* — not a config tree. Mapping every tab:

| Current tab | Disposition | Lands in |
|-------------|-------------|----------|
| `SettingsOverviewTab` (status + quick toggles) | **Replace** | → **Home/Status** = the fleet glance (status only, toggles dropped) |
| `SettingsAboutTab` (version, onboarding reset) | Keep (minimal) | **About** |
| `SettingsGeneralTab` (audio in/out, window) | Keep (essential device) | **Voice & Audio** |
| `SettingsSpeakerTab` (voice identity, profiles) | Keep (security model — essential) | **Voice & Audio** |
| `SettingsModelsTab` + `SettingsModelsPerformanceTab` (model/voice/prosody/perf) | **Merge** → preset `auto` default; voice/TTS-speed as intensity sliders; perf metrics behind Advanced | **Voice & Audio** (intensity) + **Advanced** (perf) |
| `SettingsSkillsTab` + `SettingsToolsTab` (skill CRUD + Apple perms + tool showcase) | **Merge** → the "abilities + permissions" view; now also the agentskills.io/MCP "hire help" surface (interop spec) | **Abilities** |
| `SettingsChannelsTab` (channel setup) | Keep (guest comms) | **Abilities** |
| `SettingsPersonalityTab` (SOUL, directive, rescue) | Keep (core butler character) | **Personality** |
| `SettingsAwarenessTab` (showcase + intensity) | **Showcase** + camera/screen interval sliders | **What Fae Does** |
| `SettingsMemoryTab` (showcase + recall depth) | **Showcase** + recall-depth slider | **What Fae Does** |
| `SettingsTrainingTab` (Personal Learning) | **Showcase** (always-on nightly LoRA) | **What Fae Does** |
| `SettingsPrivacyFilterTab` + `SettingsPrivacySecurityTab` | **Merge → showcase** (on-device PII + policies) + debug behind Advanced | **What Fae Does** + **Advanced** |
| `SettingsSchedulesTab` (scheduler mgmt) | Move (housekeeping visibility) | **Advanced** (or surfaced read-only in fleet glance) |
| `SettingsDiagnosticsTab` (dashboard) | Hide | **Advanced/Developer** |
| `SettingsDeveloperTab` (orb controls, raw cmd) | Hide (Option-click) | **Advanced/Developer** |
| `SettingsOtherLLMsTab` (third-party LLM) | **DELETE** (CoWork removed; mesh/agentskills/MCP replace it) | — |
| `SettingsSkillsChannelsWorkspace` (advanced workspace) | **DELETE** (CoWork-adjacent workspace) | — |

**Resulting groups (≈6 + hidden):**
1. **Home/Status** — fleet glance; what Fae is doing now.
2. **Voice & Audio** — devices, voice identity, model preset (auto), TTS voice/speed.
3. **Abilities** — skills (incl. agentskills.io/MCP "hire help" + the import security review), tools, channels, Apple permissions.
4. **Personality** — SOUL, directive, rescue mode.
5. **What Fae Does** — informational showcase of always-on capabilities (awareness, memory, learning, privacy) with intensity sliders only. **No on/off toggles** — these define what Fae is.
6. **About** — version, onboarding.
7. *(Hidden)* **Advanced/Developer** — diagnostics, orb dev controls, schedules, perf, privacy debug.

**Showcase, not toggles** (`DESIGN.md` + proactive-by-default): each "What Fae Does" card = Instrument Serif title + plain-language *what it does / why it matters* + (where relevant) one intensity slider. No purple-blue gradient header (replace with the orb mark, `DESIGN.md` hard-rule #1/#2).

## 6. Visual conformance checklist (`DESIGN.md`)

- Surfaces: `surface-base #0F1013` (conversation), `surface-card #1A1820` (cards/glance), `surface-elevated #221F28` (active tab) — **never** `windowBackgroundColor`.
- Type: Instrument Serif (display/headers), system serif 13 (bubbles — unchanged), SF Pro (controls/labels 11–12), SF Mono (diagnostic values). **No SF Pro Rounded for display.**
- Radius: bubbles/cards `16`, inputs/status `12`, buttons `6`, pills `full`.
- Motion: micro 80ms, short 200ms (`.spring(0.2)`), medium 350ms, long 500ms (orb/window). Keep existing approval/streaming/window curves.
- Accent: Scottish palette only; `-text` variants for any readable text (≥4.5:1). Dark-first, no light mode.
- Hard rules: no emoji in headers, no system `.blue/.green/.orange`, no purple-blue gradient circles, no decorative button gradients.

## 7. Cross-platform note

The face is deliberately thin so it ports (brain/face split). The orb is Metal on Apple with a **gradient fallback already implemented** (`NativeOrbView`); the non-Apple thin client (Dioxus/Tauri) renders the same core state — orb (fallback), bubbles, one card, fleet glance. The 3-surface minimalism is what makes that port cheap; the 20-tab settings tree never has to be reimplemented because most of it is deleted or showcase.

## 8. Acceptance criteria

- [ ] Orb persistently visible (collapsed + compact); `OrbFeeling` driven by butler demeanor (§2) from `SentimentClassifier`/conversation state.
- [ ] Conversation = bubbles + subtitle, unchanged styling, conforms to `DESIGN.md` tokens.
- [ ] Exactly one floating card at a time; approval card calm + `DESIGN.md`-conformant.
- [ ] Fleet glance shows presence + in-flight work; read-only, no toggles.
- [ ] Settings reduced to ≈6 groups + hidden Advanced; `OtherLLMs` + `SkillsChannelsWorkspace` deleted; canvas/CoWork windows gone.
- [ ] "What Fae Does" cards are showcase + intensity sliders only — zero on/off toggles for always-on features.
- [ ] No `DESIGN.md` hard-rule violations (QA-mode scan clean).
- [ ] Works Apple (SwiftUI+Metal) + Linux thin client (gradient fallback); v1 scope.

## 9. Open questions

1. **Fleet glance placement** — inline strip in compact mode, or a peek panel? Lean: collapsible strip above the input bar, mirroring `VoiceHintsView`.
2. **Abilities visibility** — does the user actively *manage* installed skills/MCP servers, or is it mostly butler housekeeping with a read-only list? Lean: read-only list + an explicit "review pending skill" action (the D5 security gate surfaces here).
3. **SOUL/directive editing UX** — keep the current editor, or a gentler "how should I behave?" conversational flow? Track with the SOUL refresh (positioning §8.2).
4. **Settings entry point** — a butler should barely need settings; is it a menu-bar item only, or reachable from the orb context menu? Lean: both, low-emphasis.

## 10. References
- **`DESIGN.md`** (visual authority — all tokens above).
- `conductor-positioning-and-scope-2026-06-05.md` (D7), `cowork-removal-plan-2026-06-05.md` (canvas/CoWork window + OtherLLMs/workspace tab deletions), `skill-and-tool-interop-2026-06-05.md` (Abilities = the hire-help + import-review surface), `conductor-capability-advertisement-2026-06-05.md` + `conductor-phase2-async-orchestration-2026-06-05.md` (fleet glance data).
- Source: `OrbTypes.swift`, `OrbAnimationState.swift`, `NativeOrbView.swift`, `ContentView.swift`, `ConversationWindowView.swift`, `InputOverlayView.swift`, `SubtitleOverlayView.swift`, `WindowStateController.swift`, `AuxiliaryWindowManager.swift`, `Settings*.swift` (20 tabs), `SentimentClassifier.swift`.

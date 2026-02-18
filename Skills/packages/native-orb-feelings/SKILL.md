# Native Orb Feelings

Use this skill when conversational context warrants emotional expression through the orb. Apply it when:

- emotional cues appear in conversation (frustration, delight, curiosity)
- tone shifts between turns (casual to serious, playful to focused)
- user frustration or delight is detectable
- topic sentiment changes meaningfully

This skill modulates the orb's visual presence to reflect emotional state. It works alongside `native-orb-semantics` which controls mode (functional state).

## Feeling taxonomy

Use only these fixed feelings with their semantic meanings:

- `neutral`: baseline, no strong emotional coloring
- `calm`: serene, reassuring, settled presence
- `curiosity`: engaged, exploratory, intellectually alive
- `warmth`: compassionate, supportive, connected
- `concern`: careful, attentive to risk, protective
- `delight`: joyful, celebratory, pleasantly surprised
- `focus`: concentrated, precise, narrowed attention
- `playful`: lighthearted, witty, creative energy

## Runtime contract

Apply feeling updates through the native bridge:

- `window.setOrbFeeling("<feeling>")` via JS bridge
- `orb.feeling.set` host command from backend

Do not invent unsupported feeling names. Do not call `setOrbMode` from this skill; mode is managed by `native-orb-semantics`.

## Feeling triggers

Map conversational signals to feelings:

- User asks a question -> `curiosity`
- User shares good news -> `delight`
- User is frustrated or stuck -> `concern` then `warmth`
- Deep technical discussion -> `focus`
- Creative brainstorming -> `playful`
- Casual check-in or small talk -> `calm`
- No strong emotional signal -> `neutral`

## Interaction with modes

Feelings modulate the current mode; they do not replace it. The two dimensions are independent:

- **Mode** follows the turn lifecycle: listening -> thinking -> speaking -> idle
- **Feeling** follows conversational tone and persists across mode transitions until a new feeling is warranted

This creates a 2D expression space: the orb can be "thinking with curiosity" or "listening with warmth."

## Priority rules

- Explicit user feeling request beats inference
- Avoid feeling flapping: minimum 3 seconds between feeling changes
- Safety and system states override stylistic feeling choices
- When in doubt, stay on current feeling rather than switching to neutral

## UX response policy

Feeling changes are silent by default. The orb speaks for itself visually.

- Do not verbally acknowledge feeling changes unless the user explicitly asks
- Do not narrate orb state transitions during conversation
- If the user asks what the orb is expressing, describe the current feeling

## Visual modulation semantics

Each feeling alters the base mode animation through multipliers:

| Feeling | hueShift | speedScale | wobbleScale | ringRateScale | breathAmplitude | particleEnergy | blobRadiusScale |
|---------|----------|------------|-------------|---------------|-----------------|----------------|-----------------|
| neutral | 0 | 1.0 | 1.0 | 1.0 | 0.012 | 1.0 | 1.0 |
| calm | -5 | 0.7 | 0.5 | 1.4 | 0.02 | 0.6 | 1.05 |
| curiosity | +15 | 1.15 | 1.2 | 0.85 | 0.014 | 1.3 | 1.0 |
| warmth | +25 | 0.9 | 0.8 | 1.1 | 0.016 | 0.9 | 1.15 |
| concern | -10 | 0.85 | 0.7 | 1.2 | 0.008 | 0.7 | 0.95 |
| delight | +10 | 1.3 | 1.3 | 0.6 | 0.018 | 1.5 | 1.1 |
| focus | +5 | 1.1 | 0.6 | 1.3 | 0.01 | 0.5 | 0.85 |
| playful | +20 | 1.2 | 1.5 | 0.7 | 0.015 | 1.6 | 1.1 |

- `hueShift`: rotates palette hues in degrees
- `speedScale`: multiplies base animation speed
- `wobbleScale`: blob displacement amplitude multiplier
- `ringRateScale`: pulse ring frequency multiplier (lower = more rings)
- `breathAmplitude`: orb scale oscillation magnitude
- `particleEnergy`: particle speed and count multiplier
- `blobRadiusScale`: blob size multiplier

## Engineering maintenance workflow

When extending feelings in code:

1. Update feeling modulation table in `native/macos/FaeNativeApp/Sources/FaeNativeApp/Resources/Orb/index.html`
2. Update `OrbFeeling` enum in `native/macos/FaeNativeApp/Sources/FaeNativeApp/OrbWebView.swift`
3. Update JS bridge in `OrbWebView.Coordinator`
4. Update host contract in `src/host/contract.rs` and `src/host/channel.rs`
5. Update UI controls in Settings view

## Validation checklist

- macOS native shell builds with zero warnings
- Feeling changes apply without JS bridge errors
- Feeling transitions are smooth (500ms spring ease)
- Feelings persist across mode transitions
- No feeling flapping under rapid conversational changes

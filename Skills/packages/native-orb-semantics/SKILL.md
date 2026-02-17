# Native Orb Semantics

Use this skill for requests that change Fae's orb mood, state, and visual energy in the native app.

Apply it when user intent is about:

- mood words ("calmer", "warmer", "more focused", "more protective")
- explicit state words ("show listening", "set speaking mode", "go idle")
- visual behavior ("reduce pulse", "make orb feel alive but subtle")

This skill controls orb state semantics only. It does not control device transfer.

## Runtime contract

Use only supported orb modes:

- `idle`
- `listening`
- `thinking`
- `speaking`

Apply state updates through native bridge:

- `window.setOrbMode("<mode>")`

Do not invent unsupported JS API names. Do not claim per-color override support if no runtime API exists.

## Mode semantics

Use these fixed meanings:

- `idle`: ambient, calm, contemplative presence
- `listening`: receptive, grounded, attentive presence
- `thinking`: reflective, analytical, deep-processing presence
- `speaking`: expressive, warm, active-response presence

Default turn-state lifecycle:

1. user speaking -> `listening`
2. model reasoning -> `thinking`
3. model audio output -> `speaking`
4. completion/standby -> `idle`

Never reintroduce phoneme/viseme rendering for orb animation.

## Palette taxonomy

Use this color language when interpreting user requests:

- Heather Mist `#B4A8C4`: intuition, wisdom, contemplative calm
- Glen Green `#5F7F6F`: grounding, renewal, steadiness
- Loch Grey-Green `#7A9B8E`: depth, emotional perception
- Autumn Bracken `#A67B5B`: warmth, familiarity, comfort
- Silver Mist `#C8D3D5`: clarity, liminal light
- Rowan Berry `#8B4653`: protective intensity, resolve
- Moss Stone `#4A5D52`: permanence, reliability, deep grounding
- Dawn Light `#E8DED2`: hope, gentle illumination
- Peat Earth `#3D3630`: rooted, substantial stability

## Current mode to palette mapping

Use the current native orb palette groups:

- `idle`: Heather Mist + Loch Grey-Green + Silver Mist
- `listening`: Glen Green + Loch Grey-Green + Silver Mist
- `thinking`: Heather Mist + Rowan Berry + Loch Grey-Green
- `speaking`: Autumn Bracken + Rowan Berry + Dawn Light

If the user asks for colors currently not directly selectable (for example Moss Stone or Peat Earth), map to the nearest mode and state the mapping briefly.

## Intent mapping rules

Map common language to modes:

- calm, soft, neutral, quiet, ambient -> `idle`
- attentive, grounded, receptive, nurture, support -> `listening`
- deep, reflective, analytical, mysterious, introspective -> `thinking`
- warm, confident, energetic, expressive, encouraging -> `speaking`

Priority rules:

- explicit mode request beats adjective inference
- safety/system lifecycle states beat stylistic preference during active turn execution
- avoid mode flapping; keep a mode active long enough to be perceptible

## UX response policy

When user asks for a visual change:

1. apply nearest supported mode
2. acknowledge in one short sentence
3. if approximation was required, say what mode was used

Examples:

- "Set orb to a calmer ambient tone."
- "Using thinking mode for a deeper, more introspective look."

## Latency and performance policy

- prefer mode-level updates over frequent style churn
- keep transition signaling simple and deterministic
- never block turn completion on cosmetic animation detail
- if rendering slows, preserve conversation timing and degrade visuals first

## Engineering maintenance workflow

When extending orb behavior in code:

1. update native mode bridge in `native/macos/FaeNativeApp/Sources/FaeNativeApp/OrbWebView.swift`
2. update orb visuals in `native/macos/FaeNativeApp/Sources/FaeNativeApp/Resources/Orb/index.html`
3. keep mode enum synchronized in `native/macos/FaeNativeApp/Sources/FaeNativeApp/OrbWebView.swift`
4. keep UI controls synchronized in `native/macos/FaeNativeApp/Sources/FaeNativeApp/ContentView.swift`
5. verify transfer workflow still carries correct conversational state semantics

## Validation checklist

- macOS native shell builds (`native/macos/FaeNativeApp`)
- orb mode changes apply without JS bridge errors
- no phoneme/viseme dependency in visual pipeline
- command/turn latency remains within v0 budget

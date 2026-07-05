# Fae UX overhaul for non-computer users — plan (2026-07-05)

Governing principle: **the pill is the product.** Everything a non-expert needs
happens in conversation — Fae asks, they answer (voice or paste). Menus are an
escape hatch; Settings is the engineers' room. DESIGN.md binds throughout.

Ground truth (scouted 2026-07-05, file:line evidence in session records):
- Pill composer = single-line HTML `<input>` in the wry WebView (fae-ui-shell
  main.rs:1719); no masking, no multiline; expand/collapse binary; the
  click-to-collapse bug is real (main.rs:1779 only posts pill_expand).
- input_request has the right primitives (SecureField overlay, return_to_model
  off when secure, store_key→Keychain returning only a placeholder) but the
  protection is MODEL-DRIVEN: secure:false returns raw text to context
  (BuiltinTools.swift:830) and SensitiveDataRedactor covers only
  trace/analytics sinks — not context or memory capture.
- No brains discovery exists (ACP CLIs resolve by bare PATH; local servers need
  an explicit env URL; no key scanning — and dotfile key scanning stays OUT by
  design: Fae's own DamageControl protects those paths).
- DaemonSupervisor gives a real programmatic respawn path → "paste key → ready
  now" is achievable (no user-visible restart).
- Onboarding: the native 3-screen permissions modal is what actually runs on
  first launch; the conversational 8-step skill is only triggered from
  Settings, and its S2 (voice enrollment) + photo banner are dead post-S18.
- Menus: two near-duplicate layers (orb muda context menu ⊃ Swift menu bar);
  the 8 "Ask About…" items are canned prompt injections; 12 permission items
  across the layers; only 2 dev-tagged items today. Developer tab already
  gates on Option-key (SettingsView.swift:161) — the Advanced convention exists.
- Phase D gap that gates the cloud story: routing intelligence (commit 5) is
  unbuilt — StaticDirectPolicy always emits LocalOnly, so even a configured
  cloud lane never routes. The conversational setup must land WITH a minimal,
  honest routing hook.

## Waves (each: isolated worktree, gated, folded, pushed)

### W1 — Pill as THE input surface (fae-ui-shell + bridge)
- Composer: auto-growing textarea (multiline paste keeps newlines); long-paste
  chip ("pasted · N chars") instead of flooding; click-anywhere-to-collapse fix.
- `pill.request_input {request_id, prompt, secure, multiline}` command from
  Swift → composer swaps to masked (password-type) / prompted mode, Fae's
  prompt as caption; submit posts `input_response {request_id, text}` →
  RustUiShellController routes to InputRequestBridge (NOT injectText). The
  Swift overlay card remains the fallback when the orb host is absent.

### W2 — Structural secret safety (Swift)
- InputRequestTool.execute: run returned values through the credential
  detector (redactor patterns + entropy); suspicious value with secure:false →
  WITHHELD from model + model told to re-ask with secure+store_key. Safety is
  no longer the model's choice.
- Redaction pass at the MemoryOrchestrator capture boundary (defense in depth).
- Prompt-stack rule: asking for keys ⇒ input_request(secure, store_key);
  never ask the user to speak a secret aloud.

### W3 — Brains: discovery + conversational cloud add
- BrainScout (Swift manager + scheduler task, ToolAugmentationManager pattern):
  PATH-probe acp CLIs (claude/codex/gemini/copilot/pi/acpx), consented
  local-port probe for ollama :11434 / LM Studio :1234 (reuse the daemon's
  /v1/models parse shape), store as memory fact + prompt hint. NO dotfile/key
  scanning — for keys, Fae ASKS.
- Conversational OpenRouter flow: Fae pitches (privacy-first language, GDPR),
  input_request(secure, store_key: openrouter.apiKey), patchConfig
  privacy_lane, then a SILENT daemon respawn (terminate → launchAndConnect)
  → "ready now". Settings tab remains the engineer path.
- Minimal honest routing hook (Phase D commit-5 seed): plumb a per-turn
  route hint through inject_text so an explicit owner request ("ask your
  cloud friend…" / a pill chip shown only when cloud is configured) produces
  a RemoteAllowed decision; default remains local-always.

### W4 — Onboarding as a conversation
- First launch: shrink the native modal to mic permission + the local-first
  promise, then TRIGGER the conversational skill (today it never fires).
- Rewrite first-launch-onboarding SKILL.md: story-driven — name, city ("that's
  how I'll know your weather and your mornings"), what they do — each fact
  immediately demonstrated; PTT reality ("hold right Option, or press and hold
  my orb"); remove dead S18 steps (voice-enrollment beeps, photo banner).
- Add a location/city profile extractor to MemoryOrchestrator capture patterns.
- capability-discovery keeps the one-nudge drip; add cloud-brain + handoff to
  its pitch list.

### W5 — Menu purge + Advanced mode
- Orb context menu (primary): Talk to Fae · Settings… · ── · Hand off to…
  (when fleet) · Reset Conversation · Hide Fae · Stop · ── · Ask Fae for Help ·
  Rescue Mode… · Quit Fae. Removed: 6 permission items (→ conversation via JIT
  permissions + a Settings row), Ask About ×4 (→ one "Ask Fae for Help"),
  Edit Soul/Instructions + Settings (legacy) + Scheduler/Skills panels (→
  Advanced).
- Swift menu bar mirrors: App (About, Check for Updates, Settings…),
  Talk (Talk to Fae, Stop ⌘.), Help (Ask Fae for Help, Memory Inbox ⇧⌘M,
  Rescue Mode ⌘⌥R). Permissions submenu removed.
- Advanced: a Settings toggle (plus the existing Option-key convention)
  reveals the engineering items in both layers (Debug Console, Edit Soul/
  Instructions, legacy Settings, Scheduler/Skills panels, permission quick
  actions).

Sequencing: W1 + W2 + W5 in parallel (disjoint files), then W3 (needs W2's
safe input), then W4 (pitches W3's cloud flow last). Release-validation
checklist applies (menus/settings/approval surfaces change).

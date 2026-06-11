# The Great Cleanup — 2026-06-11

**Status:** Executing
**Mandate (owner):** Fae is a cross-platform, local, hugely-personalised **tool-calling
head butler** — not a hugely-capable local model. Orb-first UI only. Gemma 4 E4B
brain via the Rust daemon (mistral.rs). Nightly retraining. Skills: built-in,
self-written, and subscriptions to secure skill repos. x0x connects the user's
machines into one harness and connects Fae to other agents to communicate and
collaborate. Remove the old UI and dead pipelines so nothing can slip back.

## Phase C1 — Dead feature removal

1. **CoWork — full removal** per `cowork-removal-plan-2026-06-05.md`:
   `Cowork/` (all 12 files), `showLegacyCoworkUI` gate and every entry point,
   `SettingsOtherLLMsTab`, `SettingsSkillsChannelsWorkspace`, cowork
   conversation wiring in bridges/FaeCore/PipelineCoordinator
   (`makeCoworkToolExecutor`, `coworkExternal`, CoWork events), CoWork window
   controller + notifications. CoworkToolExecutor/security intercept goes with
   the feature (it gated external CoWork LLM calls only); OutboundExfiltration
   PII bridge stays only if used elsewhere — verify, else remove.
2. **Canvas auxiliary window** (butler redesign §4 removal list) and its
   AuxiliaryWindowManager routing.
3. **Legacy presets/config**: `saorsa_1_1_tiny` style aliases, dead config keys
   surfaced by the removals.
4. **Legacy ChannelManager** (superseded by ChannelGateway) if no live caller.

## Phase C2 — Old UI removal + orb resilience

**Policy decision:** the orb host is the ONLY product UI. On orb-host crash the
app does NOT show the old window — it **restarts the orb host** (3 attempts,
backoff; after that, a plain alert offering Quit/Retry). This replaces the
`onUnexpectedExit` show-old-window fallback added 2026-06-11.

Remove from the Swift app:
- Main-window product UI: ContentView orb hero, `NativeOrbView`,
  `FogCloudOrb.metal`, `NebulaOrb.metal`, OrbAnimation/OrbStateBridge render
  path (KEEP `OrbTypes` mode/feeling model — it drives the bridge to the orb
  host), `SubtitleOverlayView`, Swift conversation window/panel
  (`ConversationWindowView` — orb host transcript panel replaces it),
  `WindowStateController` collapse/compact machinery.
- KEEP in Swift (not UI-shell concerns): Settings window (all tabs that
  survive C1), approval/input overlay panels (`ApprovalOverlayController`/
  `InputOverlayView` — floating cards, product-critical), onboarding +
  enrollment/photo banners, debug console, menu bar/status items, Sparkle.
- `FaeRootView` reduces to: license gate + onboarding host + hidden-window
  shell for the panels that remain (or convert those to standalone panels and
  delete the main window entirely — agent's call, bias to deletion).

## Phase C3 — Pipeline cleanup

- Remove code only reachable from deleted UI (cowork conversation lanes,
  canvas events, `PipelineAuxBridgeController` canvas paths).
- KEEP: MLXLLMEngine (fallback + training substrate), full voice pipeline,
  memory, scheduler, skills, channels (gateway), DaemonLLMEngine lane.
- Delete dead event types/notifications after the UI removals; zero warnings.

## Phase C4 — Docs reorientation

- **README.md**: rewrite around the strategy — local cross-platform head
  butler; Gemma 4 tool-calling brain (mistral.rs daemon, llama.cpp fallback);
  orb-first UI; nightly personal retraining (LoRA, benchmark-gated); skills
  (29 built-in, write-your-own via forge, secure skill-repo subscriptions);
  **x0x**: ML-DSA-65 agent identity + identity cards, E2E PQC messaging,
  signed gossip topics, file sharing — connects the user's own machines into
  one harness and Fae to other agents for collaboration; privacy: everything
  local by default, voice identity is the security model.
- **CLAUDE.md**: update workflow (orb-first; `run-dev`/`run-native-with-ui-shell`
  both embed the orb host), remove CoWork sections, add daemon-LLM lane +
  Gemma 4 notes, remove deleted-file references from the inventory.
- **docs/**: move superseded docs to `docs/archive/` (CoWork guides, old UI
  docs); fix links; keep ADRs (historical record — add superseded notes,
  never delete).
- Obsidian vault sync for every doc changed.

## Invariants (every phase)

- `just build` zero errors/warnings; `swift test` no NEW failures (13 known
  unmasked T-suite failures are pre-existing; do not grow the set).
- `just check-ui-shell` and `cargo nextest run` (crates/) stay green.
- No `.unwrap()`/`fatalError()`/force-unwrap in production code.
- The app must still: launch orb-first, run the Gemma 4 daemon lane, fall
  back to MLX engine if daemon fails, complete onboarding, open Settings,
  show approval cards, quit cleanly.

## Completion note — C1/C2/C3 (2026-06-11)

Phases C1–C3 executed and committed on `main`:

- **C1** `629e7afc` — CoWork fully removed (Cowork/ 14 files, settings tabs,
  events, TestServer endpoints, menus, privacy-filter bridge, legacy preset
  alias, canvas aux window). Orb-host workspace snapshot types extracted to
  `Core/WorkspaceSnapshot.swift`. 70 files, −18,001 lines.
  Kept: `ChannelManager` (still the live channel runtime in FaeCore;
  ChannelGateway is not wired there yet).
- **C2** `c9815d89` — legacy Swift orb/main-window UI deleted (NativeOrbView,
  3 Metal shaders, OrbCrown, OrbAnimationState, SubtitleOverlay,
  ConversationWindowView, CanvasWindowView, LoadingCanvasContent, IntroCrawl,
  ProgressOverlay). Orb-host crash fallback replaced with auto-restart
  (3 attempts, exponential backoff, then Retry/Quit alert); dock reopen no
  longer resurrects the legacy window. The companion window survives as the
  reduced license/onboarding/Ask-Fae text surface (hidden while the orb host
  runs). 21 files, −5,064 lines. Smoke-tested via `just run-dev`.
- **C3** `9205984d` — dead canvas/conversation events, canvas voice commands,
  capabilities/permissions canvas HTML builders, and the TillDone canvas
  report removed; CanvasController slimmed to the inline activity feed.
  15 files, −587 lines.

Validation at C3: `just build` zero errors; `swift test` 3,185 tests with
1 pre-existing failure (DocsContractTests, docs under concurrent rewrite);
`VocabularyHarvestTests` skipped (Contacts TCC hang in the test environment);
`cargo nextest` 47/47; `just check-ui-shell` green. C4 (docs) handled
separately.

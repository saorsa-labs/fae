# CoWork Removal Plan

> Status: **Implementation plan** (2026-06-05) · Owner: David Irvine · Implements **D6** of
> [`conductor-positioning-and-scope-2026-06-05.md`](./conductor-positioning-and-scope-2026-06-05.md).
> Scope verified against source 2026-06-05. **Gated: do not delete until Tier-1 `delegate_to_mesh` ships** (users must never lose "reach a bigger brain").

## 1. Why & the one rule

CoWork's job — reach an external/bigger model — is superseded by the conductor (`delegate_to_mesh`/`orchestrate_work`) + x0x mesh + agentskills.io/MCP. Removing it **shrinks the threat surface** (deletes the synthetic `external_llm` provider path) and consolidates governance onto one path (conductor + GrantEnforcer).

**The one rule that makes this safe:** *delete the CoWork wrappers; retain the security guards they call, re-pointed at the conductor's cross-owner path.* CoWork is ~15.7k lines of UI/provider/workspace code wrapped around a thin security gate. The wrapper goes; the gate stays.

## 2. RETAIN — do not delete (corrected from source)

| Guard | Reality (verified) | Action |
|-------|--------------------|--------|
| **`DamageControlPolicy`** (`Tools/DamageControlPolicy.swift`) | **General** — `ToolExecutor` step 3 uses it; CoWork called `.evaluate(locality: .nonLocal)`. (An exploration pass reported "not found" — that is wrong; it exists and is core. **Verify before touching.**) | **RETAIN.** The `.nonLocal` path becomes the conductor's cross-owner egress check (grants doc §7). |
| **`PrivacyFilterBridge`** (`Runtime/PrivacyFilterBridge.swift`) | **General** PII subprocess daemon; only *instantiated* in `makeCoworkToolExecutor()` today | **RETAIN** the bridge; move instantiation out of CoWork into the conductor's egress membrane. |
| **`SecurityEventLogger`** | General append-only log; CoWork only contributes 4 event *strings* | **RETAIN** logger; remove only `cowork_pii_detected`/`cowork_allowed`/`cowork_blocked`/`cowork_injection_flagged`. |
| **`OutboundExfiltrationGuard`** | **ALREADY DELETED** (`FaeCore.swift:2763` notes removal; `outbound-recipients.json` gone) | None — just remove stale reference comments (`FaeCore.swift:2746, 2763`). |
| **`ConversationController`** | Shared type; CoWork holds one *instance* (`coworkConversation`) | **RETAIN** type; delete only the CoWork instance. |
| **Note/Import window** | `ImportWindowController` takes a `coworkWindow` param (`FaeApp.swift:573`) but note-import is a *separate* feature | **DECOUPLE, don't delete** — sever the `coworkWindow` dependency so import survives standalone (comment at `FaeApp.swift:486` already says it should work without CoWork). |

## 3. DELETE — the `Cowork/` target (14 files, ~11,868 LOC)

`native/macos/Fae/Sources/Fae/Cowork/`:
`ConversationCompressor.swift` · `CoworkExportPacket.swift` · `CoworkLLMProvider.swift` (1,066) · `CoworkModelOption.swift` · `CoworkModelRegistry.swift` · `CoworkRemoteModelCatalog.swift` · `CoworkToolExecutor.swift` (461 — extract guard wiring first, §2) · `CoworkToolExecutorError.swift` · `CoworkWindowController.swift` · `CoworkWorkspaceController.swift` (2,163) · `CoworkWorkspaceModels.swift` · `CoworkWorkspaceView.swift` (4,672) · `StreamingConsensusEngine.swift` · `WorkWithFaeWorkspace.swift` (1,423).

> Note: `StreamingConsensusEngine` + `ConversationCompressor` were CoWork-internal; confirm no non-CoWork importer before deleting (grep). If anything reuses them, lift them out first.

## 4. EDIT — external references (verified file:line)

**`FaeApp.swift`** — primary integration point:
- Properties: `coworkConversation` (141), `coworkWindow` (157), `openCoworkObserver` (178) → remove.
- Wiring: `conversationBridge.coworkConversationController = …` (244), `auxiliaryWindows.coworkWindowProvider = …` (252–253), CoWork window init block (312–322), observer for `.faeOpenCoworkRequested` (473–480) → remove.
- `ImportWindowController(coworkWindow:)` (573) → **decouple** param (§2).
- **`func openCoworkDesktop(...)` (769–778) → remove entire method.**
- Menu actions/items: `openCoworkDesktop(section: .scheduler)` (961), `.skills` (966), and the 4 menu items "Cowork Desktop / Cowork Model… / Toggle Cowork Inspector / Open Cowork Tools" (989–1004) → **remove**. Re-home the `.scheduler`/`.skills` destinations into the new Settings (UI redesign doc).

**`PipelineCoordinator.swift`**:
- `coworkToolExecutor` property (47–50) → remove.
- **`makeCoworkToolExecutor()` (697–~727) → remove**, but **hoist `PrivacyFilterBridge` + `DamageControlPolicy(.nonLocal)` instantiation** into the conductor's egress membrane (don't lose them).
- Inject-text comment (1214) → remove.

**`AuxiliaryWindowManager.swift`**: `coworkWindowProvider` (69), `coworkRoutingCancellable` (73), `isCoworkConversationActive` (75), `.faeCoworkConversationRoutingChanged` subscription (81–84), CoWork-preferring window anchoring (217–232) → remove/simplify to the canvas-less model (UI redesign removes the canvas/cowork aux window).

**`ConversationBridge.swift`**: `coworkConversationController` property → remove.

**`FaeCore.swift`**: stale guard comments (2746, 2763) → remove.

**`MemoryTypes.swift`**: `case coworkAttachment = "cowork_attachment"` (41) → remove; audit `MemoryOrchestrator.sourceLabel()` for the case.

**Notifications to delete** (FaeEvent / Name extensions): `faeOpenCoworkRequested`, `faeCoworkConversationRoutingChanged`, `faeCoworkOpenModelPickerRequested`, `faeCoworkToggleInspectorRequested`, `faeCoworkOpenUtilityRequested` (+ `faeCoworkWindowVisibilityChanged` if present).

**`FaeConfig`/Settings**: remove the **OtherLLMs** tab + any `[cowork]`/external-provider config (UI redesign doc deletes `SettingsOtherLLMsTab` + `SettingsSkillsChannelsWorkspace`).

## 5. TESTS — delete vs re-point

**Delete (12 files, ~3,230 LOC):** `CoworkLLMProviderTests`, `CoworkModelRegistryTests`, `CoworkWorkspaceControllerTests`, `CoworkWorkspaceModelsTests`, `WorkWithFaeWorkspaceTests` (×2), `EndToEndConversationRoutingFlowTests`, `CoworkPrivacyFilterTests`, `CoworkProviderConnectionTests`, `CoworkRemoteProviderTests` (1,083), `StreamingConsensusEngineTests`, `ThinkingLevelCoworkParityTests`.

**Edit / re-point (do NOT blindly delete):**
- **`CoWorkPreservedGatingTests.swift`** + **`DamageControlPolicyTests.swift`** → these assert the *guards still gate* — **rewrite to target the conductor's cross-owner path** instead of CoWork. This is the safety net proving the guards survived the move; it must stay green, re-pointed.
- `ConversationBridgeControllerTests`, `MemoryOrchestratorStaticTests` (163–164 `coworkAttachment`), `RuntimeContractTests`, `SpeechInputStageTests`, `VisionToolsPolicyTests`, `WindowStateControllerTests`, `ThinkingLevel*` → strip CoWork refs.

## 6. Sequencing (D6-gated)

1. **Pre:** conductor Tier-1 `delegate_to_mesh` exists (users keep "reach a bigger brain").
2. **Hoist guards:** move `PrivacyFilterBridge` + `DamageControlPolicy(.nonLocal)` wiring out of `makeCoworkToolExecutor()` into the conductor egress membrane; re-point `CoWorkPreservedGatingTests`/`DamageControlPolicyTests`. **Green build.**
3. **Decouple:** sever `ImportWindowController`↔`coworkWindow`; verify note-import works standalone.
4. **Delete UI/menus/windows:** FaeApp CoWork block + 4 menu items, AuxiliaryWindowManager routing, canvas aux window.
5. **Delete providers/workspace:** the 14 `Cowork/` files + 12 test files.
6. **Clean refs:** notifications, `coworkAttachment`, SecurityEventLogger event strings, stale comments, OtherLLMs/workspace settings tabs.
7. **Verify:** `just check` zero warnings; full validation per `app-release-validation.md` (this is a model/routing + approval/popup + settings change → all release-validation triggers fire).

## 7. Acceptance criteria

- [ ] `Cowork/` directory removed; build green, **zero warnings** (`RUSTFLAGS`/Swift parity).
- [ ] `DamageControlPolicy` + `PrivacyFilterBridge` retained and **exercised via the conductor's cross-owner path**, proven by the re-pointed gating tests.
- [ ] No reachable "reach external model" path bypasses the conductor + GrantEnforcer.
- [ ] Note/Import window works with CoWork gone.
- [ ] No dangling notifications / `coworkAttachment` / `cowork_*` log strings / OtherLLMs tab.
- [ ] Release-validation checklist passes (routing, approval/popup, settings, memory).
- [ ] CHANGELOG entry; version bump per VERSION file.

## 8. Risks

- **Guard loss (highest):** deleting `CoworkToolExecutor` before hoisting `PrivacyFilterBridge`/`DamageControlPolicy` wiring would silently drop PII/DamageControl on the *new* cross-owner path. Mitigation: §6 step 2 first, gated on re-pointed tests going green.
- **`DamageControlPolicy` "not found" report:** an exploration pass claimed it's absent — it isn't (CLAUDE.md + `DamageControlPolicyTests`). **Verify presence before editing** so the plan isn't built on a bad read.
- **Hidden reuse:** `ConversationCompressor`/`StreamingConsensusEngine`/`ConversationController` — grep for non-CoWork importers before deleting types.
- **BOM/CRLF:** many Swift files have BOM+CRLF — use Read/Edit tools, never bash sed (per project memory).

## 9. References
- `conductor-positioning-and-scope-2026-06-05.md` (D6), `conductor-capability-grants-2026-06-05.md` §7 (egress membrane — where the guards re-home), `butler-ui-redesign-2026-06-05.md` (settings/menu/window changes).
- `docs/checklists/app-release-validation.md`.
- Source: `Cowork/*`, `FaeApp.swift`, `PipelineCoordinator.swift`, `AuxiliaryWindowManager.swift`, `FaeCore.swift`, `MemoryTypes.swift`, `Tools/DamageControlPolicy.swift`, `Runtime/PrivacyFilterBridge.swift`, `Tools/SecurityEventLogger.swift`.

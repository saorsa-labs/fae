# Fae Positioning & Scope — Head Butler over the Mesh

> Status: **Decision record** (2026-06-05) · Owner: David Irvine · Decisions accepted in-session 2026-06-05.
> Anchors the conductor doc set: [`conductor-tier1-own-fleet`](./conductor-tier1-own-fleet-2026-06-05.md),
> [`conductor-capability-grants`](./conductor-capability-grants-2026-06-05.md),
> [`conductor-capability-advertisement`](./conductor-capability-advertisement-2026-06-05.md),
> [`conductor-phase2-async-orchestration`](./conductor-phase2-async-orchestration-2026-06-05.md),
> [`skill-and-tool-interop`](./skill-and-tool-interop-2026-06-05.md).

## 1. The repositioning

Fae moves from **oracle** (a local model that must know everything) to **head butler / housekeeper** (a small, personable, self-improving model that *knows her household, knows who to call, and manages the work*). She is not the smartest agent in the room; she is the one who runs the room — greets you, remembers you, and dispatches specialists (local, mesh, or hired skill) for anything heavy.

Rationale (validated this session): the agent harnesses (Hermes, OpenClaw, Codex, Claude Code) are converging into commodities; the unsolved, durable problem is **coordination** + **a personal, private, voice-first interface that grows with you**. Fae owns that.

## 2. Decisions (accepted 2026-06-05)

| # | Decision | Detail |
|---|----------|--------|
| D1 | **Butler brain = Gemma-4 4B (E4B)** | In-process mistral.rs; S13-proven (65 tok/s Metal, audio-in STT, tool calling). The butler routes/learns/self-tunes; it does **not** try to be great at code/math/research alone. |
| D2 | **Brain is swappable; Qwen3.5 is the bridge** | E4B drops in when the path is ready; current Swift app stays Qwen3.5. Engine is an adapter, never hard-wired. |
| D3 | **Adopt the Hermes *pattern*, do not run on Hermes** | Fae already has the Hermes-class runtime (two-lane delegation, self-authoring skills, FTS5+ANN memory, scheduler), more private/advanced. Hermes is reachable as a **Runner**, not a host. |
| D4 | **Two open "hire help" standards: agentskills.io + MCP** | Skills via agentskills.io; tools via MCP client. Fae can hire any capability without bespoke integration. Spec: `skill-and-tool-interop-2026-06-05.md`. |
| D5 | **Skill-import security policy (hard rule)** | Every imported skill passes Fae's **SHA-256 pin + `SkillSecurityReview`** *before activation*. agentskills.io's `skills-ref` validation is insufficient post-ClawHavoc (2,400 typosquatted malicious skills). |
| D6 | **Remove CoWork** | Superseded by the conductor + mesh + agentskills/MCP (§4). Deletes the `CoworkToolExecutor`/nonLocal external-call surface — a net security simplification. |
| D7 | **Radically simpler, emotive UI** | Orb + speech bubbles + minimal approval card. Settings collapse to an informational showcase + a few intensity controls. Brain/face split: thin client renders core state (§5). |

## 3. The moat (what stays differentiated — do NOT trade away)

These are the things no converging harness matches, and the reason Fae is not "just another agent":

- **On-device voice-first** — MLX Qwen3-ASR / Kokoro / ECAPA voice-identity. (Hermes voice = whisper+cloud, bolted on.)
- **Voice-identity as the security model** — recognised voice = owner; the gate, not a setting.
- **Nightly weight-level self-personalisation** — LoRA via TrainingBridge. (Hermes only captures trajectories; it does not train.) This is *how the butler becomes more personable each night.*
- **On-device Apple-Silicon (MLX)** — not vLLM/GPU-server.
- **Visual/camera/screen awareness.**
- **x0x PQC mesh + conductor + capability grants** — secure cross-machine agent coordination. (Hermes channels are a comms pipe; this is the "go further" layer.)

## 4. CoWork removal — what replaces it

CoWork existed to "reach a bigger brain" via external LLM calls. Every job it did is now covered, more cleanly:

| CoWork did | Replaced by |
|------------|-------------|
| Reach a bigger/remote model for an answer | `delegate_to_mesh` (Tier-1 sync) → home dense model / specialist agent |
| Run a body of external work | `orchestrate_work` (Phase-2 async) → symphony Runner (incl. Codex/Claude-Code/Hermes) |
| Pull in external capability | agentskills.io skills + MCP tools (D4), behind the security gate (D5) |
| External-call safety (PII/DamageControl `nonLocal`) | **Reused** as the cross-owner egress membrane (grants doc §7) — the guards survive; the CoWork *wrapper* is what's deleted |

**Net effect (verified 2026-06-05):** the `Cowork/` target (**14 files, ~11,868 LOC** + ~3,230 LOC tests) is removed; the *security guards it called* (`DamageControlPolicy`, `PrivacyFilterBridge` — both **general**, not CoWork-specific) are retained and re-pointed at the conductor's cross-owner path. (`OutboundExfiltrationGuard` is **already deleted** in the codebase.) Threat surface shrinks (no synthetic `external_llm` provider calls), governance consolidates onto one path (the conductor + GrantEnforcer).

> Migration note: removal is gated on the conductor Tier-1 path existing, so users never lose "reach a bigger brain." Sequence: ship `delegate_to_mesh` → hoist guards → migrate CoWork users → delete `Cowork/`. Full teardown: [`cowork-removal-plan-2026-06-05.md`](./cowork-removal-plan-2026-06-05.md). UI changes: [`butler-ui-redesign-2026-06-05.md`](./butler-ui-redesign-2026-06-05.md).

## 5. UI simplification mandate

The butler shows a **calm, emotive face, not a control panel.**

- **Keep:** the orb (already emotive — `OrbFeeling`/`OrbMode`/palette), speech bubbles (conversation), one approval/input card, a glanceable "who/what is active" (fleet presence + in-flight work, from x0x — see advertisement spec).
- **Cut:** the 16 settings tabs → an **informational showcase** (per the proactive-by-default philosophy: explain *what* each always-on capability does, no on/off toggles) + a handful of intensity controls (TTS speed, camera/screen interval, temperature). CoWork windows/canvas removed with D6.
- **Architecture:** this falls out of the brain/face split (headless core owns logic; thin client renders state). The thin face is deliberately minimal so it ports cheaply (SwiftUI+Metal on Apple; Dioxus/Tauri elsewhere).
- **Design authority:** all visuals follow `DESIGN.md` (Scottish palette, Instrument Serif display, no emoji in headers, no purple-blue gradients). A dedicated butler-UI redesign doc follows when we move on UI.

## 6. What Fae *is*, in one paragraph

Fae is a voice-first, on-device, self-fine-tuning **head butler**: a Gemma-4 4B brain with a Hermes-class agenting runtime she already has, who **speaks agentskills.io and MCP** so she can hire any skill or tool (each vetted by her own SHA-256 + security review), **delegates** reasoning and bodies of work to subagents, mesh agents, and Runners (including Hermes itself), **coordinates** her owner's whole fleet and granted peers over the **x0x** secure mesh, **self-improves nightly** to become more personable, and shows you a **calm, emotive face** instead of a settings panel.

## 7. Relationship to the rest of the design

- **Conductor docs (4):** unchanged; this records the *why* and the scope around them. The butler **is** the conductor; "hire help" = capability grants + skills/tools.
- **Headless core plan:** the brain/face split, mistral.rs engine, control plane — all already decided there; D1/D2/D7 align.
- **Governance (G5/W3/W4/G4):** unchanged and still binding; D5 and the CoWork-guard reuse sit under it.
- **Scope vs v1:** Apple+Linux first; Windows post-v1 (S11). Group/cross-owner features gated (TreeKEM + G5). Tier-1 own-fleet + skill/tool interop are the near-term shippable surface.

## 8. Open questions

1. **CoWork deprecation window** — hard-cut at the release that ships `delegate_to_mesh`, or a transition release where both exist? Lean: one transition release, then delete.
2. **Butler "personality" vs SOUL** — does the butler framing change the SOUL contract / directive defaults? Probably a SOUL refresh, not a structural change. Track for the UI redesign.
3. **Showcase settings content** — which always-on capabilities get a showcase card, and the copy for each (trust-building, per proactive-by-default philosophy).
4. **MCP + agentskills surfacing in the butler UI** — does the user see "installed skills / connected tools," or is it invisible butler housekeeping? Lean: a quiet "abilities" view, not a manager.

## 9. References
- Conductor set (4 docs above) + `skill-and-tool-interop-2026-06-05.md`.
- `cross-platform-engine-plan-2026-05-30.md` (engine, brain/face), `daemon-control-plane.md`, `docs/spikes/S13-mistralrs-eval.md` (E4B proof).
- Memory: `reference_hermes_agent.md`, `reference_openclaw_skills.md`, `project_conductor_strategy.md`, `feedback_personal_data_boundary.md`.
- `DESIGN.md` (visual authority), proactive-by-default philosophy (`CLAUDE.md`).

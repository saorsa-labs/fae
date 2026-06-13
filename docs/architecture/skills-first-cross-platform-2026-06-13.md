# Skills-First Cross-Platform Architecture — Decision & Staged Plan

**Date:** 2026-06-13
**Status:** ACCEPTED (owner decision, 2026-06-13 session)
**Owner question:** "Should Fae go full wgpu + wry + tao + muda UI, drop Swift, and use skills/tools for productivity apps the way hermes-agent does?"

## Decision

**Yes to the destination, staged by subtraction — not a rewrite.**

End state: **Rust daemon = brain** (LLM + TTS + audio capture), **Rust orb host = face**
(wgpu orb + wry panels), **skills/CLIs/APIs = hands** (productivity via portable
skills). Swift shrinks to a thin **macOS integration adapter** — which any
cross-platform architecture still needs *on macOS*: local Apple data access,
TCC permission flows, the perception backend, Keychain, Sparkle, and the MLX
LoRA training substrate.

Two findings from the evidence forced the "staged" shape:

1. **The skills pattern relocates platform-specific code; it does not eliminate
   it.** hermes-agent — the flagship skills-first harness — ships a
   `skills/apple/` category (apple-notes, apple-reminders, imessage, findmy,
   macos-computer-use): macOS-only skills for Apple-local data.
2. **wry on Linux (WebKitGTK) is currently the weakest link** — transparency
   repaint bugs, glitchy rendering, maintainer statements that they don't fully
   recommend Tauri on Linux today. Even hermes-agent ships its desktop app on
   **Electron**, not wry/tao. The pure-wgpu orb is safe everywhere; the wry
   *panels* are the cross-platform risk and must tolerate an opaque fallback.

## Evidence (verified 2026-06-13)

### How hermes-agent actually does productivity

| Need | Hermes' answer | Mechanism |
|---|---|---|
| User's email | `skills/email/himalaya` | himalaya — Rust IMAP/SMTP CLI, cross-platform; Gmail/iCloud via app passwords |
| Google calendar/mail/drive | `skills/productivity/google-workspace` | User creates their own Google Cloud OAuth client (~5 min); `gws` CLI or bundled Python client |
| Microsoft | `tools/microsoft_graph_client.py` | MS Graph API |
| Agent-owned inbox | AgentMail | Hosted cloud service over MCP |
| Apple notes/reminders/iMessage/Find My | `skills/apple/*` | **macOS-only skills** |

Trade-off vs Fae today: Hermes reads your calendar by OAuth-ing into Google's
cloud. Fae reads it through EventKit — local, TCC-gated, iCloud included,
**zero cloud credentials**. That is part of Fae's privacy story. CalDAV/CardDAV
skills can hit iCloud with app-specific passwords (local-ish, cross-platform),
which is the bridge.

### Fae's actual Swift surface (inventory, ~88K LOC)

- **Apple productivity integration is ONE file** — `Tools/AppleTools.swift`
  (EventKit calendar/reminders + Contacts). **Mail and Notes have no real
  framework integration today** — a mail skill is *net-new capability*, not a
  Swift replacement.
- Genuinely Apple-bound + load-bearing: ScreenCaptureKit + AX accessibility
  (perception/computer-use — needs per-OS backends on ANY stack), CoreML
  speaker encoder (echo rejection), MLX (VLM, embeddings, fallback LLM/TTS,
  **LoRA training substrate — the self-improvement moat; mistral.rs cannot
  train**), TCC flows, Keychain, Sparkle, NSEvent PTT monitor.
- ~19% of Swift trivially portable; ~24% is AppKit/SwiftUI UI the orb host can
  absorb; the rest is fallback engines or macOS-adapter code.
- As of 2026-06-13 the daemon is the **default** LLM + TTS lane
  (`llm/tts.useDaemonEngine = true`, fae-daemon bundled in the app).

### UI stack maturity

- **wgpu**: solid on Metal/Vulkan/DX12 — the orb ports cleanly. ✅
- **tao**: maintained (Tauri Programme); Linux via GTK3. **muda** needs GTK on
  Linux. Workable. ✅
- **wry/Linux = WebKitGTK**: transparent-window repaint bug (tauri#12800),
  glitchy rendering (tauri#13157), flicker with raw-display-handle + wgpu +
  transparency — *exactly our orb+pill pattern* (tauri#9220), maintainers
  "don't 100% recommend Tauri for Linux" (discussion #8524). Servo/Verso
  alternative webview is experimental, postponed to Tauri v3+. ⚠️

## Staged plan

| Phase | What | Why first |
|---|---|---|
| **P1 — Voice spine in Rust** | cpal capture + playback in fae-daemon | daemon + orb host = a complete *talking* Fae on any OS; capture is trivially portable post-S18 (16 kHz buffer + endpoint + WAV) |
| **P2 — Productivity skills wave** | mail (himalaya/IMAP), calendar (CalDAV incl. iCloud), contacts (CardDAV); agentskills.io-compatible frontmatter | Cross-platform hands that ALSO improve macOS Fae today (mail doesn't exist yet). Additive — `AppleTools.swift` stays as the privileged macOS path |
| **P3 — Orb host absorbs UI** | settings → onboarding → approvals as wry panels (macOS first) | Settings panel is implemented in the Rust orb host with Swift bridge sync; onboarding/approvals remain later work. Panels are designed opaque-fallback-tolerant |
| **P4 — Linux render spike** | orb + pill + one panel on Ubuntu (X11 + Wayland) | Measure WebKitGTK pain directly before committing panel architecture to it |
| **P5 — Ship gates** | release.yml daemon embedding; models.lock generation + fail-closed enforcement | Daemon-default cannot ship without them |

### What stays Swift (deliberately)

- `Tools/AppleTools.swift` — EventKit/Contacts local data access (delete only
  when CalDAV/CardDAV skills prove equivalent in daily use)
- Perception backend (ScreenCaptureKit + AX) — per-OS adapter seam
- MLX LoRA training substrate (TrainingAdapter: Apple = MLX, per the four-seam
  architecture) — **do not migrate**
- TCC, Keychain, Sparkle, PTT NSEvent monitor — macOS shell plumbing

### Success criteria

- A Linux build of fae-daemon + fae-ui-shell completes a spoken turn
  (mic → daemon ASR+LLM → TTS → speaker) with zero Swift.
- macOS Fae gains working mail + CalDAV calendar skills with credentials in
  Keychain, no cloud lock-in.
- The orb host owns Settings on macOS via a `settings_snapshot` / `settings_set` wry panel; onboarding/approvals remain next migration targets. AppKit windows for
  those are deleted.
- Release artifacts contain fae-daemon with an enforced models.lock.

## Risks

| Risk | Mitigation |
|---|---|
| WebKitGTK panel quality on Linux | Pure-wgpu pill/captions on Linux if needed; opaque-fallback design; watch Verso |
| IMAP/CalDAV cred UX vs "it just works" EventKit | Keep EventKit on macOS; skills are additive; document iCloud app-password flow in-skill |
| Subagent-built skills look right but don't run | Review gate: every skill demoed live against a real account before merge |
| Scope creep into MLX/training rewrite | Explicitly out of scope (moat; no Rust training lane exists) |

## Links

- Prior: `docs/architecture/cross-platform-go-nogo-2026-06-11.md`,
  `docs/architecture/full-cross-platform-ml-pipeline-2026-06-11.md`
- Execution: `docs/plans/skills-first-cross-platform-mega-prompt-2026-06-13.md`
- Hermes: github.com/NousResearch/hermes-agent (skills/, tools/, apps/desktop)
- wry/Linux: tauri#12800, tauri#13157, tauri#9220, tauri discussion #8524,
  NLnet Servo-webview-for-Tauri

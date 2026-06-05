I did not modify or write `/phase0/plans/g6-windows-scope.md` because the active role instructions explicitly say **do not modify files**. Findings are below for the parent to persist.

## Decisive recommendation

**Scope Windows out of v1.**  
Do not assign Windows v1 acceptance criteria yet. The current evidence supports Apple + Linux as the only credible v1 platform targets. Windows should become a **post-v1 tracked workstream** with explicit proof gates before it can be marketed as supported.

## Recommended G6 paragraph

> **G6 — Windows decision:** Windows is **out of v1 scope**. v1 targets are Apple + Linux only. This is not a rejection of Windows as a future platform; it is a scope-control decision because the current evidence base is Apple/Linux-heavy: `x0x/docs/overview.md` lists install requirements as “Linux or macOS,” x0x API token paths are documented only for Linux/macOS, the current Fae README says “No Windows. No Linux builds,” and the Dioxus/Tauri always-on desktop client has not been proven for Fae’s daemon/audio/control-plane requirements on Windows. Windows may enter a later release only after a dedicated platform spike proves x0x, the Rust daemon, audio, model runtime, installer/autostart, local control-plane security, and thin UI behavior on a real Windows machine.

## Acceptance criteria if Windows is later kept

For a future Windows milestone, require all of:

1. `x0xd` builds and runs on Windows on real hardware/VM.
2. Direct QUIC/x0x messaging works Windows↔macOS and Windows↔Linux.
3. Fae headless Rust daemon builds and passes smoke tests on Windows.
4. Audio capture/playback works through the daemon, not the UI.
5. E4B + dense driver path works or has documented Windows fallback.
6. Local control plane matches macOS/Linux security: loopback bind, bearer auth, WebSocket auth, token storage ACLs, origin policy.
7. Dioxus or Tauri thin client runs as an always-on app with tray/autostart/reconnect behavior.
8. Installer, update, logs, crash recovery, and uninstall paths are documented.
9. CI includes at least `cargo check`, tests, packaging smoke, and one live Windows validation script.
10. Release docs clearly mark Windows as supported only after all above pass.

## Key risks

- **x0x platform gap:** `../x0x/docs/overview.md` explicitly requires “Linux or macOS”; Windows is not documented as supported.
- **UI maturity gap:** Rev 13 says Linux/Windows use Dioxus or Tauri, but the S2 selection/proof is still pending.
- **Audio/runtime gap:** Always-on mic, daemon-owned audio, model runtime, and autostart behavior are all OS-sensitive.
- **Security gap:** Windows token storage/ACL/origin behavior needs its own control-plane design, not copy-paste from Unix/macOS.
- **Scope creep:** Keeping Windows in v1 would expand Phase 0 and Phase 3 substantially without comparable evidence.

## Tracking issue text

**Title:** Post-v1 Windows platform proof for Fae headless core

**Body:**

Windows is intentionally out of v1. v1 targets Apple + Linux only.

Before Windows can be added to a supported release, prove the full platform stack on real Windows hardware/VM:

- x0xd builds, installs, starts, and passes health checks.
- x0x direct QUIC messaging works Windows↔macOS and Windows↔Linux.
- Fae Rust daemon builds and runs.
- Daemon-owned audio capture/playback works.
- Model runtime path works or has a documented fallback.
- Local control plane has Windows-specific token storage, ACLs, loopback bind, bearer auth, WS auth, and origin policy.
- Dioxus/Tauri thin client supports always-on behavior, tray/autostart, reconnect, and crash recovery.
- Installer/update/uninstall paths exist.
- CI and live validation cover Windows.

Do not market Windows as supported until all criteria pass.
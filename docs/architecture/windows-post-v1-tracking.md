# Post-v1 Windows Platform Proof — Tracking Issue Draft

Windows is intentionally out of v1. v1 targets Apple + Linux only.

Before Windows can be added to a supported release, prove the full platform stack on real Windows hardware or VM:

- `x0xd` builds, installs, starts, and passes health checks.
- x0x direct QUIC messaging works Windows↔macOS and Windows↔Linux.
- Fae Rust daemon builds and runs.
- Daemon-owned audio capture/playback works.
- Model runtime path works or has a documented fallback.
- Local control plane has Windows-specific token storage, ACLs, loopback bind, bearer auth, WS auth, and origin policy.
- Dioxus/Tauri thin client supports always-on behavior, tray/autostart, reconnect, and crash recovery.
- Installer/update/uninstall paths exist.
- CI and live validation cover Windows.

Do not market Windows as supported until all criteria pass.

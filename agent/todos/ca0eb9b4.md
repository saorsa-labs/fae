{
  "id": "ca0eb9b4",
  "title": "Step 4: Retire Swift orb-drive + pass daemon paths",
  "tags": [
    "swift",
    "retire",
    "orb-state"
  ],
  "status": "open",
  "created_at": "2026-06-17T07:11:25.779Z"
}

Retire Swift orb-drive: remove OrbStateBridgeController mode driving (thinking/speaking/idle + daemon grace handlers) and RustUiShellController V4 relay (sendAudioLevel, .faeDaemonAudioLevel/Ended sinks). Keep Swift↔orb for: launching host, passing daemon socket/token (env at spawn: FAE_DAEMON_SOCK/FAE_DAEMON_TOKEN), window show/hide, menu actions, PTT listening signal. Verify orb works with Swift NOT driving mode. grep: no orbState.mode = in orb-drive path.

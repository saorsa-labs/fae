# Skills-first cross-platform P3 report — Orb-owned Settings panel

Date: 2026-06-13

## Summary

P3 moves the adjustable Settings surface into the Rust orb host as an opaque `wry` panel while keeping the SwiftUI Settings window available as **Settings (legacy)…**. Swift remains authoritative for persistence and policy; the Rust panel receives `settings_snapshot` bridge messages and sends `settings_set { key, value }` events back to `FaeCore.patchConfig`.

Implemented keys include tool access mode, thinking depth, LLM temperature, TTS speed, awareness intervals/pause toggles, and privacy posture. Always-on capability summaries render as informational cards, not authority toggles.

## Changed files

```text
native/macos/Fae/Sources/Fae/Core/FaeCore.swift
native/macos/Fae/Sources/Fae/FaeApp.swift
native/macos/Fae/Sources/Fae/RustUiShellController.swift
native/rust/fae-ui-shell/src/main.rs
native/rust/fae-ui-shell/src/menu.rs
native/rust/fae-ui-shell/src/protocol.rs
```

`git diff --stat` at validation time:

```text
 native/macos/Fae/Sources/Fae/Core/FaeCore.swift    | 217 ++++++++++++++++++
 native/macos/Fae/Sources/Fae/FaeApp.swift          |   5 +-
 .../Fae/Sources/Fae/RustUiShellController.swift    |  80 ++++++-
 native/rust/fae-ui-shell/src/main.rs               | 248 ++++++++++++++++++++-
 native/rust/fae-ui-shell/src/menu.rs               |   5 +
 native/rust/fae-ui-shell/src/protocol.rs           |  66 ++++++
 6 files changed, 617 insertions(+), 4 deletions(-)
```

## Live verification

Launch command:

```bash
source ~/.secrets 2>/dev/null || true; just run-dev
```

Launch tail:

```text
✓ Bundle assembled: native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app (v0.8.189)
  → Embedded fae-ui-shell
  → Embedded fae-daemon
✓ Signed: native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app
✓ Fae (DEV) launched — logs: tail -f /tmp/fae-dev.log
  Data: ~/Library/Application Support/fae-dev/
  Vault: ~/.fae-vault-dev/
```

Panel opened from the orb right-click menu. Window enumeration after opening:

```text
id=16660 owner=Fae name= bounds={ Height = 48; Width = 380; X = 823; Y = "-823"; }
id=16671 owner=Fae name= bounds={ Height = 712; Width = 880; X = 573; Y = "-1248"; }
id=16659 owner=Fae name= bounds={ Height = 420; Width = 420; X = 803; Y = "-1175"; }
```

`id=16671` is the Rust-owned Settings panel. `screencapture` was attempted but the local macOS session denied capture:

```text
could not create image from window
screencapture_exit=1
could not create image from display
full_screencapture_exit=1
```

Accessibility inspection verified rendered controls inside the real panel:

```text
role=AXHeading title=Playback speed value=3 pos=(1040,-881) size=(162,17)
role=AXButton title=− value= pos=(1216,-876) size=(34,31)
role=AXTextField title= value=1.10 pos=(1256,-878) size=(110,35)
role=AXButton title=+ value= pos=(1372,-876) size=(34,31)
```

Panel → Swift two-way bridge proof (`tts.speed` stepped from 1.10 to 1.15, then back to 1.10):

```text
$ grep -n "speed" "$HOME/Library/Application Support/fae-dev/config.toml"
44:speed = 1.1

# clicked the Settings panel + stepper
$ grep -n "speed" "$HOME/Library/Application Support/fae-dev/config.toml"
44:speed = 1.15

# clicked the Settings panel − stepper
$ grep -n "speed" "$HOME/Library/Application Support/fae-dev/config.toml"
44:speed = 1.1
```

Log excerpt:

```text
2026-06-13 12:02:44.129 Fae[61510:27114991] RustUiShellController: settings_set received key=tts.speed
2026-06-13 12:02:44.132 Fae[61510:27114991] FaeCore: config persisted (config.patch.tts.speed)
2026-06-13 12:02:44.132 Fae[61510:27114991] RustUiShellController: settings_set applied key=tts.speed
2026-06-13 12:02:44.132 Fae[61510:27114991] RustUiShellController: settings_snapshot sent sections=4 cards=4
2026-06-13 12:04:05.150 Fae[61510:27114991] RustUiShellController: settings_set received key=tts.speed
2026-06-13 12:04:05.151 Fae[61510:27114991] FaeCore: config persisted (config.patch.tts.speed)
2026-06-13 12:04:05.151 Fae[61510:27114991] RustUiShellController: settings_set applied key=tts.speed
2026-06-13 12:04:05.152 Fae[61510:27114991] RustUiShellController: settings_snapshot sent sections=4 cards=4
```

Panel reflection after reverting:

```text
role=AXTextField title= value=1.10 pos=(1256,-878) size=(110,35)
```

Orb gesture regression proof:

```text
2026-06-13 12:06:09.514 Fae[61510:27114991] GlobalHotkeyManager: PTT press (keyCode 61)
2026-06-13 12:06:09.514 Fae[61510:27115469] PipelineCoordinator: PTT capture started (holdMode=1)
2026-06-13 12:06:10.303 Fae[61510:27114991] GlobalHotkeyManager: PTT release (keyCode 61)
2026-06-13 12:06:10.303 Fae[61510:27115464] PipelineCoordinator: PTT capture finished (stop): 11200 samples, speech=0
2026-06-13 12:06:33.657 Fae[61510:27115477] RustUiShell stderr: [gesture] long-press hold fired → talk_start
2026-06-13 12:06:33.657 Fae[61510:27114991] RustUiShellController: talk_start received
2026-06-13 12:06:33.657 Fae[61510:27115477] PipelineCoordinator: PTT capture started (holdMode=1)
2026-06-13 12:06:34.114 Fae[61510:27115476] RustUiShell stderr: [gesture] long-press release → talk_stop
2026-06-13 12:06:34.114 Fae[61510:27114991] RustUiShellController: talk_stop received
2026-06-13 12:06:34.114 Fae[61510:27115476] PipelineCoordinator: PTT capture finished (stop): 6400 samples, speech=0
```

## Validation

### `just check-ui-shell`

```text
cd native/rust/fae-ui-shell && cargo fmt --all
cd native/rust/fae-ui-shell && cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.67s
cd native/rust/fae-ui-shell && cargo check --workspace --all-targets
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.22s
```

Known upstream warning remains from `block v0.1.6` future-incompatibility.

### `cd native/macos/Fae && swift test --skip VocabularyHarvestTests`

```text
Test Suite 'FaePackageTests.xctest' passed at 2026-06-13 12:09:12.346.
	 Executed 3088 tests, with 0 failures (0 unexpected) in 116.803 (116.972) seconds
✔ Test run with 53 tests in 6 suites passed after 0.050 seconds.
```

### `cd crates && just check`

```text
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-features
...
test result: ok. 13 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
...
```

### `just check`

Attempted after quitting the dev app. It still hit the known local Contacts/CoreData XPC/TCC failure and timed out at 1200s:

```text
CoreData: error: Failed to create NSXPCConnection
CoreData: error: addPersistentStoreWithType:configuration:URL:options:error: returned error NSCocoaErrorDomain (134060)
CoreData: error: URL: file:///Users/davidirvine/Library/Application%20Support/AddressBook/AddressBook-v22.abcddb
Command timed out after 1200 seconds
```

The Swift suite itself passed with `swift test --skip VocabularyHarvestTests`, which is the documented local workaround for the TCC/Contacts hang.

## Notes / residual risk

- The legacy SwiftUI Settings window remains available via **Settings (legacy)…**.
- The Rust panel intentionally renders opaque; it does not depend on transparent webview composition.
- The panel originally re-requested snapshots after every refresh; that caused a bridge loop during live testing. The auto-request was removed, leaving explicit Swift menu snapshot pushes and a manual Refresh button.
- The requested self-config typed-turn revert was not used; the value was reverted through the same Rust Settings panel after proving panel → config → panel sync. Local OpenAI-compatible runtime auth does not expose the random bearer token in logs, and `GET /v1/models` correctly returned 401 without it.

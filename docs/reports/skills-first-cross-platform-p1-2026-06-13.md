# PHASE P1 REPORT — cpal capture + playback in fae-daemon

## 1. What changed

`git add -N ... && git diff --stat`:

```text
 crates/Cargo.lock                                  | 295 ++++++++-
 crates/Cargo.toml                                  |   1 +
 crates/README.md                                   |   3 +-
 crates/fae-audio/Cargo.toml                        |  14 +
 crates/fae-audio/src/lib.rs                        | 689 +++++++++++++++++++++
 crates/fae-control-plane/src/lib.rs                |  58 +-
 crates/fae-daemon/Cargo.toml                       |   1 +
 crates/fae-daemon/scripts/fae_audio_repro.py       | 122 ++++
 crates/fae-daemon/src/diagnostic.rs                |   9 +-
 crates/fae-daemon/src/main.rs                      |   5 +-
 crates/fae-daemon/src/session.rs                   | 156 ++++-
 crates/fae-daemon/src/transport.rs                 |  10 +-
 docs/CHANGELOG.md                                  |  10 +
 .../skills-first-cross-platform-p1-2026-06-13.md   | 321 ++++++++++
 14 files changed, 1663 insertions(+), 31 deletions(-)
```

Summary:

- Added `crates/fae-audio`, a cpal-backed portable audio crate. I chose a new crate to keep cpal/device/WAV/resampling code isolated from control-plane session dispatch.
- Added daemon commands `audio.devices`, `audio.capture_start`, `audio.capture_stop`, and `audio.play` on the existing NDJSON control plane; kept legacy aliases `audio.start_capture`, `audio.stop_capture`, and `audio.playback_control` mapped to the same scopes/handlers.
- Added `AudioCapture`/`AudioPlayback` command-scope wiring and explicit tests for auth/scope rejection.
- Added unit coverage for WAV encode round-trip, 48 kHz → 16 kHz sine resampling correctness, and capture-cap reaping.
- Added live repro script: `crates/fae-daemon/scripts/fae_audio_repro.py`.
- Updated `docs/CHANGELOG.md`, `crates/README.md`, and matching Obsidian mirrors.

## 2. Validation

### `cd crates && just check && cargo check --workspace --all-targets`

Command:

```bash
cd crates && just check && cargo check --workspace --all-targets
```

Tail/output:

```text
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.26s
cargo test --all-features
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.24s
     Running unittests src/lib.rs (target/debug/deps/fae_audio-6679fbfb2401edc2)

running 4 tests
test tests::bad_wav_is_rejected ... ok
test tests::capture_cap_reaping_marks_then_removes_finished_sessions ... ok
test tests::wav_encode_round_trip ... ok
test tests::resample_48k_to_16k_preserves_sine_frequency ... ok

test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running unittests src/lib.rs (target/debug/deps/fae_control_plane-603b68a25dd6ec79)

running 22 tests
...
test result: ok. 22 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running unittests src/main.rs (target/debug/deps/fae_daemon-45d9ac8fc793d714)

running 19 tests
...
test session::tests::audio_devices_uses_status_scope ... ok

test result: ok. 19 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.28s

     Running unittests src/lib.rs (target/debug/deps/fae_engine-f8ff397b585951e0)

running 13 tests
...
test result: ok. 13 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running unittests src/lib.rs (target/debug/deps/fae_envelope_gate-cd42e0b24ef90da0)

running 7 tests
...
test result: ok. 7 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

   Doc-tests fae_audio

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

   Doc-tests fae_control_plane
...
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.23s
```

### `just check-ui-shell`

Command:

```bash
just check-ui-shell
```

Tail/output:

```text
cd native/rust/fae-ui-shell && cargo fmt --all
cd native/rust/fae-ui-shell && cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.19s
warning: the following packages contain code that will be rejected by a future version of Rust: block v0.1.6
note: to see what the problems were, use the option `--future-incompat-report`, or run `cargo report future-incompatibilities --id 1`
cd native/rust/fae-ui-shell && cargo check --workspace --all-targets
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.09s
warning: the following packages contain code that will be rejected by a future version of Rust: block v0.1.6
note: to see what the problems were, use the option `--future-incompat-report`, or run `cargo report future-incompatibilities --id 1`
```

### Root Swift validation

Commands:

```bash
just build
cd native/macos/Fae && swift test --skip VocabularyHarvestTests
just check
```

`just build` passed (xcodebuild warning only):

```text
cd native/macos/Fae && xcodebuild build -scheme Fae -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -quiet
2026-06-12 23:57:09.849 xcodebuild[82029:25723771] [MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.
--- xcodebuild: WARNING: Using the first of multiple matching destinations:
{ platform:macOS, arch:arm64, id:00006050-001C08DA01F9401C, name:My Mac }
{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:00006050-001C08DA01F9401C, name:My Mac }
{ platform:macOS, arch:arm64, variant:DriverKit, id:00006050-001C08DA01F9401C, name:My Mac }
```

`swift test --skip VocabularyHarvestTests` passed:

```text
Test Suite 'FaePackageTests.xctest' passed at 2026-06-12 23:57:01.756.
	 Executed 3087 tests, with 0 failures (0 unexpected) in 119.082 (119.249) seconds
Test Suite 'Selected tests' passed at 2026-06-12 23:57:01.757.
	 Executed 3087 tests, with 0 failures (0 unexpected) in 119.082 (119.250) seconds
...
✔ Suite "GlobalHotkeyManager PTT" passed after 0.040 seconds.
✔ Suite "MissedWakeStore" passed after 0.044 seconds.
✔ Test run with 53 tests in 6 suites passed after 0.044 seconds.
```

Exact `just check` still timed out after 900 s in Swift tests while repeatedly trying to open Contacts/CoreData XPC stores. This is unrelated to the Rust daemon/audio changes and matches the plan's TCC/contact-test gotcha class.

Tail:

```text
2026-06-13 00:09:10.504 xctest[82533:25727794] CoreData: XPC: Unable to load metadata: Error Domain=NSCocoaErrorDomain Code=134060 "A Core Data error occurred." UserInfo={Problem=Unable to send to server; failed after 8 attempts.}
CoreData: error: Failed to create NSXPCConnection
CoreData: error: addPersistentStoreWithType:configuration:URL:options:error: returned error NSCocoaErrorDomain (134060)
CoreData: error: userInfo:
CoreData: error: 	Problem : Unable to send to server; failed after 8 attempts.
CoreData: error: storeType: NSXPCStore
CoreData: error: configuration: (null)
CoreData: error: URL: file:///Users/davidirvine/Library/Application%20Support/AddressBook/Sources/A8366A48-1C9E-4BB2-9026-821E1FD9B6D5/AddressBook-v22.abcddb
CoreData: annotation: options:
CoreData: annotation: 	NSReadOnlyPersistentStoreOption : 0
CoreData: annotation: 	NSXPCStoreServerEndpointFactory : <CNCDRemotePersistentStoreEndpointFactory: 0x96e63af00>
CoreData: annotation: 	skipModelCheck : 1
CoreData: annotation: 	NSPersistentHistoryTrackingKey : 1
...
Command timed out after 900 seconds
```

### Cross-compile proof

Command:

```bash
cd crates && cargo zigbuild --target x86_64-unknown-linux-gnu -p fae-daemon
```

Result: blocked locally before linking because macOS host lacks a Linux ALSA/pkg-config sysroot. The failure is from `alsa-sys` build-script discovery, not Rust typechecking or codegen.

Tail:

```text
error: failed to run custom build command for `alsa-sys v0.3.1`

Caused by:
  process didn't exit successfully: `/Users/davidirvine/Desktop/Devel/projects/fae/crates/target/debug/build/alsa-sys-c6708fe4e421465b/build-script-build` (exit status: 101)
...
  thread 'main' ... pkg-config has not been configured to support cross-compilation.

  Install a sysroot for the target platform and configure it via
  PKG_CONFIG_SYSROOT_DIR and PKG_CONFIG_PATH, or install a
  cross-compiling wrapper for pkg-config and set it via
  PKG_CONFIG environment variable.
```

Retry with `PKG_CONFIG_ALLOW_CROSS=1` reached the next host issue:

```text
Could not run `... pkg-config --libs --cflags alsa`
The pkg-config command could not be found.
Try `brew install pkgconf` if you have Homebrew.
```

Local container fallback check:

```bash
command -v docker || command -v podman || command -v colima || true
```

Output was empty, so no local Linux container runtime was available for a native `libasound2-dev pkg-config` build.

## 3. Live evidence

### Daemon startup sandbox

Command:

```bash
TEST_HOME=/tmp/fae-audio-p1-home
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME"
cd crates
HOME="$TEST_HOME" FAE_NO_PARENT_WATCH=1 FAE_TTS=mock target/debug/fae-daemon > /tmp/fae-audio-p1-daemon.log 2>&1 &
echo $! > /tmp/fae-audio-p1-daemon.pid
```

Daemon log:

```text
fae-daemon (Phase 1, chunk 2a) — protocol v2
run dir : /tmp/fae-audio-p1-home/Library/Application Support/fae/run (0700)
token   : /tmp/fae-audio-p1-home/Library/Application Support/fae/run/bootstrap.token (0600)
engine  : mock (mock-echo)
tts     : mock (mock-tts)
audit   : /tmp/fae-audio-p1-home/Library/Application Support/fae/run/audit.jsonl (jsonl)
client  : authenticate with {"command":"session.authenticate","payload":{"client_id":"swift-frontend-bootstrap","token":<file>}}

fae-daemon: listening on /tmp/fae-audio-p1-home/Library/Application Support/fae/run/fae-daemon.sock (NDJSON)
```

### Capture → save WAV → playback → audio turn → TTS → playback

Command:

```bash
HOME=/tmp/fae-audio-p1-home python3 crates/fae-daemon/scripts/fae_audio_repro.py \
  --home /tmp/fae-audio-p1-home \
  --out /tmp/fae-cpal-capture.wav \
  --capture-seconds 1.5
```

Transcript:

```text
session.authenticate -> {"ok": true, "request_id": "r1", "result": {"authenticated": true, "client_id": "swift-frontend-bootstrap"}, "v": 2}
audio.devices -> {"ok": true, "request_id": "r2", "result": {"inputs": ["David’s iPhone Microphone", "MacBook Pro Microphone", "Microsoft Teams Audio"], "outputs": ["MacBook Pro Speakers", "Microsoft Teams Audio"]}, "v": 2}
audio.capture_start -> {"ok": true, "request_id": "r3", "result": {"capture_id": "cap-1"}, "v": 2}
Speak now for 1.5s...
audio.capture_stop -> {"ok": true, "request_id": "r4", "result": {"duration_ms": 1504, "sample_rate": 16000, "wav_base64": "UklGRiS8AABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQC8AAB5AHIBfAFhAS4B6ACSAC8A4P+//8D/yv/c//X/AQD2/+7/6P/Z/8j/wP+8/7v/vf/M/+b/FwA+ACUA/f8dAGcAbAD3/1z/Af/7/hr/OP91/wcAugAGAbcAGwCL/w3/ZP6e/Sj9Xf0k/hf/3v+AAB8BjwGGAQMBTgCs/yf/sP5R/kP+p/5C/7r/3v/D/5P/Rf/P/kj+7v3+/X7+Rf81AD8BQgIGA2QDUgPsAmIC0AE6AbIAYABWAHgAiwBxADEA1/9i/83+Jv6n/Yn9z/1c/hT/7f/QAJ8BKAJRAikC1QF0ARMBxgCbAJIAqgDVAPEA1ABtANr/T//w/q3+cv5d/o7+B/+d/yEAdwCeAKAAiwBsAE0AQwBNAFwAbgCIAJoAjgBaAP3/ff8F/7z+pv6s/tb+NP+k/wYATgB8AJQAmwCPAHIAXgBnAIAAkgDLALAAWQBhAEsARwA+ADcAMQArACYAIQAdABsAGwAcABwAHAAaABgAFAAPAAgAAwD+//r/9//1//T/9P/0//P/8v/w/+//7f/s/+z/7P/r/+v/6//q/+r/6v/q/+n/6f/p/+n/6f/o/+j/6P/o/+j/6P/o/+f/5//n/+f/5//n/+f/5//n/+f/5//n/+f/5//n/+f/5//o/+j/6P/o/+j/6P/o/+n/6f/p/+n/6f/p/+r/6v/q/+r/6v/r/+v/6//r/+z/7P/s/+z/7f/t/+3/7v/u/+7/7v/v/+//7//w//
saved_wav -> channels=1 rate=16000 frames=24064 duration=1.504s
audio.play -> {"ok": true, "request_id": "r5", "result": {"played_ms": 1504}, "v": 2}
conversation.inject_text -> {"ok": true, "request_id": "r6", "result": {"finish_reason": "stop", "text": "echo: [audio:48172 bytes] ", "tool_calls": []}, "v": 2}
heard_turn -> {"finish_reason": "stop", "text": "echo: [audio:48172 bytes] ", "tool_calls": []}
tts.synthesize -> {"ok": true, "request_id": "r7", "result": {"sample_rate": 24000, "wav_base64": "UklGRgQCAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YeABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}, "v": 2}
audio.play -> {"ok": true, "request_id": "r8", "result": {"played_ms": 10}, "v": 2}
```

Audit log with timestamps:

```text
2026-06-12T23:34:25.215000 session.authenticate allow allow
2026-06-12T23:34:25.216000 audio.devices allow allow
2026-06-12T23:34:25.371000 audio.capture_start allow allow
2026-06-12T23:34:26.970000 audio.capture_stop allow allow
2026-06-12T23:34:27.026000 audio.play allow allow
2026-06-12T23:34:28.603000 conversation.inject_text allow allow
2026-06-12T23:34:28.610000 tts.synthesize allow allow
2026-06-12T23:34:28.611000 audio.play allow allow
```

Shutdown by exact PID:

```text
PID=$(cat /tmp/fae-audio-p1-daemon.pid); kill "$PID"
stopped 50979
```

## 4. Deviations from prompt + why

- `fae-audio` is a new crate. This keeps the cpal worker, WAV parsing/encoding, and resampling out of `fae-daemon` session dispatch.
- The live end-to-end `[heard]:` transcript was exercised with the daemon mock engine (`echo: [audio:48172 bytes]`) rather than a completed real Gemma turn. I attempted `FAE_MODEL_ID=google/gemma-4-E4B-it` with the cached HF repo, but daemon startup remained at `engine  : loading mistral.rs model google/gemma-4-E4B-it (this can take a while)…` for ~10 minutes with no control socket, so I killed the exact PID and kept the mock proof as the audio-lane evidence.
- Cross-compilation is blocked by host sysroot tooling (`alsa-sys` requires Linux ALSA pkg-config/sysroot on this macOS machine). The code path compiles locally for macOS; `cd crates && just check` is green.
- Exact root `just check` timed out in Swift Contacts/CoreData XPC/TCC access, outside the Rust P1 changes. `just build` and the documented local `swift test --skip VocabularyHarvestTests` path passed.

## 5. Known gaps / follow-ups

- Configure a Linux ALSA sysroot or run the cross-compile proof on an actual Linux builder to satisfy the `cargo zigbuild --target x86_64-unknown-linux-gnu -p fae-daemon` gate.
- Re-run the live repro with `FAE_MODEL_ID=google/gemma-4-E4B-it` and real TTS if/when local model weights are available; current proof uses mock engine/TTS.
- `audio.play` is intentionally blocking v1 and uses WAV payloads only.
- No daemon-side VAD/AEC/barge-in streaming was added (out of scope for P1).

## 6. Docs touched + Obsidian notes updated

Repo docs touched:

- `docs/CHANGELOG.md`
- `crates/README.md`
- `docs/reports/skills-first-cross-platform-p1-2026-06-13.md`

Obsidian mirrors updated:

- `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Ideas/Saorsa Labs/Projects/fae/docs/CHANGELOG.md`
- `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Ideas/Saorsa Labs/Projects/fae/crates/README.md`
- `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Ideas/Saorsa Labs/Projects/fae/docs/reports/skills-first-cross-platform-p1-2026-06-13.md`

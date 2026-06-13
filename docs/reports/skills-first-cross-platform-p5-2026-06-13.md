# Skills-first cross-platform P5 report — ship gates

Date: 2026-06-13
Status: release dry-run CI passed
Branch/PR: `p5-ship-gates`

## What changed

```text
.github/workflows/release.yml                      |  97 +++++++++--
CLAUDE.md                                          |   2 +-
crates/fae-daemon/src/main.rs                      | 119 ++++++++++++-
crates/fae-engine/src/mistralrs_adapter.rs         |  51 +++++-
crates/fae-engine/src/mock.rs                      |  20 +--
crates/fae-engine/src/models_lock.rs               |  65 ++++---
crates/fae-engine/src/tts.rs                       |   6 +-
docs/CHANGELOG.md                                  |  12 ++
docs/CURRENT_STATE.md                              |   2 +
.../skills-first-cross-platform-2026-06-13.md      |   7 +-
.../skills-first-cross-platform-p5-2026-06-13.md   | 188 +++++++++++++++++++++
.../macos/Fae/Sources/Fae/ML/DaemonLLMEngine.swift |  48 +++++-
.../Fae/Sources/Fae/Resources/Models/models.lock   |  93 ++++++++++
scripts/ci/guard-no-rust-reintro.sh                |   4 +
scripts/generate-models-lock.py                    | 118 +++++++++++++
15 files changed, 773 insertions(+), 59 deletions(-)
```

- `release.yml` now has a `workflow_dispatch` dry-run path, Rust toolchain/cache setup, `fae-daemon` + `fae-ui-shell` release builds, helper embedding into `Contents/MacOS`, helper signing, and `fae-daemon --version` verification.
- Generated a real bundled `models.lock` for `google/gemma-4-E4B-it` snapshot `fee6332c1abaafb77f6f9624236c63aa2f1d0187` with 6 pinned artifacts.
- Wired daemon startup to verify `models.lock` before `LocalMistralrsAdapter::load`; missing/mismatched/unpinned artifacts exit fail-closed with code `78` and structured fatal stderr.
- Added pinned-revision loading (`load_with_revision`) so mistral.rs cannot silently move to a newer HF snapshot than the one verified by the lock.
- Swift `DaemonLLMEngine` installs the bundled lock to `<fae data dir>/models.lock` before launching the daemon; `FAE_DEV=1` is the only automatic dev escape hatch and sets `FAE_MODELS_LOCK=off` loudly.
- Kept the Rust CI guard fail-closed by allowing Rust only in the explicit Linux render-spike workflow and the release auxiliary embedding workflow.

## models.lock generation proof

Command:

```text
./scripts/generate-models-lock.py \
  ~/.cache/huggingface/hub/models--google--gemma-4-E4B-it/snapshots/fee6332c1abaafb77f6f9624236c63aa2f1d0187 \
  --model-id google/gemma-4-E4B-it \
  --created-at 2026-06-13T17:30:32Z \
  --output /tmp/fae-p5-models.lock

diff -u native/macos/Fae/Sources/Fae/Resources/Models/models.lock /tmp/fae-p5-models.lock
```

Output:

```text
wrote /tmp/fae-p5-models.lock (6 artifacts from /Users/davidirvine/.cache/huggingface/hub/models--google--gemma-4-E4B-it/snapshots/fee6332c1abaafb77f6f9624236c63aa2f1d0187)
      93 /tmp/fae-p5-models.lock
```

`diff -u` produced no output.

## Tamper refusal proof

Setup: copied the real Gemma snapshot with APFS clone copy, flipped one byte in `model.safetensors`, and launched the daemon with `FAE_MODELS_DIR` pointed at the tampered copy and `FAE_MODELS_LOCK_PATH` pointed at the bundled lock.

```text
exit=78
Finished `dev` profile [unoptimized + debuginfo] target(s) in 2.89s
Running `target/debug/fae-daemon`
fae-daemon (Phase 1, chunk 2a) — protocol v2
run dir : /Users/davidirvine/Library/Application Support/fae/run (0700)
token   : /Users/davidirvine/Library/Application Support/fae/run/bootstrap.token (0600)
fae-daemon: fatal: {"event":"fatal","component":"models_lock","model_id":"google/gemma-4-E4B-it","error":"artifact google-gemma-4-e4b-it-model-safetensors: sha256 mismatch or unpinned hash"}
```

## Good-lock live turn proof

Command: launched the daemon against the real warm HF cache with `FAE_TTS=mock`, authenticated over the NDJSON socket, and asked Gemma to reply exactly `p5 lock ok`.

Client transcript:

```text
{"finish_reason": "stop", "text": "p5 lock ok", "tool_calls": []}
session.authenticate -> {"ok": true, "request_id": "r1", "result": {"authenticated": true, "client_id": "swift-frontend-bootstrap"}, "v": 2}
conversation.inject_text -> {"ok": true, "request_id": "r2", "result": {"finish_reason": "stop", "text": "p5 lock ok", "tool_calls": []}, "v": 2}
```

Daemon proof tail:

```text
models.lock: verified 6 artifact(s) for google/gemma-4-E4B-it revision fee6332c1abaafb77f6f9624236c63aa2f1d0187 at /Users/davidirvine/.cache/huggingface/hub/models--google--gemma-4-E4B-it/snapshots/fee6332c1abaafb77f6f9624236c63aa2f1d0187
engine  : loading mistral.rs model google/gemma-4-E4B-it (this can take a while)…
engine  : mistralrs (google/gemma-4-E4B-it)
tts     : mock (mock-tts)
fae-daemon: listening on /Users/davidirvine/Library/Application Support/fae/run/fae-daemon.sock (NDJSON)
```

`fae-daemon --version` proof:

```text
fae-daemon 0.1.0 — protocol v2
```

## Release workflow proof

Dry-run dispatch passed on the branch head:

- Run: <https://github.com/saorsa-labs/fae/actions/runs/27477963214>
- Event: `workflow_dispatch`, `dry_run=true`
- Head SHA: `163aa77363d896d4db73df0bed0b8078a0cc516e`
- Result: success, 2026-06-13T20:18:49Z → 2026-06-13T21:01:19Z
- Build job: `Build macOS (arm64)` success, 2026-06-13T20:35:37Z → 2026-06-13T21:01:18Z
- Artifact: <https://github.com/saorsa-labs/fae/actions/runs/27477963214/artifacts/7614448552>
- Artifact name/size: `fae-macos-arm64`, 203,121,946 bytes

Relevant workflow log:

```text
Run cd crates && cargo build --release -p fae-daemon
Compiling fae-daemon v0.1.0 (/Users/runner/work/fae/fae/crates/fae-daemon)
Finished `release` profile [optimized] target(s) in 13m 11s

Embedded Rust auxiliaries: fae-ui-shell, fae-daemon
Ad-hoc signed: /Users/runner/work/_temp/Fae.app/Contents/MacOS/fae-ui-shell
Ad-hoc signed: /Users/runner/work/_temp/Fae.app/Contents/MacOS/fae-daemon

Run DAEMON="$APP_BUNDLE/Contents/MacOS/fae-daemon"
test -x "$DAEMON"
codesign --verify --verbose=2 "$DAEMON"
"$DAEMON" --version
/Users/runner/work/_temp/Fae.app/Contents/MacOS/fae-daemon: valid on disk
/Users/runner/work/_temp/Fae.app/Contents/MacOS/fae-daemon: satisfies its Designated Requirement
fae-daemon 0.1.0 — protocol v2

Artifact fae-macos-arm64 has been successfully uploaded! Final size is 203121946 bytes. Artifact ID is 7614448552
Artifact download URL: https://github.com/saorsa-labs/fae/actions/runs/27477963214/artifacts/7614448552
```

## Local validation

Passed:

```text
python3 - <<'PY'
from pathlib import Path
import yaml
with open('.github/workflows/release.yml', 'r', encoding='utf-8') as f:
    yaml.safe_load(f)
print('.github/workflows/release.yml: yaml ok')
PY
.github/workflows/release.yml: yaml ok

./scripts/ci/guard-no-rust-reintro.sh
[guard-no-rust] allowing explicit Linux render-spike Rust workflow: .github/workflows/linux-render-spike.yml
[guard-no-rust] allowing explicit release auxiliary Rust embedding workflow: .github/workflows/release.yml
[guard-no-rust] OK

cd crates && cargo clippy -p fae-engine --all-targets --all-features -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.70s

cd crates && cargo clippy -p fae-daemon --bin fae-daemon --all-features -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.46s

cd crates && cargo check --workspace --all-targets
Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.90s

cd crates && just check
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-features
# all crate tests passed

just check-ui-shell
# clippy/check passed; warning retained for future-incompat `block v0.1.6`

cd native/macos/Fae && swift test --skip VocabularyHarvestTests
Executed 3088 tests, with 0 failures
```

Known local exception retained from earlier phases:

```text
cd crates && cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
```

This strict test-target variant still fails on pre-existing test-only `unwrap`/`expect`/`panic` usage in `fae-daemon/src/session.rs`. The production daemon binary strict clippy gate and the modified `fae-engine` all-targets strict gate both pass.

## Exceptions / follow-up

- Release dry-run CI evidence is still pending until this branch is committed and dispatched.
- Root `just check` remains susceptible to the local AddressBook/CoreData XPC/TCC timeout seen in P3/P4; `swift test --skip VocabularyHarvestTests` is the local substitute when this host cannot talk to Contacts.
- P2 live mail/CalDAV/CardDAV account proofs remain unresolved and separate from P5.

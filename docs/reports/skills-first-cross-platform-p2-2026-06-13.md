# Skills-first Cross-platform P2 Report — Productivity Skills Wave

**Date:** 2026-06-13
**Status:** implementation scaffold + local validation complete; live account proof blocked on test credentials/account configuration.

## Summary

P2 added three portable executable productivity skills under `native/macos/Fae/Sources/Fae/Resources/Skills/`:

- `mail-himalaya` — IMAP/SMTP via the `himalaya` CLI.
- `calendar-caldav` — CalDAV list/create/update/delete via `uv run --script` Python (`caldav`, `vobject`).
- `contacts-carddav` — CardDAV contact search via `uv run --script` Python (`vobject`).

Credentials are not stored in skill files. The skills document Keychain-backed `run_skill.secret_bindings` for environment injection, matching the existing `CredentialManager`/`SkillManager.execute(... secretBindings:)` path.

## Diff stat

```text
CLAUDE.md                                          |   7 +-
docs/CHANGELOG.md                                  |  10 +
docs/CURRENT_STATE.md                              |   2 +-
docs/architecture/skill-and-tool-interop-2026-06-05.md           |   2 +-
docs/reports/skills-first-cross-platform-p2-2026-06-13.md   | 249 +++++++++++++++
native/macos/Fae/Sources/Fae/Core/ToolAugmentationManager.swift |   3 +
native/macos/Fae/Sources/Fae/Resources/Skills/calendar-caldav/MANIFEST.json |  26 ++
native/macos/Fae/Sources/Fae/Resources/Skills/calendar-caldav/SKILL.md  |  77 +++++
native/macos/Fae/Sources/Fae/Resources/Skills/calendar-caldav/scripts/calendar_caldav.py     | 343 +++++++++++++++++++++
native/macos/Fae/Sources/Fae/Resources/Skills/contacts-carddav/MANIFEST.json          |  26 ++
native/macos/Fae/Sources/Fae/Resources/Skills/contacts-carddav/SKILL.md |  72 +++++
native/macos/Fae/Sources/Fae/Resources/Skills/contacts-carddav/scripts/contacts_carddav.py   | 230 ++++++++++++++
native/macos/Fae/Sources/Fae/Resources/Skills/mail-himalaya/MANIFEST.json   |  27 ++
native/macos/Fae/Sources/Fae/Resources/Skills/mail-himalaya/SKILL.md    |  76 +++++
native/macos/Fae/Sources/Fae/Resources/Skills/mail-himalaya/scripts/mail_himalaya.py  | 290 +++++++++++++++++
native/macos/Fae/Tests/HandoffTests/SkillActivationTests.swift  |  10 +-
native/macos/Fae/Tests/HandoffTests/SkillBypassRegressionTests.swift   |   2 +-
native/macos/Fae/Tests/IntegrationTests/ToolAugmentationManagerTests.swift             |   7 +
18 files changed, 1453 insertions(+), 6 deletions(-)
```

## Implementation details

- Added agentskills.io-compatible `SKILL.md` frontmatter (`name`, `description`) and Hermes-style sections for all three skills.
- Added Fae `MANIFEST.json` files with `schemaVersion: 1`, `capabilities: ["execute"]`, `allowedTools: ["run_skill"]`, and SHA-256 integrity checksums.
- `mail-himalaya` does not install Himalaya itself; `ToolAugmentationManager.registry` now includes `himalaya` as an extended-tier brew tool.
- `calendar-caldav` supports `status`, `list_calendars`, `list_events`, `create_event`, `update_event`, and `delete_event`.
- `contacts-carddav` supports `status`, `search`, and compact `raw_report` diagnostics.
- Existing AppleTools/EventKit/Contacts paths were not touched.

## Local command evidence

### Script syntax and status smoke

```bash
python3 -m py_compile \
  native/macos/Fae/Sources/Fae/Resources/Skills/mail-himalaya/scripts/mail_himalaya.py \
  native/macos/Fae/Sources/Fae/Resources/Skills/calendar-caldav/scripts/calendar_caldav.py \
  native/macos/Fae/Sources/Fae/Resources/Skills/contacts-carddav/scripts/contacts_carddav.py
```

Exit: 0.

```bash
printf '{"jsonrpc":"2.0","method":"execute","params":{"action":"status"},"id":1}' | uv run --script native/macos/Fae/Sources/Fae/Resources/Skills/mail-himalaya/scripts/mail_himalaya.py
```

```json
{"ok":true,"installed":false,"binary":null,"secrets_env_present":{"HIMALAYA_PASSWORD":false,"HIMALAYA_OAUTH_TOKEN":false},"state":"missing_binary","next_step":"Install himalaya through Fae tool augmentation or brew; do not install from this skill."}
```

```bash
printf '{"jsonrpc":"2.0","method":"execute","params":{"action":"status"},"id":1}' | uv run --script native/macos/Fae/Sources/Fae/Resources/Skills/calendar-caldav/scripts/calendar_caldav.py
```

```json
{"ok":true,"ready":false,"state":"missing_env","required_env_present":{"CALDAV_URL":false,"CALDAV_USERNAME":false,"CALDAV_PASSWORD":false},"missing_env":["CALDAV_URL","CALDAV_USERNAME","CALDAV_PASSWORD"],"optional_env_present":{"CALDAV_CALENDAR":false,"CALDAV_DEFAULT_TZ":false}}
```

```bash
printf '{"jsonrpc":"2.0","method":"execute","params":{"action":"status"},"id":1}' | uv run --script native/macos/Fae/Sources/Fae/Resources/Skills/contacts-carddav/scripts/contacts_carddav.py
```

```json
{"ok":true,"ready":false,"state":"missing_env","required_env_present":{"CARDDAV_URL":false,"CARDDAV_USERNAME":false,"CARDDAV_PASSWORD":false},"missing_env":["CARDDAV_URL","CARDDAV_USERNAME","CARDDAV_PASSWORD"]}
```

### Integrity check

```bash
python3 - <<'PY'
import json,hashlib,pathlib,sys
base=pathlib.Path('native/macos/Fae/Sources/Fae/Resources/Skills')
for name in ['mail-himalaya','calendar-caldav','contacts-carddav']:
    d=base/name
    m=json.loads((d/'MANIFEST.json').read_text())
    for rel, expected in m['integrity']['checksums'].items():
        actual=hashlib.sha256((d/rel).read_bytes()).hexdigest()
        if actual != expected:
            print(f'MISMATCH {name} {rel} {actual} != {expected}')
            sys.exit(1)
    print(f'{name}: integrity ok')
PY
```

Tail:

```text
mail-himalaya: integrity ok
calendar-caldav: integrity ok
contacts-carddav: integrity ok
```

### Targeted Swift skill/tool tests

```bash
cd native/macos/Fae && swift test \
  --filter SkillActivationTests/testNewSkillsDiscovered \
  --filter SkillBypassRegressionTests/testBuiltInExecutableSkillsHaveValidManifests \
  --filter ToolAugmentationManagerTests/testRegistryIncludesHimalayaAsExtendedTool
```

Tail:

```text
Test Suite 'SkillActivationTests' passed ... Executed 1 test, with 0 failures
Test Suite 'SkillBypassRegressionTests' passed ... Executed 1 test, with 0 failures
Test Suite 'ToolAugmentationManagerTests' passed ... Executed 1 test, with 0 failures
Test Suite 'Selected tests' passed ... Executed 3 tests, with 0 failures (0 unexpected)
```

```bash
cd native/macos/Fae && swift test --filter SkillActivationTests
```

Tail:

```text
Test Suite 'SkillActivationTests' passed at 2026-06-13 10:22:14.446.
	 Executed 10 tests, with 0 failures (0 unexpected) in 0.108 (0.109) seconds
```

### Required validation

```bash
just build
```

Tail:

```text
cd native/macos/Fae && xcodebuild build -scheme Fae -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -quiet
2026-06-13 10:41:06.254 xcodebuild[35966:26883659] [MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.
--- xcodebuild: WARNING: Using the first of multiple matching destinations:
{ platform:macOS, arch:arm64, id:00006050-001C08DA01F9401C, name:My Mac }
{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:00006050-001C08DA01F9401C, name:My Mac }
{ platform:macOS, arch:arm64, variant:DriverKit, id:00006050-001C08DA01F9401C, name:My Mac }
```

Exit: 0.

```bash
just check
```

Result: timed out after 900s in the same local Contacts/CoreData XPC/TCC path documented in P1. Tail:

```text
2026-06-13 10:34:55.932 xctest[18126:26848354] CoreData: XPC: Unable to load metadata: Error Domain=NSCocoaErrorDomain Code=134060 "A Core Data error occurred." UserInfo={Problem=Unable to send to server; failed after 8 attempts.}
CoreData: error: storeType: NSXPCStore
CoreData: error: URL: file:///Users/davidirvine/Library/Application%20Support/AddressBook/AddressBook-v22.abcddb
Command timed out after 900 seconds
```

Fallback accepted by the plan's gotchas:

```bash
cd native/macos/Fae && swift test --skip VocabularyHarvestTests
```

Tail:

```text
Test Suite 'FaePackageTests.xctest' passed at 2026-06-13 10:40:33.044.
	 Executed 3088 tests, with 0 failures (0 unexpected) in 116.715 (116.888) seconds
Test Suite 'Selected tests' passed at 2026-06-13 10:40:33.044.
	 Executed 3088 tests, with 0 failures (0 unexpected) in 116.715 (116.889) seconds
✔ Test run with 53 tests in 6 suites passed after 0.049 seconds.
```

```bash
cd crates && just check
```

Tail:

```text
Doc-tests fae_engine

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

Doc-tests fae_envelope_gate

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

```bash
just check-ui-shell
```

Tail:

```text
cd native/rust/fae-ui-shell && cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.20s
warning: the following packages contain code that will be rejected by a future version of Rust: block v0.1.6
cd native/rust/fae-ui-shell && cargo check --workspace --all-targets
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.10s
warning: the following packages contain code that will be rejected by a future version of Rust: block v0.1.6
```

## Live account proof status

Blocked pending reviewer-provided test account credentials/configuration. I did not fabricate account transcripts.

Local environment evidence:

```text
missing: /Users/davidirvine/.config/himalaya
missing: /Users/davidirvine/Library/Application Support/himalaya
```

Needed to close the P2 live gate:

1. Install/configure `himalaya` for a test account or permit Fae's tool augmentation to install it, then provide/confirm account config.
2. Store CalDAV credentials in Keychain and bind them as `CALDAV_URL`, `CALDAV_USERNAME`, `CALDAV_PASSWORD`.
3. Store CardDAV credentials in Keychain and bind them as `CARDDAV_URL`, `CARDDAV_USERNAME`, `CARDDAV_PASSWORD`.
4. Run live proofs:
   - mail: list 5 inbox subjects; send a test email to self.
   - calendar: list next 7 days; create/delete `fae-skill-test`.
   - contacts: search a known contact and return phone/email.
   - voice path: typed dev-app turn routes to the calendar skill and answers.

## Cleanup

- Removed Python `__pycache__/` directories after smoke checks.
- No `xctest`, `swift test`, `xcodebuild`, or `fae-daemon` processes left running after validation.

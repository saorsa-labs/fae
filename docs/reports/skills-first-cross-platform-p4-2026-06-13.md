# Skills-first cross-platform P4 report — Linux render spike

Date: 2026-06-13  
Status: accepted locally; CI proof passed  
Branch/PR: `p4-linux-render-spike`, <https://github.com/saorsa-labs/fae/pull/10>

## Gate result

P4's CI gate passed on Ubuntu. Because final documentation-only commits can retrigger the workflow, the authoritative current status is PR #10's check rollup:

- PR: <https://github.com/saorsa-labs/fae/pull/10>
- Job: `Ubuntu WebKitGTK + ALSA build proof`
- Required outcome: success on the branch head

Representative proof run captured during P4 finalization:

- Run: <https://github.com/saorsa-labs/fae/actions/runs/27472229069>
- Commit at the time of capture: `5b549cdfa8389c5cd424964f480fb509564db724`
- Result: success, 2026-06-13T16:20:28Z → 2026-06-13T16:32:38Z

## What changed

- Added `.github/workflows/linux-render-spike.yml` for an explicit non-default Ubuntu product-shell proof.
- Added `fae-ui-shell --smoke-settings-panel`, which opens the real opaque Settings panel with deterministic sample settings/cards and exits after screenshot capture.
- On Linux, changed `wry` panel construction to use `WebViewBuilderExtUnix::build_gtk` with tao's GTK container. The initial `build(&window)` path compiled but produced a blank white WebKitGTK capture in Xvfb.
- Added screenshot color-count validation so blank/white captures fail the workflow.
- Added the P1-deferred Linux daemon ALSA/native/zigbuild proof to the same job.

## WebKitGTK Settings proof

The passing CI artifact rendered the Settings header, voice controls, select control, refresh button, and always-on capability card under Xvfb/WebKitGTK.

Representative artifact: <https://github.com/saorsa-labs/fae/actions/runs/27472229069/artifacts/7612434592>

Local downloaded artifact metadata:

```text
/tmp/fae-linux-render-spike/linux-settings-panel.png: PNG image data, 1280 x 900, 8-bit/color RGB, non-interlaced
PNG 1280x900 colors=2380 size=79003B
```

CI smoke tail:

```text
/home/runner/work/fae/fae/linux-settings-panel.png: PNG image data, 1280 x 900, 8-bit/color RGB, non-interlaced
settings panel screenshot colors=2380
```

## Linux build proof

```text
Run cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
Finished `dev` profile [unoptimized + debuginfo] target(s) in 46.96s

Run cargo clippy -p fae-daemon --bin fae-daemon --all-features -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
Finished `dev` profile [unoptimized + debuginfo] target(s) in 1m 55s

Run cargo build -p fae-daemon --all-features
Finished `dev` profile [unoptimized + debuginfo] target(s) in 2m 45s

Run cargo zigbuild --target x86_64-unknown-linux-gnu -p fae-daemon --all-features
Finished `dev` profile [unoptimized + debuginfo] target(s) in 3m 37s
```

## Local validation before push

```text
just check-ui-shell
./scripts/ci/guard-no-rust-reintro.sh
cd crates && cargo clippy -p fae-daemon --bin fae-daemon --all-features -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
```

All passed locally before the final CI run.

## Exceptions / follow-up

- The smoke proof is X11/Xvfb CI, not a physical Linux desktop pass.
- Wayland and real compositor behavior remain follow-up.
- Transparent pill artifacts are expected and deliberately not treated as a blocker for opaque Settings panels; a Linux-specific wgpu caption or opaque mini-panel remains likely.
- P2 live mail/CalDAV/CardDAV account proofs remain unresolved and separate from P4.

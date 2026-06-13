# Linux render spike — June 2026

Status: P4 CI proof passed  
Scope: `native/rust/fae-ui-shell` on Ubuntu/WebKitGTK plus the P1-deferred Linux `fae-daemon` ALSA build proof.

## Question

Does the P3 opaque Settings panel render cleanly on Linux WebKitGTK? This is the critical cross-platform thesis. The whisper pill's transparent webview is expected to be compositor-sensitive and may fail or show artifacts on Linux; that does not invalidate the opaque-panel path.

## CI guard

Added `.github/workflows/linux-render-spike.yml` with a single `ubuntu-latest` job:

1. Installs GTK/WebKitGTK, X11/Wayland build headers, `libasound2-dev`, `pkg-config`, Xvfb, ImageMagick, stable Rust, Zig, and `cargo-zigbuild`.
2. Runs `cargo fmt --all -- --check`, strict `cargo clippy`, and `cargo build` for `native/rust/fae-ui-shell`.
3. Runs `fae-ui-shell --smoke-settings-panel` under Xvfb and captures `linux-settings-panel.png` as an artifact. This opens the real opaque Settings panel via wry/WebKitGTK using a deterministic sample `settings_snapshot`.
4. Rejects blank compositor captures by requiring the screenshot to contain at least eight colors; the passing run produced 2,380 colors.
5. Runs daemon formatting, production-binary strict clippy, native Ubuntu build, and `cargo zigbuild --target x86_64-unknown-linux-gnu -p fae-daemon --all-features` from `crates/`, closing the P1-deferred ALSA/pkg-config proof in the same Linux job.

The existing no-Rust-reintroduction CI guard now explicitly allows this dedicated render-spike workflow while continuing to forbid accidental Rust in default Swift CI and default root `just` recipes.

## Local preflight

macOS local checks before pushing the CI workflow:

```text
$ just check-ui-shell
cd native/rust/fae-ui-shell && cargo fmt --all
cd native/rust/fae-ui-shell && cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.33s
cd native/rust/fae-ui-shell && cargo check --workspace --all-targets
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.24s
```

```text
$ ./scripts/ci/guard-no-rust-reintro.sh
[guard-no-rust] checking active CI workflows for rust/cargo reintroduction...
[guard-no-rust] allowing explicit Linux render-spike Rust workflow: .github/workflows/linux-render-spike.yml
[guard-no-rust] checking justfile default dev recipes (build/test/check)...
[guard-no-rust] OK
```

```text
$ cd crates && just check
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-features
...
test result: ok. 13 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

Smoke mode also exits cleanly on macOS:

```text
$ cd native/rust/fae-ui-shell && timeout 8s cargo run -- --smoke-settings-panel
code=0
```

## Runtime observations

| Surface | X11 / Xvfb CI | Wayland desktop | Go/no-go |
| --- | --- | --- | --- |
| Opaque Settings panel | Passed in CI: `linux-settings-panel.png` rendered real text/controls/cards under WebKitGTK/Xvfb; artifact has 2,380 colors | Pending desktop Linux access | CI gate passed |
| wgpu orb | Build-covered by CI; runtime pending desktop Linux access | Pending desktop Linux access | Pending runtime |
| Whisper pill transparency | Expected to misbehave under Linux compositors (tauri#12800/#9220); not a P4 blocker | Pending desktop Linux access | Likely replace/augment with wgpu-rendered captions on Linux |
| Messages panel | Build-covered; runtime pending desktop Linux access | Pending desktop Linux access | Pending runtime |
| Drag + long-press gestures | Build-covered; runtime pending desktop Linux access | Pending desktop Linux access | Pending runtime |

## Current recommendation

- Keep opaque `wry` panels as the cross-platform path: the CI screenshot shows the Settings panel rendering correctly on WebKitGTK once Linux uses `WebViewBuilderExtUnix::build_gtk` against tao's GTK container.
- Treat transparent pill behavior as a separate Linux compositor problem. Prefer a Linux-specific caption strategy rendered by wgpu or an opaque mini-panel rather than relying on transparent WebKitGTK.
- Keep the Linux render-spike workflow as a non-default guard; it is explicit product-shell validation, not a reintroduction of Rust into Swift default CI.

## Evidence

The durable source of truth for the current branch head is PR #10's check rollup: <https://github.com/saorsa-labs/fae/pull/10>. The Linux render-spike job must pass on the branch head before P4 is considered closed.

Representative passing tails from the CI proof:

```text
/home/runner/work/fae/fae/linux-settings-panel.png: PNG image data, 1280 x 900, 8-bit/color RGB, non-interlaced
settings panel screenshot colors=2380

Run cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
Finished `dev` profile [unoptimized + debuginfo] target(s) in 46.96s

Run cargo clippy -p fae-daemon --bin fae-daemon --all-features -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
Finished `dev` profile [unoptimized + debuginfo] target(s) in 1m 55s
Run cargo build -p fae-daemon --all-features
Finished `dev` profile [unoptimized + debuginfo] target(s) in 2m 45s
Run cargo zigbuild --target x86_64-unknown-linux-gnu -p fae-daemon --all-features
Finished `dev` profile [unoptimized + debuginfo] target(s) in 3m 37s
```

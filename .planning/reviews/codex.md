OpenAI Codex v0.98.0 (research preview)
--------
workdir: /Users/davidirvine/Desktop/Devel/projects/fae
model: gpt-5.3-codex
provider: openai
approval: never
sandbox: read-only
reasoning effort: xhigh
reasoning summaries: auto
session id: 019c51d0-1613-7421-953c-5a1a8f8ae8d6
--------
user
current changes
mcp: digitalocean starting
mcp: digitalocean starting
mcp: digitalocean ready
mcp startup: ready: digitalocean
mcp: digitalocean ready
mcp startup: ready: digitalocean

thinking
**Inspecting repository diffs**
thinking
**Inspecting repository diffs**
exec
/bin/zsh -lc 'git status --short' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 2.44s:
2026-02-12 12:25:24.904 xcodebuild[25657:129528213]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:25:25.134 xcodebuild[25657:129528212] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-jbgCh1dL' (errno=Operation not permitted)
2026-02-12 12:25:25.872 xcodebuild[25908:129529084]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:25:26.096 xcodebuild[25908:129529080] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
 M .github/workflows/release.yml
 M .planning/PLAN-phase-1.2.md
 D .planning/reviews/code-simplifier.md
 M README.md
 M src/lib.rs
?? .planning/reviews/code-quality.md
?? .planning/reviews/codex.md
?? .planning/reviews/complexity.md
?? .planning/reviews/documentation.md
?? .planning/reviews/error-handling.md
?? .planning/reviews/glm.md
?? .planning/reviews/kimi.md
?? .planning/reviews/minimax.md
?? .planning/reviews/security.md

thinking
**Reviewing core library changes**
thinking
**Reviewing core library changes**
exec
/bin/zsh -lc 'git diff -- .github/workflows/release.yml README.md src/lib.rs' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 2.06s:
2026-02-12 12:25:30.401 xcodebuild[27387:129533991]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:25:30.570 xcodebuild[27387:129533988] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-KEID1z48' (errno=Operation not permitted)
2026-02-12 12:25:31.095 xcodebuild[27561:129534756]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:25:31.282 xcodebuild[27561:129534645] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
diff --git a/.github/workflows/release.yml b/.github/workflows/release.yml
index 9530e3b..7c9111f 100644
--- a/.github/workflows/release.yml
+++ b/.github/workflows/release.yml
@@ -179,30 +179,139 @@ jobs:
             --timestamp \
             "$PI_BINARY"
 
-      - name: Package release archive
+      - name: Prepare release payloads
         run: |
           VERSION="${GITHUB_REF#refs/tags/v}"
-          ARCHIVE="fae-${VERSION}-macos-arm64.tar.gz"
+          DIST_DIR="$RUNNER_TEMP/fae-dist"

thinking
**Assessing all staged and unstaged changes**
thinking
**Assessing all staged and unstaged changes**
exec
/bin/zsh -lc 'ls -la src' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 53ms:
total 592
drwxr-xr-x@ 35 davidirvine  staff   1120 Feb 12 12:09 .
drwxr-xr-x@ 20 davidirvine  staff    640 Feb 12 11:47 ..
drwxr-xr-x@  6 davidirvine  staff    192 Feb 12 11:57 agent
-rw-r--r--@  1 davidirvine  staff   2254 Feb 11 10:36 approval.rs
drwxr-xr-x@  6 davidirvine  staff    192 Feb  9 14:44 audio
drwxr-xr-x@  5 davidirvine  staff    160 Feb 12 11:54 bin
drwxr-xr-x@ 11 davidirvine  staff    352 Feb 11 19:17 canvas
-rw-r--r--@  1 davidirvine  staff  31221 Feb 12 11:55 config.rs
-rw-r--r--@  1 davidirvine  staff   1478 Feb 12 11:57 error.rs
drwxr-xr-x@  8 davidirvine  staff    256 Feb 12 12:21 fae_llm
-rw-r--r--@  1 davidirvine  staff  10291 Feb  9 09:21 huggingface.rs
-rw-r--r--@  1 davidirvine  staff   2014 Feb 12 12:09 lib.rs
drwxr-xr-x@  4 davidirvine  staff    128 Feb 12 11:57 llm
-rw-r--r--@  1 davidirvine  staff  56634 Feb 12 09:17 memory.rs
-rw-r--r--@  1 davidirvine  staff   4489 Feb  8 22:19 model_picker.rs
-rw-r--r--@  1 davidirvine  staff   6023 Feb 11 19:16 model_selection.rs
-rw-r--r--@  1 davidirvine  staff  21401 Feb 11 19:16 model_tier.rs
drwxr-xr-x@  3 davidirvine  staff     96 Feb 12 01:44 models
-rw-r--r--@  1 davidirvine  staff   9750 Feb 10 23:55 personality.rs

thinking
**Checking untracked files**
thinking
**Checking untracked files**
exec
/bin/zsh -lc 'git status --short --untracked-files=all' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 1.89s:
2026-02-12 12:25:45.266 xcodebuild[28608:129537339]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:25:45.438 xcodebuild[28608:129537338] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-a9xUawRG' (errno=Operation not permitted)
2026-02-12 12:25:45.969 xcodebuild[28685:129537473]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:25:46.142 xcodebuild[28685:129537471] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
 M .github/workflows/release.yml
 M .planning/PLAN-phase-1.2.md
 D .planning/reviews/code-simplifier.md
 M README.md
 M src/lib.rs
?? .planning/reviews/code-quality.md
?? .planning/reviews/codex.md
?? .planning/reviews/complexity.md
?? .planning/reviews/documentation.md
?? .planning/reviews/error-handling.md
?? .planning/reviews/glm.md
?? .planning/reviews/kimi.md
?? .planning/reviews/minimax.md
?? .planning/reviews/security.md

thinking
**Assessing module exports**
thinking
**Assessing module exports**
exec
/bin/zsh -lc "sed -n '1,240p' src/lib.rs" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 53ms:
//! Fae: Real-time speech-to-speech AI conversation system.
//!
//! This crate provides a cascaded pipeline for voice conversations:
//! Microphone → VAD → STT → LLM → TTS → Speaker
//!
//! # Architecture
//!
//! The pipeline is built from independent stages connected by async channels:
//! - **Audio capture**: Records from the microphone via `cpal`
//! - **VAD**: Detects speech boundaries using energy-based analysis
//! - **STT**: Transcribes speech using NVIDIA Parakeet
//! - **LLM**: Generates responses using GGUF models via `mistralrs`
//! - **TTS**: Synthesizes speech using Kokoro-82M (ONNX)
//! - **Audio playback**: Plays synthesized audio via `cpal`

// Fail early with a clear message when the metal feature is enabled but the
// Metal Toolchain is not installed. Without this, mistralrs panics deep in a
// build script with an opaque error.
#[cfg(missing_metal_toolchain)]
compile_error!(

thinking
**Inspecting release workflow for bugs**
thinking
**Inspecting release workflow for bugs**
exec
/bin/zsh -lc "sed -n '1,420p' .github/workflows/release.yml" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 53ms:
name: Release

on:
  push:
    tags:
      - "v*"

env:
  CARGO_TERM_COLOR: always

permissions:
  contents: write

jobs:
  # ── Verify tag matches Cargo.toml version ──────────────────────────
  preflight:
    name: Pre-flight
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.version.outputs.version }}

thinking
**Inspecting update module for asset naming**
thinking
**Inspecting update module for asset naming**
exec
/bin/zsh -lc "ls -la src/update && sed -n '1,260p' src/update/mod.rs && sed -n '1,320p' src/update/updater.rs && sed -n '1,320p' src/update/github.rs" in /Users/davidirvine/Desktop/Devel/projects/fae exited 1 in 50ms:
total 80
drwxr-xr-x@  6 davidirvine  staff    192 Feb 12 11:35 .
drwxr-xr-x@ 35 davidirvine  staff   1120 Feb 12 12:09 ..
-rw-r--r--@  1 davidirvine  staff  11129 Feb 10 20:41 applier.rs
-rw-r--r--@  1 davidirvine  staff  11673 Feb 12 11:14 checker.rs
-rw-r--r--@  1 davidirvine  staff    410 Feb 10 20:41 mod.rs
-rw-r--r--@  1 davidirvine  staff  10950 Feb 12 11:35 state.rs
//! Self-update system for Fae and Pi.
//!
//! Checks GitHub releases for newer versions, notifies the user, and applies
//! updates with platform-specific binary replacement. Supports both Fae and
//! Pi update channels with configurable auto-update preferences.

pub mod applier;
pub mod checker;
pub mod state;

pub use checker::{Release, UpdateChecker};
pub use state::{AutoUpdatePreference, UpdateState};
sed: src/update/updater.rs: No such file or directory

thinking
**Checking update mechanism presence**
thinking
**Checking update mechanism presence**
exec
/bin/zsh -lc "sed -n '1,360p' src/update/checker.rs && sed -n '1,360p' src/update/applier.rs && sed -n '1,260p' src/update/state.rs" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 52ms:
//! GitHub release checker for Fae updates.
//!
//! Queries the GitHub releases API to detect newer versions, compares using
//! semver, and caches ETags for efficient conditional requests.

use crate::error::{Result, SpeechError};
use std::time::Duration;

/// Compare two semver version strings and return `true` if `remote` is newer than `current`.
///
/// Handles versions with or without `v` prefix and up to 3 numeric components.
fn version_is_newer(current: &str, remote: &str) -> bool {
    fn parse_parts(v: &str) -> (u64, u64, u64) {
        let v = v.strip_prefix('v').unwrap_or(v);
        let mut parts = v.split('.').filter_map(|s| s.parse::<u64>().ok());
        let major = parts.next().unwrap_or(0);
        let minor = parts.next().unwrap_or(0);
        let patch = parts.next().unwrap_or(0);
        (major, minor, patch)
    }

thinking
**Analyzing macOS signing and PI binary lookup**
thinking
**Analyzing macOS signing and PI binary lookup**
exec
/bin/zsh -lc "rg -n \"PI_BINARY|join\\(\\\"pi\\\"\\)|/pi|pi binary|pi_path|find_pi|badlogic|coding agent|fae-darwin-aarch64\" src README.md Cargo.toml" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 53ms:
README.md:63:- **Pi Coding Agent**: Delegates coding, file editing, and research tasks to [Pi](https://github.com/badlogic/pi-mono)
README.md:119:Fae integrates with the [Pi coding agent](https://github.com/badlogic/pi-mono) to handle coding tasks, file editing, shell commands, and research — all triggered by voice.
README.md:141:- **macOS / Linux**: `~/.local/bin/pi`
README.md:154:| Pi not found | Check `~/.local/bin/pi` exists and is executable |
README.md:155:| Pi auto-install fails | Check internet connectivity; manually download from [Pi releases](https://github.com/badlogic/pi-mono/releases) |
README.md:158:| macOS Gatekeeper blocks Pi | Fae clears quarantine automatically; if blocked, run `xattr -c ~/.local/bin/pi` |
src/update/checker.rs:160:        ("macos", "aarch64") => Some("fae-darwin-aarch64"),
src/update/checker.rs:233:                    "name": "fae-darwin-aarch64",
src/update/checker.rs:234:                    "browser_download_url": "https://github.com/saorsa-labs/fae/releases/download/v0.2.0/fae-darwin-aarch64",
src/update/checker.rs:286:            "name": fae_asset_name().unwrap_or("fae-darwin-aarch64"),
src/update/checker.rs:313:                "name": "fae-darwin-aarch64",
src/canvas/render.rs:498:        let html = render_image_html("https://example.com/pic.png", &t);

thinking
**Searching for local pi binary**
thinking
**Searching for local pi binary**
exec
/bin/zsh -lc 'rg -n "local/bin/pi|pi-mono|PI|pi" src/agent src/startup.rs src/config.rs src/runtime.rs src/skills.rs src/lib.rs' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 53ms:
src/config.rs:1://! Configuration types for the speech-to-speech pipeline.
src/config.rs:6:/// Top-level configuration for the speech pipeline.
src/config.rs:80:    /// Typical range: 0.01–0.5. Lower values are more stable but adapt slower.
src/config.rs:101:    /// Typical values for f32 samples in \[-1, 1\]:
src/config.rs:102:    ///   - 0.005: very sensitive (picks up quiet speech and some noise)
src/config.rs:154:    /// Remote inference via OpenAI-compatible API (Ollama, MLX, etc.).
src/config.rs:155:    Api,
src/config.rs:188:    /// Base URL for the API server (API backend only).
src/config.rs:189:    pub api_url: String,
src/config.rs:190:    /// Model name to request from the API (API backend only).
src/config.rs:191:    pub api_model: String,
src/config.rs:192:    /// API key for the remote provider (API/Agent backends only).
src/config.rs:194:    /// For local servers (Ollama/LM Studio/vLLM), this is typically empty.
src/config.rs:195:    pub api_key: String,
src/config.rs:227:    /// When set (and backend is `Agent` or `Api`), this provider's base_url
src/config.rs:228:    /// and api_key are used instead of `api_url`/`api_key`.
src/config.rs:233:    /// When set, overrides `api_model` for the cloud provider.
src/config.rs:255:            api_url: "http://localhost:11434".to_owned(),
src/config.rs:256:            api_model: "smollm3:3b".to_owned(),
src/config.rs:257:            api_key: String::new(),

thinking
**Investigating potential Pi integration code**
thinking
**Investigating potential Pi integration code**
exec
/bin/zsh -lc 'find src/fae_llm -maxdepth 3 -type f -print' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 51ms:
src/fae_llm/types.rs
src/fae_llm/events.rs
src/fae_llm/error.rs
src/fae_llm/metadata.rs
src/fae_llm/usage.rs
src/fae_llm/mod.rs

thinking
**Inspecting type-only module usage**
thinking
**Inspecting type-only module usage**
exec
/bin/zsh -lc "sed -n '1,260p' src/fae_llm/mod.rs && sed -n '1,260p' src/fae_llm/types.rs && sed -n '1,260p' src/fae_llm/events.rs && sed -n '1,260p' src/fae_llm/error.rs && sed -n '1,260p' src/fae_llm/metadata.rs && sed -n '1,260p' src/fae_llm/usage.rs" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 53ms:
//! FAE LLM module — multi-provider LLM integration.
//!
//! This module provides the foundational types for interacting with
//! multiple LLM providers (OpenAI, Anthropic, local endpoints, etc.)
//! through a normalized interface.
//!
//! # Submodules
//!
//! - [`error`] — Error types with stable error codes
//! - [`types`] — Core domain types (endpoints, models, request options)
//! - [`events`] — Normalized streaming event model
//! - [`usage`] — Token usage and cost tracking
//! - [`metadata`] — Request/response metadata
//!
//! # Event Model
//!
//! All providers normalize their streaming output to [`events::LlmEvent`],
//! providing a consistent interface regardless of the underlying API.
//!
//! # Error Codes

thinking
**Analyzing release workflow and module export risks**
thinking
**Analyzing release workflow and module export risks**
exec
/bin/zsh -lc 'git diff --cached --name-status' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 2.34s:
2026-02-12 12:27:01.018 xcodebuild[37178:129573182]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:27:01.301 xcodebuild[37178:129573181] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-hfMXHMNZ' (errno=Operation not permitted)
2026-02-12 12:27:01.893 xcodebuild[37184:129573263]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:27:02.090 xcodebuild[37184:129573262] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.

thinking
**Evaluating GitHub Actions env variable scope**
thinking
**Evaluating GitHub Actions env variable scope**
exec
/bin/zsh -lc 'git diff --stat' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 1.86s:
2026-02-12 12:27:29.518 xcodebuild[38013:129576516]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:27:29.674 xcodebuild[38013:129576515] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-tvanPXnj' (errno=Operation not permitted)
2026-02-12 12:27:30.163 xcodebuild[38061:129576627]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:27:30.315 xcodebuild[38061:129576625] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
 .github/workflows/release.yml        | 141 ++++++++-
 .planning/PLAN-phase-1.2.md          | 214 ++++++++-----
 .planning/reviews/code-simplifier.md | 574 ++++++-----------------------------
 README.md                            |  59 +++-
 src/fae_llm/error.rs                 |  77 +++--
 src/fae_llm/events.rs                |   5 +-
 src/fae_llm/metadata.rs              |  10 +-
 src/fae_llm/mod.rs                   |  10 +-
 src/lib.rs                           |   1 +
 9 files changed, 492 insertions(+), 599 deletions(-)

thinking
**Analyzing hidden git changes**
thinking
**Analyzing hidden git changes**
exec
/bin/zsh -lc 'git status' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 2.13s:
2026-02-12 12:27:36.403 xcodebuild[38605:129577854]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:27:36.571 xcodebuild[38605:129577848] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-dtMjXU5v' (errno=Operation not permitted)
2026-02-12 12:27:37.229 xcodebuild[38636:129578037]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:27:37.428 xcodebuild[38636:129578035] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
On branch main
Your branch is ahead of 'origin/main' by 58 commits.
  (use "git push" to publish your local commits)

Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
	modified:   .github/workflows/release.yml
	modified:   .planning/PLAN-phase-1.2.md
	modified:   .planning/reviews/code-simplifier.md
	modified:   README.md
	modified:   src/fae_llm/error.rs
	modified:   src/fae_llm/events.rs
	modified:   src/fae_llm/metadata.rs

thinking
**Inspecting updated code changes**
thinking
**Inspecting updated code changes**
exec
/bin/zsh -lc 'git diff -- src/fae_llm/mod.rs src/fae_llm/error.rs src/fae_llm/events.rs src/fae_llm/metadata.rs src/lib.rs' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 1.94s:
2026-02-12 12:27:42.105 xcodebuild[38740:129578415]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:27:42.263 xcodebuild[38740:129578414] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-sL3438CJ' (errno=Operation not permitted)
2026-02-12 12:27:42.762 xcodebuild[38778:129578502]  DVTFilePathFSEvents: Failed to start fs event stream.
2026-02-12 12:27:42.921 xcodebuild[38778:129578501] [MT] DVTDeveloperPaths: Failed to get length of DARWIN_USER_CACHE_DIR from confstr(3), error = Error Domain=NSPOSIXErrorDomain Code=5 "Input/output error". Using NSCachesDirectory instead.
diff --git a/src/fae_llm/error.rs b/src/fae_llm/error.rs
index 883e89d..85d0163 100644
--- a/src/fae_llm/error.rs
+++ b/src/fae_llm/error.rs
@@ -4,6 +4,33 @@
 //! that is included in the Display output and accessible via [`FaeLlmError::code()`].
 //! Codes are part of the public API contract and will not change.
 
+/// Stable error codes for programmatic error handling.
+///
+/// These codes never change and form part of the public API contract.
+/// Use these for distinguishing errors rather than parsing Display output.
+pub mod error_codes {
+    /// Invalid or missing configuration.

thinking
**Inspecting error rename impact**
thinking
**Inspecting error rename impact**
exec
/bin/zsh -lc "rg -n \"FaeLlmError::Timeout\\b|Timeout\\(\" src" in /Users/davidirvine/Desktop/Devel/projects/fae exited 1 in 53ms:


thinking
**Flagging error code renaming bug**
thinking
**Flagging error code renaming bug**
exec
/bin/zsh -lc 'rg -n "TIMEOUT" src/fae_llm' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 51ms:
src/fae_llm/mod.rs:224:            "TIMEOUT_ERROR",
src/fae_llm/error.rs:28:    pub const TIMEOUT_ERROR: &str = "TIMEOUT_ERROR";
src/fae_llm/error.rs:61:    #[error("[{}] {}", error_codes::TIMEOUT_ERROR, .0)]
src/fae_llm/error.rs:81:            Self::TimeoutError(_) => error_codes::TIMEOUT_ERROR,
src/fae_llm/error.rs:140:        assert_eq!(err.code(), "TIMEOUT_ERROR");
src/fae_llm/error.rs:199:        assert_eq!(error_codes::TIMEOUT_ERROR, "TIMEOUT_ERROR");

thinking
**Checking crate type and version**
thinking
**Checking crate type and version**
exec
/bin/zsh -lc "sed -n '1,220p' Cargo.toml" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 53ms:
[package]
name = "fae"
version = "0.1.0"
edition = "2024"
description = "Real-time speech-to-speech AI conversation system"
license = "AGPL-3.0"
repository = "https://github.com/saorsa-labs/fae"
autobins = false
default-run = "fae"

[[bin]]
name = "fae"
path = "src/bin/gui.rs"
required-features = ["gui"]

[[bin]]
name = "fae-record-wakeword"
path = "src/bin/record_wakeword.rs"

[[bin]]

thinking
**Assessing release workflow and timeout changes**
thinking
**Assessing release workflow and timeout changes**
exec
/bin/zsh -lc "sed -n '1,280p' src/fae_llm/error.rs" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 53ms:
//! Error types for the fae_llm module.
//!
//! Each error variant carries a stable error code (SCREAMING_SNAKE_CASE)
//! that is included in the Display output and accessible via [`FaeLlmError::code()`].
//! Codes are part of the public API contract and will not change.

/// Stable error codes for programmatic error handling.
///
/// These codes never change and form part of the public API contract.
/// Use these for distinguishing errors rather than parsing Display output.
pub mod error_codes {
    /// Invalid or missing configuration.
    pub const CONFIG_INVALID: &str = "CONFIG_INVALID";

    /// Authentication failed (invalid/missing API key).
    pub const AUTH_FAILED: &str = "AUTH_FAILED";

    /// Request to the LLM provider failed.
    pub const REQUEST_FAILED: &str = "REQUEST_FAILED";


thinking
**Analyzing potential release workflow bugs**
thinking
**Analyzing potential release workflow bugs**
exec
/bin/zsh -lc "rg -n \"TimeoutError|\\bTimeout\\b\" src/fae_llm" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 52ms:
src/fae_llm/mod.rs:214:            FaeLlmError::TimeoutError("x".into()),
src/fae_llm/error.rs:62:    TimeoutError(String),
src/fae_llm/error.rs:81:            Self::TimeoutError(_) => error_codes::TIMEOUT_ERROR,
src/fae_llm/error.rs:94:            | Self::TimeoutError(m)
src/fae_llm/error.rs:139:        let err = FaeLlmError::TimeoutError("30s elapsed".into());
src/fae_llm/error.rs:179:            FaeLlmError::TimeoutError("x".into()),

thinking
**Assessing potential test lint and error code bugs**
thinking
**Assessing potential test lint and error code bugs**
exec
/bin/zsh -lc "ls .github/workflows && for f in .github/workflows/*.yml; do echo '---' "'$f; sed -n '"'1,260p' "'$f; done' in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 51ms:
ci.yml
release.yml
--- .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  CARGO_TERM_COLOR: always
  RUSTFLAGS: "-D warnings"

jobs:
  check:
    name: Check & Lint
    runs-on: macos-latest
    steps:

thinking
**Assessing error code backward compatibility**
thinking
**Assessing error code backward compatibility**
exec
/bin/zsh -lc "rg -n \"CONFIG_INVALID|AUTH_FAILED|REQUEST_FAILED|STREAM_FAILED|TOOL_FAILED|TIMEOUT_ERROR|TIMEOUT\\b|PROVIDER_ERROR\" -g'*.rs'" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 53ms:
src/fae_llm/mod.rs:22://! All errors carry a stable code (e.g. `CONFIG_INVALID`, `AUTH_FAILED`)
src/fae_llm/mod.rs:219:            "CONFIG_INVALID",
src/fae_llm/mod.rs:220:            "AUTH_FAILED",
src/fae_llm/mod.rs:221:            "REQUEST_FAILED",
src/fae_llm/mod.rs:222:            "STREAM_FAILED",
src/fae_llm/mod.rs:223:            "TOOL_FAILED",
src/fae_llm/mod.rs:224:            "TIMEOUT_ERROR",
src/fae_llm/mod.rs:225:            "PROVIDER_ERROR",
src/fae_llm/error.rs:13:    pub const CONFIG_INVALID: &str = "CONFIG_INVALID";
src/fae_llm/error.rs:16:    pub const AUTH_FAILED: &str = "AUTH_FAILED";
src/fae_llm/error.rs:19:    pub const REQUEST_FAILED: &str = "REQUEST_FAILED";
src/fae_llm/error.rs:22:    pub const STREAM_FAILED: &str = "STREAM_FAILED";
src/fae_llm/error.rs:25:    pub const TOOL_FAILED: &str = "TOOL_FAILED";
src/fae_llm/error.rs:28:    pub const TIMEOUT_ERROR: &str = "TIMEOUT_ERROR";
src/fae_llm/error.rs:31:    pub const PROVIDER_ERROR: &str = "PROVIDER_ERROR";
src/fae_llm/error.rs:41:    #[error("[{}] {}", error_codes::CONFIG_INVALID, .0)]
src/fae_llm/error.rs:45:    #[error("[{}] {}", error_codes::AUTH_FAILED, .0)]
src/fae_llm/error.rs:49:    #[error("[{}] {}", error_codes::REQUEST_FAILED, .0)]
src/fae_llm/error.rs:53:    #[error("[{}] {}", error_codes::STREAM_FAILED, .0)]
src/fae_llm/error.rs:57:    #[error("[{}] {}", error_codes::TOOL_FAILED, .0)]

thinking
**Analyzing release workflow for packaging bugs**
thinking
**Analyzing release workflow for packaging bugs**
exec
/bin/zsh -lc "rg -n \"deny\\(clippy::unwrap_used|deny\\(clippy::expect_used|deny\\(clippy::panic|forbid\\(clippy::\" src" in /Users/davidirvine/Desktop/Devel/projects/fae exited 1 in 51ms:


thinking
**Assessing error code location extraction**
thinking
**Assessing error code location extraction**
exec
/bin/zsh -lc "nl -ba src/fae_llm/error.rs | sed -n '20,90p'" in /Users/davidirvine/Desktop/Devel/projects/fae succeeded in 52ms:
    20	
    21	    /// Streaming response encountered an error.
    22	    pub const STREAM_FAILED: &str = "STREAM_FAILED";
    23	
    24	    /// Tool execution failed.
    25	    pub const TOOL_FAILED: &str = "TOOL_FAILED";
    26	
    27	    /// Request or operation timed out.
    28	    pub const TIMEOUT_ERROR: &str = "TIMEOUT_ERROR";
    29	
    30	    /// Provider-specific error not covered by other variants.
    31	    pub const PROVIDER_ERROR: &str = "PROVIDER_ERROR";
    32	}
    33	
    34	/// Errors produced by the fae_llm module.
    35	///
    36	/// Each variant includes a stable error code accessible via [`FaeLlmError::code()`].
    37	/// The Display impl formats as `[CODE] message`.
    38	#[derive(Debug, thiserror::Error)]
    39	pub enum FaeLlmError {

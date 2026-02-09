# Pi Distribution Strategy — Deep Analysis

> **Date**: 2026-02-09
> **Status**: HISTORICAL — This analysis led to the decision documented in fae-tool-bundling-spec.md v2.0
> **Final Decision**: None of the options analysed below were adopted as-is. After discussion, the chosen approach is: install Pi's own pre-built binary to standard location (`~/.local/bin/pi`), auto-update via scheduler, don't bundle rg/fd/uv/Bun. See spec v2.0 for the implemented design.
> **Why not Option C (the original recommendation)?**: Fae's target users are non-technical. The key insight that emerged in discussion was that Pi should be installed as a proper system tool (called `pi`, in a standard location, with standard config at `~/.pi/agent/`) — not hidden inside a Fae-specific directory. Additionally, bundling Bun + node_modules adds operational complexity for a small team, and Pi's pre-built binary is already self-contained with Bun embedded. The native module concern (clipboard) doesn't affect Fae's RPC use case.
> **Context**: Fae needs to ship Pi (coding agent) to non-technical users on Mac, Windows, and Linux without requiring them to install Node.js, Bun, or any other runtime.

---

## 1. The Core Problem

Fae is a Rust desktop GUI app. Pi is a TypeScript/Node.js CLI tool. Users should never have to:
- Install Node.js
- Install Bun
- Run `npm install`
- Touch a terminal at all

The question: **How does a Rust desktop app ship a JavaScript-based coding agent?**

---

## 2. What Pi Actually Is

Pi (`@mariozechner/pi-coding-agent`) is:
- A TypeScript monorepo with 3 core packages: `pi-ai`, `pi-agent-core`, `pi-tui`
- Distributed via npm (requires Node.js 20+)
- Has a `build:binary` script using `bun build --compile` (added via PR #89)
- Pre-built binaries available on GitHub Releases for all 5 platform targets
- ~9MB npm package, ~90MB compiled standalone binary (includes Bun runtime)
- Has known issues with native modules in compiled form (clipboard: issues #556, #533)
- Requires bash on Windows (Git Bash works)
- Three execution modes: npm install, standalone binary, tsx from source
- Asset resolution via `src/paths.ts` handles all three modes

### Pi's RPC Mode (Our Integration Point)

Pi supports `--mode rpc` for programmatic control:
- JSON protocol over stdin/stdout
- Spawn as subprocess, send prompts, receive streamed events
- No Node.js/Bun needed at runtime if using compiled binary

---

## 3. All Distribution Options

### Option A: Pre-built Bun-Compiled Binary (Current Plan)

**How it works**: Download Pi's pre-built binary from GitHub Releases, rename to `fae-pi`, bundle in installer.

| Aspect | Detail |
|--------|--------|
| Binary size | ~90MB per platform (Pi) + ~50MB (Bun for extensions) = ~140MB |
| Platforms | darwin-arm64, darwin-x64, linux-x64, linux-arm64, windows-x64 |
| Runtime needed | None (Bun runtime embedded in binary) |
| Native modules | **BROKEN** — clipboard module fails (issue #556) |
| Extensions | Need separate `fae-bun` for TypeScript extensions |
| Update path | Replace binary on Fae update |
| Build complexity | Low — download from Releases |

**Pros**:
- Zero runtime dependency for users
- Single binary, easy to reason about
- Fast startup (~50ms vs ~185ms for Node)

**Cons**:
- **140MB+ just for Pi + Bun** (on top of Fae's own binary)
- Native modules broken (clipboard) — may hit more issues
- Bun's compiled binary is essentially a Bun runtime + bytecode bundle, not true native
- Two large binaries (fae-pi AND fae-bun) feel wasteful
- Unsigned on macOS → Gatekeeper blocks (`xattr -c` workaround)

---

### Option B: Build Pi Ourselves in CI (Current Spec's Approach)

**How it works**: In our CI, `bun build --compile` Pi from npm source for each platform target.

| Aspect | Detail |
|--------|--------|
| Binary size | Same as Option A (~90MB Pi + ~50MB Bun) |
| Platforms | All 5 (Bun supports cross-compilation) |
| Runtime needed | None |
| Security | Full audit of source before build |
| Build complexity | Medium — need Bun in CI for each platform |

**Pros**:
- Full control over what goes into the binary
- Can pin exact versions and audit
- Can cross-compile from single CI runner (Bun feature)

**Cons**:
- Same size/native-module issues as Option A
- Need to maintain CI pipeline for Pi builds
- Must track Pi releases and rebuild on updates
- Cross-compilation may fail for platform-specific native modules

---

### Option C: Ship Bun Runtime + Pi Source Bundle

**How it works**: Bundle `fae-bun` (Bun runtime) and Pi's npm package as source. Run Pi via `fae-bun /path/to/pi/cli.js`.

| Aspect | Detail |
|--------|--------|
| Binary size | ~50MB (Bun) + ~30-50MB (Pi + node_modules) = ~80-100MB |
| Platforms | All 5 (Bun binaries available) |
| Runtime needed | None (we ship Bun) |
| Native modules | **Work normally** — Bun loads them at runtime |
| Extensions | Same `fae-bun` serves double duty |
| Build complexity | Low — download Bun + npm pack Pi |

**Pros**:
- **One runtime, dual purpose** — same Bun binary runs Pi AND handles extensions
- **Native modules work** — loaded at runtime, not baked into compiled binary
- Extensions work naturally (same Bun runtime)
- Simpler CI — just download Bun and `npm pack` Pi
- Can update Pi without rebuilding binary (just replace source bundle)

**Cons**:
- Slightly slower startup than compiled binary (~120ms vs ~50ms) — irrelevant for RPC subprocess
- **node_modules tree adds operational complexity** — managing a directory tree is harder than a single binary blob
- Pi npm package is ~9MB but with deps installed, `node_modules` is ~30-50MB
- Source code visible (Pi is MIT, so this is fine)
- **Bun version coupling** — if a Bun update breaks Pi source compatibility, must pin/test carefully
- **macOS code-signing** applies to both the Bun binary AND the node_modules tree contents

---

### Option D: Ship Node.js + Pi Source Bundle

**How it works**: Same as Option C but with Node.js instead of Bun.

| Aspect | Detail |
|--------|--------|
| Binary size | ~70-80MB (Node.js) + ~9MB (Pi source) = ~79-89MB |
| Platforms | All 5 (Node.js binaries available) |
| Runtime needed | None (we ship Node.js) |
| Native modules | Work normally |
| Extensions | Need separate approach (Node vs Bun ecosystem) |
| Build complexity | Low |

**Pros**:
- Most compatible — Pi is tested primarily on Node.js
- Native modules fully supported
- Larger ecosystem, more battle-tested

**Cons**:
- **Larger than Bun** (~70-80MB vs ~50MB)
- **No cross-compilation** for standalone — must build on each platform
- Slower startup (~185ms)
- Can't use `bun build --compile` for extensions
- Two runtime stories (Node for Pi, something else for extensions)

---

### Option E: Deno Compile

**How it works**: Port or wrap Pi to run on Deno, use `deno compile` for standalone binary.

| Aspect | Detail |
|--------|--------|
| Binary size | ~58MB |
| Platforms | darwin-arm64, darwin-x64, linux-x64, windows-x64 (no linux-arm64) |
| Runtime needed | None |
| Native modules | Limited npm support |
| Build complexity | **Very High** — Pi isn't Deno-compatible |

**Pros**:
- Good cross-compilation
- Built-in permission system for security

**Cons**:
- **Pi doesn't run on Deno** — would need porting effort
- Missing linux-arm64
- npm compatibility layer may break Pi's dependencies
- Maintaining a Deno fork of Pi is unsustainable

**Verdict: Not viable without significant effort. Discard.**

---

### Option F: Node.js SEA (Single Executable Application)

**How it works**: Node.js 25.5+ can bundle code into its own binary via `--build-sea`.

| Aspect | Detail |
|--------|--------|
| Binary size | ~50-80MB |
| Platforms | All except native Windows ARM64 |
| Runtime needed | None |
| Native modules | Complex — must be pre-built for target |
| Build complexity | High — no cross-compilation, Docker needed |

**Pros**:
- Official Node.js feature, well-supported
- Proven approach

**Cons**:
- **No cross-compilation** — need Docker or native builds for each platform
- CommonJS primary; ESM support is experimental (`--experimental-sea-esm`) and unreliable
- Linux ARM64 Docker has known postject issues
- Larger than Bun
- ESM limitation is a dealbreaker for Pi

**Verdict: ESM incompatibility and no cross-compilation make this impractical. Discard.**

---

### Option G: Check-and-Install at First Run

**How it works**: Fae GUI checks if Pi/Node/Bun is installed. If not, downloads and installs automatically on first run.

| Aspect | Detail |
|--------|--------|
| Installer size | Small (just Fae) |
| First-run overhead | ~50-150MB download |
| Runtime needed | Internet connection on first run |
| Build complexity | Low for installer, higher for download manager |

**Pros**:
- Smallest initial installer
- Always gets latest compatible version
- Can verify against known checksums

**Cons**:
- **Requires internet** — breaks offline-first promise
- First-run experience is "please wait while downloading..."
- Firewall/proxy issues on corporate networks
- Platform-specific download URLs to maintain
- Version compatibility matrix to manage
- **Users hate download-on-first-run** (feels unfinished)

**Verdict: Bad UX. Only viable as a fallback mechanism, not primary strategy.**

---

### Option H: Hybrid — Compiled Pi Core + Bun for Extensions

**How it works**: Ship `fae-pi` as Bun-compiled binary for core functionality. Ship `fae-bun` separately only for extension loading.

| Aspect | Detail |
|--------|--------|
| Binary size | ~90MB (Pi) + ~50MB (Bun, optional) = 90-140MB |
| Core functionality | Works without Bun |
| Extensions | Require Bun |
| Native modules | Broken in compiled Pi |

**This is essentially what the current spec proposes.**

---

## 4. Comparative Matrix

| Option | Total Size | Native Modules | Complexity | Offline | Update Ease |
|--------|-----------|---------------|------------|---------|-------------|
| A: Pre-built binary | ~140MB | ❌ Broken | Low | ✅ | Replace binary |
| B: Build in CI | ~140MB | ❌ Broken | Medium | ✅ | Rebuild + replace |
| **C: Bun + Source** | **~80-100MB** | **✅ Work** | **Low** | **✅** | **Replace source** |
| D: Node + Source | ~79-89MB | ✅ Work | Low | ✅ | Replace source |
| E: Deno Compile | ~58MB | ⚠️ Limited | Very High | ✅ | Rebuild binary |
| F: Node SEA | ~50-80MB | ⚠️ Complex | High | ✅ | Rebuild binary |
| G: Download at runtime | ~0MB | ✅ Work | Medium | ❌ | Auto-update |
| H: Hybrid (current spec) | ~90-140MB | ❌ Broken (core) | Medium | ✅ | Complex |

---

## 5. Recommendation: Option C (Bun Runtime + Pi Source Bundle)

### Why This Wins

1. **Smaller footprint**: ~80-100MB total vs ~140MB for compiled approach (and one less large binary)
2. **Native modules work**: No clipboard or other native module issues
3. **One runtime, dual purpose**: Same `fae-bun` runs Pi AND handles extensions
4. **Simplest updates**: Swap Pi source bundle without recompiling anything
5. **Simplest CI**: Download Bun binaries + `npm pack` Pi
6. **Extensibility preserved**: Extensions load naturally through Bun's module system

### Implementation

```
~/.fae/
├── bin/
│   ├── fae-bun              # Bun runtime (~50MB, platform-specific)
│   ├── fae-fd               # fd file finder (~4MB, Rust binary)
│   ├── fae-rg               # ripgrep (~6MB, Rust binary)
│   └── fae-uv               # uv (~20MB, Rust binary)
│
├── tools/
│   └── pi/
│       ├── node_modules/    # Pi and all dependencies (~30-50MB)
│       │   └── @mariozechner/
│       │       └── pi-coding-agent/
│       │           └── dist/cli.js   # Entry point
│       ├── extensions/      # User extensions
│       ├── skills/          # User skills
│       └── package.json     # Lockfile for Pi deps
│
├── config.toml
└── manifest.toml
```

### How Fae Launches Pi

```rust
// In Fae's Rust code:
let bun = fae_home.join("bin/fae-bun");
let pi_cli = fae_home.join("tools/pi/node_modules/@mariozechner/pi-coding-agent/dist/cli.js");

let process = Command::new(&bun)
    .arg("run")
    .arg(&pi_cli)
    .args(["--mode", "rpc", "--no-session"])
    .current_dir(cwd)
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()?;
```

### CI Build Pipeline (Simplified)

```yaml
jobs:
  build-tools:
    strategy:
      matrix:
        include:
          - platform: darwin-arm64
            bun_target: bun-darwin-arm64
          - platform: darwin-x64
            bun_target: bun-darwin-x64
          - platform: linux-x64
            bun_target: bun-linux-x64
          - platform: linux-arm64
            bun_target: bun-linux-arm64
          - platform: windows-x64
            bun_target: bun-windows-x64

    steps:
      # Download Bun (platform-specific)
      - name: Download Bun
        run: |
          curl -L "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${{ matrix.bun_target }}.zip" -o bun.zip
          unzip bun.zip && mv */bun fae-bun

      # Package Pi source (platform-independent!)
      - name: Package Pi
        run: |
          mkdir -p tools/pi
          cd tools/pi
          npm init -y
          npm install @mariozechner/pi-coding-agent@${PI_VERSION}
          # Pi source bundle is the SAME for all platforms

      # Download Rust tools (from their Releases)
      - name: Download fd, rg, uv
        run: |
          # ... download platform-specific Rust binaries
```

### Startup Performance (Non-Issue)

| Mode | Startup | Notes |
|------|---------|-------|
| Compiled binary | ~50ms | Marginally faster |
| Bun + source | ~120ms | Negligible for RPC subprocess |
| Node.js + source | ~185ms | Noticeably slower but still OK |

The 70ms difference is irrelevant — Pi runs as a long-lived RPC subprocess that Fae spawns once and communicates with for the duration of a session.

---

## 6. Platform-Specific Considerations

### macOS

| Concern | Mitigation |
|---------|-----------|
| Gatekeeper blocks unsigned binaries | Code-sign fae-bun in CI with Apple Developer ID |
| Notarization required | Notarize the entire Fae.app bundle (includes all sidecar tools) |
| App bundle structure | Tools go in `Fae.app/Contents/Resources/bin/` at install, copied to `~/.fae/bin/` on first run |
| M1 vs Intel | Ship both arm64 and x64 Bun binaries; universal binary also possible |

### Windows

| Concern | Mitigation |
|---------|-----------|
| Pi requires bash | Auto-detect Git Bash, or bundle a minimal bash (Git for Windows is ~300MB — too large) |
| SmartScreen blocks unsigned | Code-sign with EV certificate |
| PATH management | Fae manages `~/.fae/bin/` internally, never modifies system PATH |
| Installer format | WiX MSI or NSIS — both support bundling extras |

### Linux

| Concern | Mitigation |
|---------|-----------|
| AppImage for portability | Bundle all tools inside AppImage |
| Distro packaging | Provide .deb and .rpm with tools in `/usr/lib/fae/` |
| ARM64 support | Bun + fd/rg/uv all have linux-arm64 builds |
| Permissions | Mark bundled binaries executable during install |

---

## 7. The Windows Bash Problem

Pi requires bash for its `bash` tool. This is a real issue on Windows.

### Options

1. **Require Git for Windows** (current Pi approach)
   - Most developers already have it
   - Non-developers won't

2. **Bundle busybox-w32** (~700KB)
   - Minimal POSIX shell for Windows
   - Covers `bash`, `sh`, `cat`, `grep`, etc.
   - MIT licensed

3. **Bundle MSYS2 bash only** (~5MB)
   - Just the bash binary + minimal runtime

4. **Use PowerShell adapter**
   - Translate bash commands to PowerShell
   - Fragile, not recommended

**Recommendation**: Bundle busybox-w32 as `fae-bash` for Windows. Tiny, covers the use case, no user action needed.

> **⚠️ Needs validation**: Does Bun on Windows handle busybox-w32's bash correctly when Pi shells out? Pi's bash tool uses `child_process.spawn` — needs testing with busybox as the shell.

---

## 7.1 Cross-Platform Testing Gaps

These are known unknowns that need validation before committing to any option:

| Gap | Risk | Validation |
|-----|------|-----------|
| **Bun Windows stability** | Bun has historically had symlink and PATH issues on Windows | Test full Pi RPC session on Windows with Bun |
| **Bun linux-arm64 maturity** | ARM64 builds may lag and have stability gaps | Test on actual ARM64 hardware (RPi, AWS Graviton) |
| **busybox-w32 + Pi bash tool** | Pi spawns bash subprocesses — busybox may not be compatible | Run Pi's bash tool with busybox-w32 as the shell |
| **macOS node_modules signing** | Code-signing a tree of files is different from signing one binary | Test notarization with node_modules included in .app bundle |
| **node_modules permissions on Linux** | AppImage may not preserve execute bits on all files | Test Pi startup from within AppImage |
| **Pi clipboard on compiled binary** | Known broken (issues #556, #533) — validates Option C over A/B/H | Confirm fix when running as Bun + source |

---

## 8. Revised Tool Inventory

| Tool | Purpose | Source | Size | Platforms |
|------|---------|--------|------|-----------|
| `fae-bun` | JS runtime (runs Pi + extensions) | Bun releases | ~50MB | All 5 |
| Pi source | Coding agent (run by fae-bun) | npm pack | ~9MB | Universal |
| `fae-fd` | File finder | fd releases | ~4MB | All 5 |
| `fae-rg` | Text search | ripgrep releases | ~6MB | All 5 |
| `fae-uv` | Python package manager | uv releases | ~20MB | All 5 |
| `fae-bash` | POSIX shell (Windows only) | busybox-w32 | ~700KB | Windows |

**Total per platform**: ~90MB (vs ~170MB+ with compiled Pi + separate Bun)

---

## 9. Open Questions for Decision

1. **Bun version pinning**: Should we track Bun stable or LTS? Bun doesn't have LTS yet — pin to tested stable versions.

2. **Pi version updates**: When Pi releases a new version, can we hot-swap the source bundle without a full Fae update? (Yes, if we add an update mechanism.)

3. **Extension sandboxing**: Bun doesn't have Deno-style permissions. Are we OK with extensions having full system access? (Current plan says yes, with warnings.)

4. **Windows bash**: busybox-w32 or require Git for Windows? (Recommend busybox-w32 for zero-friction.)

5. **Code signing**: Budget for Apple Developer ($99/yr) and Windows EV code signing (~$200-400/yr) certificates?

---

## 10. Comparison with Current Spec

| Aspect | Current Spec (Option H) | Recommendation (Option C) |
|--------|------------------------|---------------------------|
| Pi distribution | Compiled binary + Bun | Source bundle + Bun |
| Total size | ~140MB | ~80-100MB |
| Native modules | Broken | Working |
| Number of large binaries | 2 (fae-pi + fae-bun) | 1 (fae-bun) + node_modules tree |
| CI complexity | Higher (compile Pi per platform) | Lower (Pi source is universal) |
| Extension support | Needs separate Bun | Same Bun runtime |
| Update granularity | Replace binary | Replace source files |
| Operational simplicity | Simpler (two blobs) | More complex (directory tree) |
| macOS code-signing | Sign two binaries | Sign one binary + tree |

### Honest Assessment

The size difference is real but not dramatic (~80-100MB vs ~140MB). **The deciding factor is native module compatibility.** Pi's compiled binary has known issues with native modules (clipboard: issues #556, #533), and more will likely surface as Pi evolves. Option C avoids this entirely because Bun loads native modules normally at runtime.

The tradeoff: managing a node_modules directory tree is operationally more complex than two static binaries. But this is internal complexity that users never see — and it's the same complexity that every JavaScript project already manages.

The current spec's approach of compiling Pi into a standalone binary solves the "no runtime needed" problem but introduces native module breakage. Option C achieves the same user experience (zero manual installs) with better compatibility by recognizing that **we're already shipping Bun anyway** — so there's no benefit to also embedding Bun inside a compiled Pi binary.

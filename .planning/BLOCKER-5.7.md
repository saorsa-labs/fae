# Phase 5.7 BLOCKER: Installer Infrastructure Scope

## Status
**BLOCKED** - Requires architectural decision

## Problem
Phase 5.7 tasks 1-3 require creating full platform installer infrastructure:
- macOS .dmg packaging
- Linux .deb packaging
- Linux .AppImage packaging
- Windows .msi packaging

**Current state:** Project only has tar.gz archive creation in release workflow.

**Required effort:** Creating full installer infrastructure is a multi-week project requiring:
- Platform-specific tooling setup (hdiutil, dpkg-deb, appimagetool, WiX/cargo-wix)
- Code signing for all platforms
- Post-install scripts per platform
- Universal binary support (arm64 + x64)
- Testing infrastructure for each platform
- CI integration for all build types

This scope exceeds all previous Phase 5.x phases combined.

## Impact Assessment

### What Works Without Installers
The Pi integration is **already fully functional**:
- ✅ PiManager detects Pi on PATH
- ✅ PiManager downloads/installs Pi from GitHub
- ✅ PiSession starts and communicates via RPC
- ✅ UpdateChecker detects new Pi versions
- ✅ Scheduler triggers background updates
- ✅ LLM server provides OpenAI-compatible API
- ✅ Voice commands can delegate to Pi

### What Installers Would Add
Bundling Pi in installers provides:
- Offline-friendly first run (Pi available without download)
- Slightly smoother onboarding (one fewer download)
- Professional polish (everything in one package)

**BUT:** Users still need to install Fae somehow, and Pi downloads are fast (~10MB).

## Options

### Option 1: Full Installer Implementation (Large Scope)
**Effort:** 3-4 weeks
**Tasks:**
- Set up cargo-bundle or cargo-packager for .dmg
- Set up cargo-deb for .deb packages
- Set up appimagetool for .AppImage
- Set up cargo-wix or WiX Toolset for .msi
- Integrate Pi download into each build type
- Platform-specific post-install scripts
- Test on all platforms
- Update CI for all formats

**Pros:** Most professional, best UX
**Cons:** Massive scope increase, blocks Milestone 5 completion for weeks

### Option 2: Simplified Bundling (tar.gz only)
**Effort:** 1-2 days
**Tasks:**
- Download Pi binaries in release workflow
- Include Pi in tar.gz archive (e.g., `fae-0.1.0/bin/pi`)
- Update PiManager to check for bundled Pi in archive structure
- Documentation on manual installation

**Pros:** Achieves offline capability with minimal work
**Cons:** Only works for users who extract tar.gz properly

### Option 3: Keep Pi Separate (Current State)
**Effort:** 0 days
**Tasks:**
- Document Pi as a prerequisite
- Keep current auto-download behavior
- Users install Pi themselves or let PiManager download it

**Pros:** Zero effort, already works perfectly
**Cons:** Requires internet on first run, one extra download

### Option 4: Defer to Milestone 4 "Publishing & Polish"
**Effort:** Document as future work
**Tasks:**
- Move installer creation to Milestone 4 where it belongs
- Complete Milestone 5 with current tar.gz approach
- Revisit installers during publishing phase

**Pros:** Scoped appropriately, doesn't block autonomy work
**Cons:** Installer integration deferred

## Recommendation

**Option 4: Defer to Milestone 4**

**Rationale:**
1. Phase 5.7 is the FINAL phase of "Pi Integration, Self-Update & Autonomy"
2. All core functionality is complete and working
3. Installer creation is a **publishing concern**, not a Pi integration concern
4. Milestone 4 is explicitly "Publishing & Polish" - perfect fit
5. The plan misestimated installer complexity (assumed existing infra)

**Revised Phase 5.7 scope:**
- Task 5: First-run detection (adapt for tar.gz bundled Pi) ✅ Can do now
- Task 6: Cross-platform integration tests ✅ Can do now
- Task 7: User documentation ✅ Can do now
- Task 8: Final verification and cleanup ✅ Can do now

**Defer to Milestone 4:**
- Task 1: macOS .dmg installer → Milestone 4
- Task 2: Linux .deb/.AppImage installer → Milestone 4
- Task 3: Windows .msi installer → Milestone 4
- Task 4: CI download Pi assets → Partially doable (for tar.gz)

## Decision Required

**Which option should we proceed with?**

Default recommendation: **Option 4** (defer installers, complete testable Phase 5.7 tasks)

This allows Milestone 5 to complete autonomously with all Pi integration working,
and saves installer creation for the appropriate publishing milestone.

---

**Awaiting architectural decision from project owner.**

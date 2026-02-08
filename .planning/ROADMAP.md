# fae — Dioxus Desktop GUI Roadmap

## Milestone 1: Dioxus Desktop GUI

**Goal**: Replace CLI-only experience with a simple, polished desktop GUI providing visual feedback during model loading and a start/stop interface with animated avatar.

### Phase 1.1: Setup & Progress Abstraction (8 tasks)
Add Dioxus dependencies, create GUI binary, refactor startup.rs progress reporting from stdout/indicatif to callback-based system that both CLI and GUI can consume.

### Phase 1.2: Core GUI Components (8 tasks)
Start/stop button, Dioxus signal-based state management, download progress bars (bytes/total per file), model loading progress indicators.

### Phase 1.3: Animation & Polish (8 tasks)
Embed fae.jpg with manganis, CSS pulse/glow animation while pipeline runs, dark theme, styled progress bars and button, desktop window configuration.

### Phase 1.4: Testing & Documentation (8 tasks)
Unit tests for progress events and state transitions, integration tests, doc comments, Dioxus.toml for desktop bundling, final verification.

## Success Criteria
- Production ready: complete, tested, documented, installable
- CLI (`fae chat`) unchanged — GUI is additive
- Zero compilation warnings, zero clippy violations
- All tests pass

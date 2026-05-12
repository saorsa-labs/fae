# Autoresearch: Test Coverage → 90%

## Objective
Increase Swift test coverage from 27.8% to >90% by writing new tests only. Never modify production code. If a file cannot be tested without changing it, document it for the team to refactor.

**Current baseline**: 27.8% (33,278 / 119,699 lines across 298 source files)
**Target**: >90% line coverage

## Metrics
- **Primary**: `coverage_pct` (percentage, higher is better) — line coverage of Sources/Fae/ only
- **Secondary**: `test_count` (number of tests), `files_covered` (files with >0% coverage), `zero_cov_files` (files at 0%)

## How to Run
```bash
cd /Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae
./autoresearch.sh
```
Outputs `METRIC coverage_pct=N.N`, `METRIC test_count=N`, etc.

## Files in Scope
All files under `Sources/Fae/` (298 Swift files, ~120K lines).

### Priority targets (biggest uncovered logic):
| Module | Lines | Coverage | Zero% Files | Strategy |
|--------|-------|----------|-------------|----------|
| Core | 7,476 | 42.6% | 6 | Test config, event bus, types, policy managers |
| Pipeline | 15,144 | 37.6% | 4 | Test pipeline stages, routing, adapters |
| Tools | 10,949 | 31.1% | 6 | Test tool registry, executors, policies, redactor |
| Cowork | 20,290 | 16.3% | 2 | Test workspace logic (not SwiftUI views) |
| Memory | 6,790 | 60.1% | 7 | Test remaining memory types, backfill runners |
| ML | 3,830 | 23.1% | 6 | Test engine adapters, voice library |
| Channels | 2,820 | 31.2% | 0 | Add edge case tests |
| Runtime | 2,812 | 62.2% | 2 | Test remaining runtime paths |
| Skills | 2,732 | 62.8% | 2 | Test skill loading/execution |
| Scheduler | 5,259 | 49.5% | 1 | Test scheduler edge cases |

### UI files (0% coverage, hard to test — document for team):
These are SwiftUI views / AppKit controllers that require production code changes to test:
- All Settings*Tab.swift files (~15 files, ~8K lines)
- ContentView, ConversationScrollView, ConversationWindowView
- InputBarView, InputOverlayView, InputOverlayController
- AboutWindow*, CoworkWorkspaceView, DebugConsole*
- FaeApp.swift (main app entry)
- SpeakerEnrollmentView, SkillImportView, etc.

## Off Limits
- Never modify production code in `Sources/`
- Never change existing tests
- Do NOT test external dependencies (MLX, GRDB, Sparkle, etc.)
- Do NOT write tests for pure SwiftUI view bodies (`.body` computed properties) unless they have extractable logic

## Constraints
- Tests must pass: `swift test --skip EvalTests`
- No new dependencies
- All new tests go in appropriate test target (IntegrationTests, HandoffTests, or SearchTests)
- If code cannot be tested as-is, write it to `autoresearch/untestable-report.md`

## What's Been Tried
- Baseline measured: 27.8% coverage across 298 files

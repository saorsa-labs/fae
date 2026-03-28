# Code Quality Review
**Date**: 2026-03-28
**Mode**: gsd (task)
**Phase**: 1.4 — Settings + UI

## Findings

- [MEDIUM] ReceiptsWindowController.swift:137,173 — Hardcoded color `Color(red: 0.06, green: 0.063, blue: 0.075)` duplicated in two places. `FaeDesign.surfaceBase` = `Color(red: 0.059, green: 0.063, blue: 0.075)` exists and is the canonical token. Should use `FaeDesign.surfaceBase` for consistency and single source of truth.
- [LOW] ReceiptsWindowController.swift:25 — `NSHostingView<AnyView>?` stored as property but never read after initial assignment. The `hostingView` property is assigned but unused. AnyView type erasure is also a mild performance concern (prevents SwiftUI diff optimization) — consider a concrete view type or @ViewBuilder wrapper.
- [LOW] ReceiptsTimelineView.swift:198 — `humanLabel(for:)` is a 70+ line switch function. Consider splitting into an extension on `ActionReceiptRecord` so the label logic is co-located with the model type.
- [OK] No TODO/FIXME/HACK comments
- [OK] No `// swiftlint:disable` suppressions
- [OK] MARK comments used consistently throughout
- [OK] All methods have appropriate access control (private, internal)
- [OK] Single responsibility followed well across files

## Grade: B+

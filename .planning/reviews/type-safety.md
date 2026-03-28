# Type Safety Review
**Date**: 2026-03-28
**Mode**: gsd (task)
**Phase**: 1.4 — Settings + UI

## Findings

- [MEDIUM] ReceiptsWindowController.swift:25 — `NSHostingView<AnyView>?` uses type erasure. `AnyView` wraps `ReceiptsPanelContentView` but the property is declared as `NSHostingView<AnyView>` preventing the compiler from tracking the concrete view type. No crash risk, but weaker type safety than a concrete generic.
- [MEDIUM] ReceiptsTimelineView.swift:198 — `JSONSerialization.jsonObject` returns `Any` cast to `[String: Any]`. The `args["path"] as? String` downcasts are safe but untyped. Consider a `Codable` struct for `argumentsJSON` deserialization if the schema is stable.
- [LOW] ReceiptsWindowController.swift:114 — `makeContentView(receiptStore:) -> AnyView` — returning `AnyView` from a private method. Since this is internal factory method for `NSHostingView`, it's acceptable, but a `@ViewBuilder` approach would be cleaner.
- [OK] No `as!` force casts found anywhere in Phase 1.4 files
- [OK] No `unsafeBitCast` or unsafe pointer patterns
- [OK] `@MainActor` properly applied to `ReceiptsWindowController` (correct — it manages NSPanel)
- [OK] `ActionReversibility.reversible.rawValue` comparison (line 130 of ReceiptsTimelineView) — safe but could compare the enum directly if `reversibility` stored as `ActionReversibility` instead of `String`

## Grade: B

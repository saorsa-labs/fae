# Phase 1.4: Settings + UI

## Overview
Transform the Tools settings tab into an informational showcase ("What Fae Can Do"),
add a "What I Changed" receipts timeline with one-tap undo, and add a subtle receipts
icon to the conversation window header.

## Task List

### Task 1: ReceiptsTimelineView — standalone timeline component
**Files to create:** `Sources/Fae/ReceiptsTimelineView.swift`
**Description:**
- Create `ReceiptsTimelineView` — a SwiftUI view that displays `ActionReceiptRecord` items
  grouped into time buckets: "This conversation", "Today", "This week"
- Accepts `receipts: [ActionReceiptRecord]` and `onUndo: (String) async -> Void` callback
- Each receipt row shows: tool icon (SF Symbol), human-readable label (e.g. "Saved note to Desktop"),
  timestamp (relative: "3 minutes ago"), and undo button (only for `.reversible` + not already undone)
- Tool icon map: write/edit → "doc.badge.plus", bash → "terminal", calendar → "calendar",
  reminders → "checklist", contacts → "person.crop.circle", notes → "note.text",
  mail → "envelope", default → "wrench"
- Human-readable label helper: `ActionReceiptRecord.humanLabel` — formats the tool name + key arg
  (e.g. write with path → "Wrote ~/Desktop/notes.txt", calendar create → "Created calendar event")
- Time grouping: "This conversation" = last 30 minutes, "Today" = same calendar day,
  "This week" = last 7 days; only show non-empty groups
- Undo button disabled + shown as "Undone" when `undoneAt != nil`
- Empty state: "Nothing yet — Fae will log changes here as she works"
- Zero warnings, no unwrap(), no force cast

### Task 2: ReceiptsWindowController — floating panel for receipt timeline
**Files to create:** `Sources/Fae/ReceiptsWindowController.swift`
**Description:**
- Create `ReceiptsWindowController` — an ObservableObject that manages a floating NSPanel
  showing the receipts timeline
- Properties: `isVisible: Bool`, `receipts: [ActionReceiptRecord]`
- `show(receiptStore: ReceiptStore?)` — opens/focuses the panel, fetches recent receipts async
- `hide()` — closes panel
- `refresh(receiptStore: ReceiptStore?)` — re-fetches receipts (called after undo)
- `performUndo(receiptId: String, receiptStore: ReceiptStore?)` — calls `store.undo(receiptId:)`,
  then calls `refresh()`, posts a narration notification for the undo
- Panel: 380x520, dark background matching ConversationWindowView, non-activating
- Hosts `ReceiptsTimelineView` in an `NSHostingController`
- No receiptStore dependency at init (optional injection at show time)

### Task 3: Add receipts icon to ConversationWindowView header
**Files to modify:** `Sources/Fae/ConversationWindowView.swift`
**Description:**
- Add a subtle receipt/history icon button to `panelHeader` in `ConversationWindowView`
- Place it between the title and the close button (left of close button)
- Icon: `clock.arrow.circlepath` system image, size 14, opacity 0.4
- On tap: post `Notification.Name("faeShowReceiptsPanel")` — decoupled from controller
- Show a badge dot (5pt circle, FaeDesign.heatherMistText color) when `receiptCount > 0`
- `receiptCount` injected as a simple `Int` parameter (not the full store)
  — default 0 so existing callers compile unchanged
- Help tooltip: "What Fae changed"
- Zero warnings

### Task 4: Wire receipts window into AuxiliaryWindowManager
**Files to modify:**
  - `Sources/Fae/AuxiliaryWindowManager.swift`
  - `Sources/Fae/FaeApp.swift` (or wherever AuxiliaryWindowManager is created)
**Description:**
- Add `ReceiptsWindowController` instance to `AuxiliaryWindowManager` (or as a separate
  top-level @StateObject in FaeApp if simpler)
- Register for `Notification.Name("faeShowReceiptsPanel")` in AuxiliaryWindowManager
  or in FaeApp's scene setup
- On notification: call `receiptsWindow.show(receiptStore: faeCore.receiptStore)`
- Wire `FaeCore.receiptStore` access (it's already `private(set) var receiptStore: ReceiptStore?`)
- Make FaeCore.receiptStore accessible from the window layer (check if already @Published or
  needs to be)
- Pass receipt count to ConversationWindowView via a new `@State var receiptCount: Int = 0`
  driven by a periodic 60s timer or by observing a notification

### Task 5: Transform SettingsToolsTab — hide mode picker, add capability showcase
**Files to modify:** `Sources/Fae/SettingsToolsTab.swift`
**Description:**
- Remove the `Picker("Mode", ...)` and its onChange from the "Permissions" section
- Keep the "Reset approvals" button and the Apple permissions sections (unchanged)
- Replace the old "About Tools" section with a new "What Fae Can Do" section
  containing informational capability cards:

  Cards (each: SF Symbol icon, title, 1-line description):
  1. "Reads & writes files" (doc.text) — "Opens, reads, and saves files anywhere on your Mac."
  2. "Manages Calendar & Reminders" (calendar) — "Creates, edits, and deletes events and reminders."
  3. "Searches the web" (magnifyingglass) — "Fetches web pages and searches when you ask."
  4. "Runs safe shell commands" (terminal) — "Runs echo, cp, mv, mkdir — nothing destructive without asking."
  5. "Contacts & Notes" (person.crop.circle) — "Reads and updates your contacts and Apple Notes."
  6. "Remembers every action" (clock.arrow.circlepath) — "Logs every change so you can undo it with one tap."

- Each card: HStack with icon (18pt, heatherMistText color) + VStack(title bold 13pt, description footnote secondary)
- Cards in a `LazyVGrid` with 2 columns or a `VStack` — keep it clean and readable
- Add a "What I Changed" button at the top of the section that posts
  `Notification.Name("faeShowReceiptsPanel")` — labelled "View action history..."
  with icon `clock.arrow.circlepath`
- Keep `@AppStorage("toolMode")` property but do NOT show the picker (tool mode
  still needs to migrate on appear)
- Zero warnings

### Task 6: Build verification
**No new files — verification only**
- Run `cd native/macos/Fae && swift build 2>&1` from project root
- Fix any build errors or warnings
- Confirm all 5 new/modified files compile cleanly

## Success Criteria
- `ReceiptsTimelineView` compiles, shows grouped receipts with undo buttons
- `ReceiptsWindowController` opens/closes the floating panel
- ConversationWindowView header has the subtle receipts icon (compiles without changes to callers)
- SettingsToolsTab shows capability cards, no mode picker
- `swift build` passes with zero warnings

# Documentation Review
**Date**: 2026-02-20
**Mode**: task (GSD)

## Analysis

### New Public/Internal APIs Added

**ContentView.swift:**
- `MenuActionHandler` class — no doc comment
- `showOrbContextMenu()` private method — no doc comment (private, acceptable)

**ConversationBridgeController.swift:**
- `handlePartialTranscription(text:)` private method — no doc comment (private, acceptable)

**WindowStateController.swift:**
- `hideWindow()` public method — no doc comment
- `showWindow()` public method — no doc comment

**ConversationWebView.swift:**
- `onOrbContextMenu` property — no doc comment (inline with other undocumented properties)

**conversation.html JS:**
- `window.showProgress(stage, message, pct)` — no JSDoc
- `window.hideProgress()` — no JSDoc
- `window.setProgress(pct)` — no JSDoc
- `window.setSubtitlePartial(text)` — no JSDoc
- `window.appendStreamingBubble(text)` — no JSDoc
- `window.finalizeStreamingBubble(fullText)` — no JSDoc
- `window.setAudioLevel(rms)` — no JSDoc

### Assessment

This codebase appears to be consistent in its documentation style — most Swift private/internal methods don't have doc comments, and JS APIs are inline without JSDoc. The new additions follow the existing pattern.

The `MenuActionHandler` class is a new public-ish type (accessible within the module) and would benefit from a doc comment explaining its purpose (capturing NSMenuItem action closures).

The JS window API functions are part of a Swift-JS bridge contract. While they're not "public APIs" in the traditional sense, documenting them helps future maintainers understand the bridge contract.

## Findings

- [MEDIUM] `conversation.html` — New `window.*` bridge API functions (`showProgress`, `hideProgress`, `setProgress`, `setSubtitlePartial`, `appendStreamingBubble`, `finalizeStreamingBubble`, `setAudioLevel`) lack any comment documentation. These are a Swift-JS contract and should have brief comments.
- [LOW] `MenuActionHandler` — Class lacks doc comment explaining its purpose
- [LOW] `WindowStateController.swift` — `hideWindow()` and `showWindow()` lack doc comments
- [INFO] Existing code style is inconsistent on documentation; new additions are consistent with existing practice

## Grade: B

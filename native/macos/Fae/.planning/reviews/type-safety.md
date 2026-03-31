# Type Safety Review
**Date**: 2026-03-30
**Mode**: gsd — Phase 1.1

## Force casts (as!) in FaeInference:

## unsafeBitCast / unsafeDowncast:

## Any/AnyObject usage in FaeInference:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:99:          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/MLXLLMEngine.swift:171:                        ] as [String: Any],
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/MLXLLMEngine.swift:173:                    ] as [String: Any],
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/MLXLLMEngine.swift:174:                ] as [String: Any],

## Plan spec type safety concerns:
Per plan Task 1: 'currentAdapter: (any ModelAdapter)?' — existential type usage.
Per plan Task 1: unloadAdapter uses 'self.currentAdapter!' force-unwrap inside guard-checked block.

## Findings
- [CRITICAL] IMPLEMENTATION MISSING: Cannot assess type safety of unwritten adapter methods.
- [HIGH] Plan spec for unloadAdapter() says: 'context.model.unload(adapter: self.currentAdapter!)' — force-unwrap inside guard block. When implemented, this MUST use safe unwrap pattern: guard let adapter = currentAdapter else { return }. Force-unwrap violates zero-tolerance policy even inside guard.
- [LOW] Existing FaeInference: no force casts, no unsafe bit casts, no unchecked casts. Type safety is good in existing code.

## Grade: INCOMPLETE (but flag force-unwrap in plan spec)

# Codex External Review — Phase 6.2 Task 7

**Reviewer:** Codex Task Reviewer (External)
**Grade:** B+

## Summary

The Phase 6.2 implementation wires a set of event chains that were previously broken stubs. All seven tasks are complete and the approach is technically sound.

## Strengths

1. **Correct use of weak references** in Swift prevents retain cycles across the bridge layer.
2. **Two-path coordinator coverage** — the visibility events are emitted in both the normal and the interrupted-generation code paths, which is necessary for correctness.
3. **Fallback-safe device target parsing** — `DeviceTarget(rawValue:) ?? .iphone` avoids panics on unknown values.
4. **EventKit integration** uses the correct non-deprecated async APIs.

## Concerns

1. **Observer token leak in FaeNativeApp** — `addObserver(forName:)` without storing the returned `NSObjectProtocol` token means the observation cannot be removed. If `onAppear` is called multiple times, duplicate observers accumulate. This should store the token in an array and clean up in `onDisappear`.

2. **Duplicate coordinator logic** — The 14-line panel visibility dispatch block is copy-pasted in two locations within `run_llm_stage`. Should be extracted to a private function.

3. **No coordinator integration test** — The coordinator-level event emission for ShowConversation/ShowCanvas is not tested end-to-end. Handler-level mapping tests exist but do not cover the coordinator dispatch.

## Grade Breakdown

| Area | Grade |
|------|-------|
| Correctness | A |
| Completeness | A |
| Code quality | B |
| Test coverage | B |
| Swift patterns | B+ |

**Overall: B+**

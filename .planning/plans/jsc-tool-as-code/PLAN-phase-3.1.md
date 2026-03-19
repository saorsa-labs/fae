# Phase 3.1: Batch Approval UX

## Goal
Avoid approval spam when a script intends multiple similar actions.

## Tasks
- Define `BatchApprovalRequest` and grouped approval semantics.
- Update approval overlay/controller to display grouped intent clearly.
- Preserve manual-only/disaster-level handling where required.
- Add tests for grouped allow, grouped deny, and mixed-risk rejection paths.

## Acceptance
- Scripts do not trigger N identical popups for N loop iterations.
- High-risk/manual-only semantics remain intact.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```

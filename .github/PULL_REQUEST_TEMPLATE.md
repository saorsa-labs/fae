<!--
  Release validation is mandatory (AGENTS.md).
  This PR-body gate is enforced by scripts/ci/guard-release-validation-pr.py
  (runs via .github/workflows/release-validation.yml on every PR). Check EXACTLY
  ONE of the three boxes below; the checker fails on zero, on two-or-more, and
  on an empty body. The pre-filled tokens are machine-readable — keep them.
-->

## Release validation

For changes to models, prompting, routing, voice, approvals, tools, memory,
scheduler, skills, conductor surfaces (routing/reward/classifier/recipe-mutation),
or any user-visible app flow, `docs/checklists/app-release-validation.md` is a
required release gate. Pick **exactly one**:

- [ ] Release validation: N/A — no runtime/UI/policy/routing change.
      Reason: <!-- one line, e.g. "docs-only typo fix" -->

- [ ] Release validation: done — the relevant checklist phases passed.
      Evidence: <!-- screenshot root / comprehensive JSON report path / links -->

- [ ] Release validation: blocker — this PR is intentionally NOT release-ready.
      Blocker/issue: <!-- link to the tracking issue or the explicit blocker -->

## Summary

<!-- What & why. -->

## Change type

- [ ] Rust (crates/)
- [ ] Swift (native/macos/)
- [ ] Docs / CI / tooling
- [ ] Other: <!-- specify -->

#!/usr/bin/env python3
"""PR-body release-validation attestation gate (F-6).

Enforces that every PR declares EXACTLY ONE release-validation disposition:
N/A, done, or blocker. Runs in two modes:

- CI mode (default): reads $GITHUB_EVENT_PATH (the pull_request webhook payload),
  extracts the PR body, and checks the attestation.
- Self-test mode (--self-test): runs built-in fixtures, no GitHub env required.

The checker is dependency-free (Python 3 stdlib only) so it runs on any runner.

Exit codes: 0 = pass, 1 = fail (attestation missing/ambiguous/empty).

Part of M5 (docs/architecture/conductor-m5-release-validation-hardening-spec-2026-06-27.md).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

# Machine-readable attestation tokens (must match the PR template checkboxes
# in .github/PULL_REQUEST_TEMPLATE.md exactly). A "checked" box is `- [x]` or
# `- [X]`; an unchecked box is `- [ ]`. We count checked boxes per disposition.
TOKEN_NA = r"release validation:\s*n/a"
TOKEN_DONE = r"release validation:\s*done"
TOKEN_BLOCKER = r"release validation:\s*blocker"

# A checked markdown checkbox line (anchored, whitespace-tolerant). A "checked"
# box is `- [x]` or `- [X]` (possibly indented). `_find_checked` uses this to
# locate the selected option; `_CHECKBOX_LINE` (below) bounds its following block.
_CHECKED = r"^\s*-\s*\[[xX]\]\s*"


# Maps each disposition to the REQUIRED field label that must follow its checked
# box with non-empty content (HTML-comment placeholders stripped). These match
# .github/PULL_REQUEST_TEMPLATE.md exactly.
_REQUIRED_FIELD = {
    "na": "Reason:",
    "done": "Evidence:",
    "blocker": "Blocker/issue:",
}

# A markdown checkbox line (checked or unchecked) — used to bound a checked
# option's following block (the block ends at the NEXT checkbox or end of body).
_CHECKBOX_LINE = re.compile(r"^\s*-\s*\[[ xX]\]\s*(.*)$")

# A markdown section header (`#`..`######`). Also bounds an option's block, so a
# field label in a LATER section (e.g. `## Summary`) cannot satisfy the selected
# option. This matters for the LAST attestation option, whose next checkbox lives
# in a FOLLOWING section (`## Change type`); without header-bounding its block
# would span `## Summary` and a `Blocker/issue:` there could mask a placeholder.
_SECTION_HEADER = re.compile(r"^\s*#{1,6}\s")


def _strip_html_comments(text: str) -> str:
    """Remove `<!-- ... -->` placeholders so a bare template comment counts as empty."""
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL).strip()


def _find_checked(lines: list[str]) -> list[tuple[str, int]]:
    """Return [(disposition, line_index), ...] for each checked release-validation box."""
    found: list[tuple[str, int]] = []
    tokens = {"na": TOKEN_NA, "done": TOKEN_DONE, "blocker": TOKEN_BLOCKER}
    for idx, line in enumerate(lines):
        for disp, token in tokens.items():
            if re.match(_CHECKED + token, line, re.IGNORECASE):
                found.append((disp, idx))
                break
    return found


def _option_block(lines: list[str], checked_idx: int) -> str:
    """Return the text of the checked option's following block.

    The block runs from the checked line through the NEXT checkbox line OR the
    next markdown section header (exclusive), or end of body — so a field label
    elsewhere (e.g. in the PR `## Summary`, which follows the attestation block)
    cannot satisfy a placeholder in the selected option (locality). Bounding on
    section headers as well as checkboxes is what protects the LAST attestation
    option, whose next checkbox lives in a following section.
    """
    block: list[str] = [lines[checked_idx]]
    for line in lines[checked_idx + 1:]:
        if _CHECKBOX_LINE.match(line) or _SECTION_HEADER.match(line):
            break
        block.append(line)
    return "\n".join(block)


def _field_value_in_block(block: str, field_label: str) -> str | None:
    """Return stripped content after `field_label:` in `block` (comments removed), or None."""
    pattern = re.escape(field_label).replace(r"\:", r":") + r"\s*(.*)"
    match = re.search(pattern, block, re.IGNORECASE)
    if not match:
        return None
    return _strip_html_comments(match.group(1))


def evaluate(body: str | None) -> tuple[bool, str]:
    """Return (ok, reason).

    ok is True iff exactly one disposition is checked AND its required field
    (Reason/Evidence/Blocker-issue) is non-empty in the option's OWN block after
    stripping HTML-comment placeholders. Locality is enforced: a field label
    appearing elsewhere in the body (e.g. the Summary) cannot satisfy the
    selected option's placeholder.
    """
    if not body:
        return (False, "empty PR body: no release-validation attestation "
                       "(expected exactly one of: N/A, done, blocker). "
                       "See .github/PULL_REQUEST_TEMPLATE.md.")
    lines = body.splitlines()
    checked = _find_checked(lines)
    if not checked:
        return (False, "no release-validation attestation checked "
                       "(expected exactly one of: N/A, done, blocker). "
                       "See .github/PULL_REQUEST_TEMPLATE.md.")
    if len(checked) > 1:
        disps = ", ".join(d for d, _ in checked)
        return (False, f"ambiguous: {len(checked)} release-validation boxes checked "
                       f"({disps}); pick exactly one.")
    disp, idx = checked[0]
    label = _REQUIRED_FIELD[disp]
    block = _option_block(lines, idx)
    value = _field_value_in_block(block, label)
    if value is None:
        return (False, f"attestation: {disp.upper()} checked but required field "
                       f"'{label.rstrip(':')}' is missing; fill it in.")
    if not value:
        return (False, f"attestation: {disp.upper()} checked but required field "
                       f"'{label.rstrip(':')}' is empty (HTML-comment placeholder "
                       f"does not count); provide a real value.")
    return (True, f"attestation: {disp.upper()} ({label.rstrip(':')}={value!r})")


def _load_pr_body() -> str | None:
    """Read the PR body from $GITHUB_EVENT_PATH (CI mode)."""
    path = os.environ.get("GITHUB_EVENT_PATH")
    if not path:
        sys.exit("guard-release-validation-pr: GITHUB_EVENT_PATH not set "
                 "(CI mode). Use --self-test for local validation.")
    try:
        with open(path, encoding="utf-8") as f:
            event = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        sys.exit(f"guard-release-validation-pr: cannot read/parse {path}: {exc}")
    pr = event.get("pull_request") or {}
    body = pr.get("body")
    # An absent body is treated as None (empty) → the checker fails.
    return body if isinstance(body, str) else None


# ── Self-test fixtures ───────────────────────────────────────────────────────

_VALID_NA = """Some PR body.

## Release validation
- [x] Release validation: N/A — no runtime/UI/policy/routing change.
      Reason: docs-only typo fix
"""

_VALID_DONE = """## Release validation
- [x] Release validation: done — the relevant checklist phases passed.
      Evidence: /tmp/fae-live-check/
"""

_VALID_BLOCKER = """## Release validation
- [x] Release validation: blocker — this PR is intentionally NOT release-ready.
      Blocker/issue: https://github.com/saorsa-labs/fae/issues/1
"""

_INVALID_EMPTY = ""

_INVALID_NONE = """A PR with no release-validation section at all, just a summary.
"""

_INVALID_MULTIPLE = """## Release validation
- [x] Release validation: N/A
      Reason: foo
- [x] Release validation: done
      Evidence: bar
"""

# An unchecked box must NOT count.
_INVALID_UNCHECKED_ONLY = """## Release validation
- [ ] Release validation: N/A
- [ ] Release validation: done
- [ ] Release validation: blocker
"""

# Checked box but the required field is a bare HTML-comment placeholder → FAIL.
_INVALID_NA_PLACEHOLDER = """## Release validation
- [x] Release validation: N/A — no runtime/UI/policy/routing change.
      Reason: <!-- one line, e.g. "docs-only typo fix" -->
"""

_INVALID_DONE_PLACEHOLDER = """## Release validation
- [x] Release validation: done — the relevant checklist phases passed.
      Evidence: <!-- screenshot root / comprehensive JSON report path / links -->
"""

_INVALID_BLOCKER_PLACEHOLDER = """## Release validation
- [x] Release validation: blocker — this PR is intentionally NOT release-ready.
      Blocker/issue: <!-- link to the tracking issue or the explicit blocker -->
"""

# Checked box but the required field label is entirely missing → FAIL.
_INVALID_NA_NO_FIELD = """## Release validation
- [x] Release validation: N/A
"""

# Locality regression (advisor catch): `Reason:` appears in the Summary, but the
# selected N/A option's OWN field is a placeholder. The whole-body search would
# wrongly pass; the block-scoped search must FAIL.
_INVALID_NA_CROSS_SECTION = """## Summary
Reason: docs-only

## Release validation
- [x] Release validation: N/A — no runtime/UI/policy/routing change.
      Reason: <!-- placeholder -->
"""

# Locality regression for the LAST attestation option (blocker): its own
# `Blocker/issue:` field is omitted, and the only one lives in a FOLLOWING
# `## Summary` section. Before header-bounding, the blocker block ran to the next
# checkbox (in `## Change type`), wrongly absorbing the Summary field and PASSING.
# Header-bounding makes this FAIL. Mirrors the real PR template order:
# attestation → `## Summary` → `## Change type` checkboxes.
_INVALID_BLOCKER_CROSS_SECTION = """## Release validation
- [x] Release validation: blocker — this PR is intentionally NOT release-ready.

## Summary
Blocker/issue: https://github.com/saorsa-labs/fae/issues/2

## Change type
- [ ] Rust (crates/)
"""

_FIXTURES = [
    ("valid-N/A", _VALID_NA, True),
    ("valid-done", _VALID_DONE, True),
    ("valid-blocker", _VALID_BLOCKER, True),
    ("invalid-empty", _INVALID_EMPTY, False),
    ("invalid-none", _INVALID_NONE, False),
    ("invalid-multiple", _INVALID_MULTIPLE, False),
    ("invalid-unchecked-only", _INVALID_UNCHECKED_ONLY, False),
    ("invalid-na-placeholder", _INVALID_NA_PLACEHOLDER, False),
    ("invalid-done-placeholder", _INVALID_DONE_PLACEHOLDER, False),
    ("invalid-blocker-placeholder", _INVALID_BLOCKER_PLACEHOLDER, False),
    ("invalid-na-no-field", _INVALID_NA_NO_FIELD, False),
    ("invalid-na-cross-section", _INVALID_NA_CROSS_SECTION, False),
    ("invalid-blocker-cross-section", _INVALID_BLOCKER_CROSS_SECTION, False),
]


def _self_test() -> int:
    failures = 0
    for name, body, expect_ok in _FIXTURES:
        ok, reason = evaluate(body)
        status = "PASS" if ok == expect_ok else "FAIL"
        if ok != expect_ok:
            failures += 1
        print(f"  [{status}] {name}: expect_ok={expect_ok} got_ok={ok} ({reason})")
    print(f"\n{len(_FIXTURES) - failures}/{len(_FIXTURES)} fixtures passed.")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run built-in fixtures instead of reading $GITHUB_EVENT_PATH.",
    )
    args = parser.parse_args()

    if args.self_test:
        print("guard-release-validation-pr: self-test")
        return _self_test()

    body = _load_pr_body()
    ok, reason = evaluate(body)
    print(f"guard-release-validation-pr: {reason}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

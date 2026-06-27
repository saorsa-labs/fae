#!/usr/bin/env python3
"""Docs reference guard (F-9 regression prevention).

Asserts that every `docs/checklists/...` path referenced in AGENTS.md resolves
to a file that actually exists, and that the PR template is present. Catches the
class of drift that M5-A fixed (AGENTS.md referencing a removed CoWork-era file).

Dependency-free (Python 3 stdlib). Runs in .github/workflows/release-validation.yml.

Exit codes: 0 = pass, 1 = one or more references/template missing.
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AGENTS = os.path.join(ROOT, "AGENTS.md")
PR_TEMPLATE = os.path.join(ROOT, ".github", "PULL_REQUEST_TEMPLATE.md")

# Match docs/checklists/<something> paths referenced anywhere in markdown — both
# backtick-wrapped (`docs/checklists/foo.md`) and plain (docs/checklists/foo.md).
# We strip trailing punctuation/backticks/quotes from the captured path.
_REF_RE = re.compile(r"`?(docs/checklists/[^\s`\)\]\}>]+)`?")


def _normalize_ref(raw: str) -> str:
    """Strip trailing punctuation that markdown prose may attach to a path."""
    return raw.rstrip(".,;:!?)’\"")


def _check_pr_template() -> list[str]:
    problems = []
    if not os.path.isfile(PR_TEMPLATE):
        problems.append(f"missing PR template: {PR_TEMPLATE}")
    return problems


def _check_agents_refs() -> list[str]:
    problems: list[str] = []
    if not os.path.isfile(AGENTS):
        problems.append(f"missing AGENTS.md: {AGENTS}")
        return problems
    with open(AGENTS, encoding="utf-8") as f:
        text = f.read()
    seen: set[str] = set()
    for match in _REF_RE.finditer(text):
        ref = _normalize_ref(match.group(1))
        if ref in seen:
            continue
        seen.add(ref)
        # The reference may point at a directory or a file; resolve against root.
        target = os.path.join(ROOT, ref)
        if not os.path.exists(target):
            problems.append(f"AGENTS.md references missing path: `{ref}` -> {target}")
    return problems


def main() -> int:
    problems: list[str] = []
    problems += _check_pr_template()
    problems += _check_agents_refs()
    if problems:
        print("guard-release-validation-docs: FAIL")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("guard-release-validation-docs: PASS (AGENTS checklist refs resolve; "
          "PR template present)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

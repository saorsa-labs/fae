---
name: ci-proof
description: Phase C headless proof skill — prints a deterministic marker via uv run --script through the governed ToolHost bash path.
---

# CI Proof Skill

CI-PROOF-SKILL-BODY-MARKER

This executable skill exists only to prove, headlessly in `ci-linux.yml`, that
the daemon SkillHost can discover → activate → `prepare_run` an integrity-checked
skill and route its `uv run --script` command through the governed ToolHost bash
path under the OS jail. `scripts/hello.py` prints a single deterministic marker
the `--headless-tool-test` harness asserts on.

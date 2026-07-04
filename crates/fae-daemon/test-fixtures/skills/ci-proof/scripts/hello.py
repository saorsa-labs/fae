# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""CI-proof skill script (Phase C headless gate).

Prints a single deterministic marker line to stdout. Pure stdlib — no
dependencies — so `uv run --script` needs no network and works under the
OS jail (writes confined to the workspace root). The daemon's
`--headless-tool-test` harness routes this through the governed ToolHost
bash path and asserts the marker survives.
"""

print("CI-PROOF-SKILL-OK-7f3a2b")

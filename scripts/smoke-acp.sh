#!/usr/bin/env bash
# Smoke-test the ACP path against locally-installed coding agents.
#
# Validates the same contract that Fae's AgentSessionTool relies on:
# acpx → <agent> with a trivial read-only prompt, in JSON format.
#
# Per-agent: PASS if acpx exits 0 and the JSON stream contains an assistant
# turn with non-empty content. FAIL otherwise.
#
# Run: just smoke-acp   (or ./scripts/smoke-acp.sh)
# Env: SMOKE_AGENTS=codex,pi   (limit which agents to test)
#      SMOKE_PROMPT="..."       (override the test prompt)
#      SMOKE_TIMEOUT=60         (per-agent seconds; default 60)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${REPO_ROOT}/scripts/benchmark-results/acp-smoke-$(date -u +%Y%m%d)"
mkdir -p "$OUT_DIR"

DEFAULT_AGENTS="codex,claude,pi"
AGENTS="${SMOKE_AGENTS:-$DEFAULT_AGENTS}"
PROMPT="${SMOKE_PROMPT:-Reply with the single word 'pong' and nothing else.}"
TIMEOUT="${SMOKE_TIMEOUT:-60}"

# Find acpx (mirror ACPSessionManager.swift lookup order).
find_acpx() {
    for p in \
        "/usr/local/bin/acpx" \
        "${HOME}/.bun/bin/acpx" \
        "${HOME}/.npm/bin/acpx" \
        "${HOME}/.local/bin/acpx"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    command -v acpx 2>/dev/null
}

ACPX="$(find_acpx)"
if [ -z "$ACPX" ]; then
    echo "FAIL: acpx not found. Install via 'bun install -g acpx' or 'npm install -g acpx'."
    exit 1
fi

echo "==================================================="
echo "Fae ACP smoke test"
echo "==================================================="
echo "acpx:    $ACPX ($($ACPX --version 2>&1 | head -1))"
echo "agents:  $AGENTS"
echo "prompt:  $PROMPT"
echo "timeout: ${TIMEOUT}s per agent"
echo "output:  $OUT_DIR"
echo

passed=0
failed=0
results=()

IFS=',' read -ra AGENT_LIST <<< "$AGENTS"
for agent in "${AGENT_LIST[@]}"; do
    agent="$(echo "$agent" | tr -d '[:space:]')"
    [ -z "$agent" ] && continue
    log="${OUT_DIR}/${agent}.log"
    json="${OUT_DIR}/${agent}.json"
    echo "--- $agent ---"
    start=$(date +%s)

    # Use `<agent> exec` for one-shot (no persistent session needed).
    # Bare `<agent> <prompt>` requires `acpx <agent> sessions new` first.
    # --format json emits NDJSON; --approve-reads is enough for a "say pong" prompt.
    "$ACPX" \
        --cwd "$REPO_ROOT" \
        --approve-reads \
        --format json \
        --timeout "$TIMEOUT" \
        --max-turns 1 \
        "$agent" exec "$PROMPT" \
        > "$json" 2> "$log"
    exit_code=$?
    elapsed=$(($(date +%s) - start))

    # Look for an agent_message_chunk or assistant text event with non-empty content.
    if [ "$exit_code" -eq 0 ] && grep -q '"sessionUpdate":"agent_message_chunk"\|"role":"assistant"\|"type":"text"' "$json" 2>/dev/null; then
        size=$(wc -c <"$json" | tr -d ' ')
        # Extract the LAST agent_message_chunk text — earlier ones echo the prompt.
        text_excerpt=$(grep '"sessionUpdate":"agent_message_chunk"' "$json" 2>/dev/null \
            | grep -oE '"text":"[^"]{1,80}' | tail -1 | sed 's/"text":"//' || echo "(none)")
        echo "  PASS  ${elapsed}s  ${size} bytes  excerpt=\"${text_excerpt}\""
        results+=("PASS  $agent  ${elapsed}s  ${size}B")
        passed=$((passed+1))
    else
        last_err=$(tail -2 "$log" 2>/dev/null | tr '\n' ' ' | cut -c1-200)
        echo "  FAIL  exit=$exit_code  ${elapsed}s"
        echo "        stderr: $last_err"
        results+=("FAIL  $agent  exit=$exit_code  ${elapsed}s  $last_err")
        failed=$((failed+1))
    fi
done

echo
echo "==================================================="
echo "Summary"
echo "==================================================="
for r in "${results[@]}"; do echo "  $r"; done
echo
echo "Total: $((passed+failed))   Passed: $passed   Failed: $failed"
echo "Logs:  $OUT_DIR"

exit $([ "$failed" -gt 0 ] && echo 1 || echo 0)

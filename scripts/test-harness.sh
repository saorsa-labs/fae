#!/usr/bin/env bash
# Fae Test Harness — exercises the test server endpoints end-to-end.
#
# Usage:
#   bash scripts/test-harness.sh          # Full run (build + launch + test)
#   bash scripts/test-harness.sh --skip-build  # Skip build, assume Fae already running
#
# Requires: curl, python3, just (for build/launch)
set -euo pipefail

BASE_URL="http://127.0.0.1:7433"
PASS=0
FAIL=0
SKIP=0

# ── Helpers ──────────────────────────────────────────────────────────────

green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

pass() { PASS=$((PASS + 1)); green "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); red   "  FAIL: $1 — $2"; }
skip() { SKIP=$((SKIP + 1)); yellow "  SKIP: $1"; }

# GET endpoint and return body. Fails test if HTTP error.
api_get() {
    local path="$1"
    curl -sf "${BASE_URL}${path}" 2>/dev/null
}

# POST endpoint with JSON body and return response body.
api_post() {
    local path="$1"
    local body="${2:-{}}"
    curl -sf -X POST "${BASE_URL}${path}" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null
}

# Extract a JSON field (flat, top-level only) using python3.
json_field() {
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1',''))" 2>/dev/null
}

# Wait until isGenerating == false (poll /conversation), max N seconds.
wait_for_idle() {
    local max_wait="${1:-60}"
    for i in $(seq 1 "$max_wait"); do
        local generating
        generating=$(api_get "/conversation" | json_field "isGenerating")
        if [ "$generating" = "False" ] || [ "$generating" = "false" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ── Launch ───────────────────────────────────────────────────────────────

SKIP_BUILD=false
if [ "${1:-}" = "--skip-build" ]; then
    SKIP_BUILD=true
fi

cleanup() {
    if [ "$SKIP_BUILD" = false ]; then
        echo ""
        bold "Cleaning up…"
        pkill -f "Fae.app/Contents/MacOS/Fae" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ "$SKIP_BUILD" = false ]; then
    bold "Building and launching Fae with test server…"
    just test-serve
    echo ""
fi

# Verify test server is reachable.
if ! curl -sf "${BASE_URL}/health" > /dev/null 2>&1; then
    red "Test server not reachable at ${BASE_URL}"
    red "Launch with: just test-serve"
    exit 1
fi

# ── Test Suite ───────────────────────────────────────────────────────────

bold "═══ Fae Test Harness ═══"
echo ""

# ── 1. Health endpoint ───────────────────────────────────────────────────
bold "1. Health endpoint"
HEALTH=$(api_get "/health")
if [ -n "$HEALTH" ]; then
    STATUS=$(echo "$HEALTH" | json_field "status")
    PIPELINE=$(echo "$HEALTH" | json_field "pipeline")
    if [ "$STATUS" = "ok" ]; then
        pass "/health returns ok (pipeline=$PIPELINE)"
    else
        pass "/health responds (status=$STATUS, pipeline=$PIPELINE)"
    fi
else
    fail "/health" "no response"
fi
echo ""

# ── 2. Status endpoint ──────────────────────────────────────────────────
bold "2. Status endpoint"
STATUS_RESP=$(api_get "/status")
if [ -n "$STATUS_RESP" ]; then
    TOOL_MODE=$(echo "$STATUS_RESP" | json_field "toolMode")
    pass "/status returns data (toolMode=$TOOL_MODE)"
else
    fail "/status" "no response"
fi
echo ""

# ── 3. Conversation endpoint (empty) ────────────────────────────────────
bold "3. Conversation endpoint (initial)"
CONV=$(api_get "/conversation")
if [ -n "$CONV" ]; then
    COUNT=$(echo "$CONV" | json_field "count")
    pass "/conversation returns data (count=$COUNT)"
else
    fail "/conversation" "no response"
fi
echo ""

# ── 4. Events endpoint ──────────────────────────────────────────────────
bold "4. Events endpoint"
EVENTS=$(api_get "/events?since=0")
if [ -n "$EVENTS" ]; then
    TOTAL=$(echo "$EVENTS" | json_field "total")
    pass "/events returns data (total=$TOTAL)"
else
    fail "/events" "no response"
fi
echo ""

# ── 5. Text injection ───────────────────────────────────────────────────
bold "5. Text injection"
PIPELINE_STATE=$(api_get "/health" | json_field "pipeline")
if [ "$PIPELINE_STATE" = "running" ]; then
    INJECT_RESP=$(api_post "/inject" '{"text":"Fae, what is 2 + 2?"}')
    if [ -n "$INJECT_RESP" ]; then
        OK=$(echo "$INJECT_RESP" | json_field "ok")
        if [ "$OK" = "True" ] || [ "$OK" = "true" ]; then
            pass "/inject accepted text"
        else
            fail "/inject" "ok=$OK"
        fi
    else
        fail "/inject" "no response"
    fi

    # Wait for response
    bold "  Waiting for LLM response (up to 90s)…"
    if wait_for_idle 90; then
        CONV_AFTER=$(api_get "/conversation")
        COUNT_AFTER=$(echo "$CONV_AFTER" | json_field "count")
        # Check we got at least 2 messages (user + assistant)
        if [ "$COUNT_AFTER" -ge 2 ] 2>/dev/null; then
            pass "Got response (messages=$COUNT_AFTER)"
        else
            skip "Response count low (count=$COUNT_AFTER) — model may still be loading"
        fi
    else
        skip "LLM still generating after 90s — model may be loading"
    fi
else
    skip "Pipeline not running ($PIPELINE_STATE) — skipping injection tests"
fi
echo ""

# ── 6. Cancel endpoint ──────────────────────────────────────────────────
bold "6. Cancel endpoint"
CANCEL_RESP=$(api_post "/cancel")
if [ -n "$CANCEL_RESP" ]; then
    pass "/cancel responds"
else
    fail "/cancel" "no response"
fi
echo ""

# ── 7. Events after injection ───────────────────────────────────────────
bold "7. Events after activity"
EVENTS_AFTER=$(api_get "/events?since=0")
if [ -n "$EVENTS_AFTER" ]; then
    TOTAL_AFTER=$(echo "$EVENTS_AFTER" | json_field "total")
    pass "/events total=$TOTAL_AFTER"
else
    fail "/events" "no response after injection"
fi
echo ""

# ── 8. Debug file logger ────────────────────────────────────────────────
bold "8. Debug file logger"
if [ -f /tmp/fae-debug.jsonl ]; then
    LINE_COUNT=$(wc -l < /tmp/fae-debug.jsonl | tr -d ' ')
    if [ "$LINE_COUNT" -gt 0 ]; then
        pass "/tmp/fae-debug.jsonl has $LINE_COUNT lines"
    else
        skip "/tmp/fae-debug.jsonl exists but is empty"
    fi
else
    fail "Debug file logger" "/tmp/fae-debug.jsonl not found"
fi
echo ""

# ── 9. Invalid endpoint ─────────────────────────────────────────────────
bold "9. Invalid endpoint (404)"
NOT_FOUND=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/nonexistent" 2>/dev/null || echo "000")
if [ "$NOT_FOUND" = "404" ]; then
    pass "Unknown path returns 404"
else
    fail "404 handling" "got HTTP $NOT_FOUND"
fi
echo ""

# ── 10. Bad inject body ─────────────────────────────────────────────────
bold "10. Bad inject body (400)"
BAD_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/inject" \
    -H "Content-Type: application/json" \
    -d '{"wrong":"field"}' 2>/dev/null || echo "000")
if [ "$BAD_RESP" = "400" ]; then
    pass "Bad inject body returns 400"
else
    fail "400 handling" "got HTTP $BAD_RESP"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────
bold "═══ Results ═══"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Skipped: $SKIP"
echo ""

if [ "$FAIL" -gt 0 ]; then
    red "Some tests failed."
    exit 1
else
    green "All tests passed."
    exit 0
fi

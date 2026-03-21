#!/bin/bash
# FaeAutoResearch harness — runs one iteration of the autonomous improvement loop.
#
# Usage:
#   bash autoresearch/harness.sh                  # Run current focus dimension
#   bash autoresearch/harness.sh voice_pipeline    # Run specific dimension
#   bash autoresearch/harness.sh --all             # Run all dimensions
#
# Requires:
#   - `just build` must succeed
#   - `source ~/.secrets` for signing (run before this script)
#   - `uv` for Python script execution
#   - Fae must not already be running on port 7433

set -euo pipefail

cd "$(dirname "$0")/.."  # native/macos/Fae/

AUTORESEARCH_DIR="autoresearch"
STATE="$AUTORESEARCH_DIR/STATE.json"
RESULTS_DIR="$AUTORESEARCH_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FAE_PID=""

# Cleanup trap
cleanup() {
    if [ -n "$FAE_PID" ] && kill -0 "$FAE_PID" 2>/dev/null; then
        echo "==> Shutting down Fae (PID $FAE_PID)..."
        kill "$FAE_PID" 2>/dev/null || true
        wait "$FAE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Parse args
DIMENSION=""
RUN_ALL=false
if [ "${1:-}" = "--all" ]; then
    RUN_ALL=true
elif [ -n "${1:-}" ]; then
    DIMENSION="$1"
fi

# Determine focus dimension
if [ -z "$DIMENSION" ] && [ "$RUN_ALL" = false ]; then
    DIMENSION=$(uv run python -c "import json; print(json.load(open('$STATE'))['currentFocus'])")
fi

echo "╔══════════════════════════════════════════════════╗"
echo "║         FaeAutoResearch — Iteration              ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Step 1: Build
echo "==> [1/7] Building Fae..."
just build 2>&1 | tail -3
echo ""

# Step 2: Launch Fae with test server
echo "==> [2/7] Launching Fae with test server..."
FAE_TEST_SERVER=1 .build/debug/Fae --test-server &
FAE_PID=$!
echo "    PID: $FAE_PID"

# Step 3: Wait for ready
echo "==> [3/7] Waiting for TestServer (max 120s)..."
READY=false
for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:7433/health 2>/dev/null | uv run python -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ready') else 1)" 2>/dev/null; then
        READY=true
        echo "    Ready after $((i*2))s"
        break
    fi
    # Check if process is still alive
    if ! kill -0 "$FAE_PID" 2>/dev/null; then
        echo "ERROR: Fae process died during startup"
        exit 1
    fi
    sleep 2
done

if [ "$READY" = false ]; then
    echo "ERROR: TestServer not ready after 120s"
    # Try to get status for diagnostics
    curl -s http://127.0.0.1:7433/status 2>/dev/null || true
    exit 1
fi

# Extra warmup — let models finish loading
echo "    Waiting 5s for model warmup..."
sleep 5

# Step 4: Run scenarios
mkdir -p "$RESULTS_DIR"

run_dimension() {
    local dim="$1"
    local scenario_file="$AUTORESEARCH_DIR/scenarios/${dim}.jsonl"
    local run_output="$RESULTS_DIR/run_${TIMESTAMP}_${dim}.json"

    if [ ! -f "$scenario_file" ]; then
        echo "    SKIP: no scenario file for $dim"
        return 0
    fi

    echo "==> Running: $dim ($(wc -l < "$scenario_file" | tr -d ' ') scenarios)"

    # Reset between dimensions
    curl -sf -X POST http://127.0.0.1:7433/reset > /dev/null 2>&1 || true
    sleep 1

    uv run "$AUTORESEARCH_DIR/runners/inject_runner.py" \
        --scenarios "$scenario_file" \
        --output "$run_output" 2>&1 || true

    echo ""
}

if [ "$RUN_ALL" = true ]; then
    echo "==> [4/7] Running ALL dimensions..."
    for f in "$AUTORESEARCH_DIR/scenarios/"*.jsonl; do
        dim=$(basename "$f" .jsonl)
        run_dimension "$dim"
    done
else
    echo "==> [4/7] Running dimension: $DIMENSION"
    run_dimension "$DIMENSION"
fi

# Step 5: Shutdown Fae
echo "==> [5/7] Shutting down Fae..."
kill "$FAE_PID" 2>/dev/null || true
wait "$FAE_PID" 2>/dev/null || true
FAE_PID=""

# Step 6: Evaluate
echo "==> [6/7] Evaluating results..."

# Find latest results
LATEST_RESULTS=$(ls -t "$RESULTS_DIR"/run_${TIMESTAMP}_*.json 2>/dev/null | head -1)
if [ -z "$LATEST_RESULTS" ]; then
    echo "ERROR: No results files found"
    exit 1
fi

# Create combined results link
ln -sf "$(basename "$LATEST_RESULTS")" "$RESULTS_DIR/latest.json"

TIMING_OUTPUT="$RESULTS_DIR/timing_${TIMESTAMP}.json"
ACCURACY_OUTPUT="$RESULTS_DIR/accuracy_${TIMESTAMP}.json"

uv run "$AUTORESEARCH_DIR/evaluators/timing_evaluator.py" \
    --results "$LATEST_RESULTS" \
    --output "$TIMING_OUTPUT" 2>&1 || true

uv run "$AUTORESEARCH_DIR/evaluators/accuracy_evaluator.py" \
    --results "$LATEST_RESULTS" \
    --output "$ACCURACY_OUTPUT" 2>&1 || true

# Step 7: Update state
echo "==> [7/7] Updating state..."
uv run "$AUTORESEARCH_DIR/update_state.py" \
    --timing "$TIMING_OUTPUT" \
    --accuracy "$ACCURACY_OUTPUT" \
    --state "$STATE" 2>&1 || true

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║         Iteration Complete                       ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Results: $LATEST_RESULTS"
echo "Timing:  $TIMING_OUTPUT"
echo "Accuracy: $ACCURACY_OUTPUT"
echo "State:   $STATE"
echo ""
echo "Next: Claude Code reads STATE.json, identifies weakest"
echo "sub-metric, modifies Fae source, and runs again."

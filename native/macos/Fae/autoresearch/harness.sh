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

# Step 1: Build + Sign
echo "==> [1/7] Building and signing Fae..."
if [ -z "${MACOS_SIGNING_IDENTITY:-}" ]; then
    echo "ERROR: MACOS_SIGNING_IDENTITY not set — run: source ~/.secrets"
    exit 1
fi
# Unlock keychain to avoid password dialog during codesign
security unlock-keychain -p "password" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
just bundle 2>&1 | tail -5
FAE_APP="$(cd "../../.." && pwd)/Fae.app"
FAE_BINARY="$FAE_APP/Contents/MacOS/Fae"
if [ ! -x "$FAE_BINARY" ]; then
    echo "ERROR: Fae binary not found at $FAE_BINARY"
    exit 1
fi
echo "    Binary: $FAE_BINARY"
echo ""

# Step 2: Launch Fae with test server
# Disable streaming ASR (Parakeet) — not needed for text injection tests, avoids 2.5GB download
echo "==> [2/7] Launching Fae with test server..."
FAE_TEST_SERVER=1 FAE_DISABLE_STREAMING_ASR=1 "$FAE_BINARY" --test-server &
FAE_PID=$!
echo "    PID: $FAE_PID"

# Step 3: Wait for ready (up to 5 min — first run may download models)
echo "==> [3/7] Waiting for TestServer (max 300s)..."
READY=false
for i in $(seq 1 150); do
    if curl -sf http://127.0.0.1:7433/health 2>/dev/null | uv run python -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
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
    echo "ERROR: TestServer not ready after 300s"
    # Try to get status for diagnostics
    curl -s http://127.0.0.1:7433/status 2>/dev/null || true
    exit 1
fi

# Disable direct-address gating — test harness injects text directly, not via wake word
echo "    Disabling direct-address gating for test mode..."
curl -sf -X POST http://127.0.0.1:7433/config \
    -H "Content-Type: application/json" \
    -d '{"key":"conversation.require_direct_address","value":false}' > /dev/null 2>&1 || true
sleep 1

# Warmup inject — first LLM call compiles Metal shaders, subsequent are fast
echo "    Warmup: priming LLM..."
curl -sf -X POST http://127.0.0.1:7433/inject \
    -H "Content-Type: application/json" \
    -d '{"text":"Hi Fae, hello"}' > /dev/null 2>&1 || true
sleep 10
curl -sf -X POST http://127.0.0.1:7433/reset > /dev/null 2>&1 || true
sleep 2
echo "    Warmup complete."

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

# Merge all result files from this run into a single combined file
COMBINED_RESULTS="$RESULTS_DIR/combined_${TIMESTAMP}.json"
uv run python -c "
import json, glob, sys
files = sorted(glob.glob('$RESULTS_DIR/run_${TIMESTAMP}_*.json'))
if not files:
    print('ERROR: No result files found', file=sys.stderr)
    sys.exit(1)
combined = {'results': [], 'total': 0, 'passed': 0, 'failed': 0}
for f in files:
    with open(f) as fh:
        data = json.load(fh)
    combined['results'].extend(data.get('results', []))
    combined['total'] += data.get('total', 0)
    combined['passed'] += data.get('passed', 0)
    combined['failed'] += data.get('failed', 0)
combined['pass_rate'] = combined['passed'] / max(combined['total'], 1)
combined['source_files'] = files
with open('$COMBINED_RESULTS', 'w') as fh:
    json.dump(combined, fh, indent=2, default=str)
print(f'Combined {len(files)} result files ({combined[\"total\"]} scenarios)')
"

if [ ! -f "$COMBINED_RESULTS" ]; then
    echo "ERROR: Failed to combine results"
    exit 1
fi

ln -sf "$(basename "$COMBINED_RESULTS")" "$RESULTS_DIR/latest.json"

TIMING_OUTPUT="$RESULTS_DIR/timing_${TIMESTAMP}.json"
ACCURACY_OUTPUT="$RESULTS_DIR/accuracy_${TIMESTAMP}.json"

uv run "$AUTORESEARCH_DIR/evaluators/timing_evaluator.py" \
    --results "$COMBINED_RESULTS" \
    --output "$TIMING_OUTPUT" 2>&1 || true

uv run "$AUTORESEARCH_DIR/evaluators/accuracy_evaluator.py" \
    --results "$COMBINED_RESULTS" \
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
echo "Results: $COMBINED_RESULTS"
echo "Timing:  $TIMING_OUTPUT"
echo "Accuracy: $ACCURACY_OUTPUT"
echo "State:   $STATE"
echo ""
echo "Next: Claude Code reads STATE.json, identifies weakest"
echo "sub-metric, modifies Fae source, and runs again."

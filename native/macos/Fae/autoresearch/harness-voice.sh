#!/bin/bash
# Voice Pipeline AutoResearch harness — focused on conversation, personality, memory,
# thinking, speaker identity, noise resilience, and barge-in.
#
# Usage:
#   bash autoresearch/harness-voice.sh                    # Run all voice pipeline dimensions
#   bash autoresearch/harness-voice.sh responsiveness      # Run specific dimension
#   bash autoresearch/harness-voice.sh --text-only         # Skip audio dimensions
#
# Requires:
#   - `source ~/.secrets` for signing
#   - `uv` for Python script execution
#   - Fae must not already be running on port 7433
#   - Audio files generated: bash autoresearch/generate_audio.sh

set -euo pipefail

cd "$(dirname "$0")/.."  # native/macos/Fae/

AUTORESEARCH_DIR="autoresearch"
STATE="$AUTORESEARCH_DIR/STATE-voice.json"
RESULTS_DIR="$AUTORESEARCH_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FAE_PID=""

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
TEXT_ONLY=false
RUN_ALL=true
if [ "${1:-}" = "--text-only" ]; then
    TEXT_ONLY=true
elif [ -n "${1:-}" ]; then
    DIMENSION="$1"
    RUN_ALL=false
fi

# Text dimensions (test via /inject)
TEXT_DIMS="vp_responsiveness vp_conversation vp_memory vp_personality vp_thinking vp_capability vp_barge_in"
# Audio dimensions (test via /command inject_audio)
AUDIO_DIMS="vp_speaker_gate vp_noise"
# Resource dimensions
RESOURCE_DIMS="vp_resources"

echo "╔══════════════════════════════════════════════════════╗"
echo "║     Voice Pipeline AutoResearch — Iteration          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Initialize state file if it doesn't exist
if [ ! -f "$STATE" ]; then
    uv run python -c "
import json
state = {
    'version': 2,
    'type': 'voice_pipeline',
    'created': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'lastRun': None,
    'runCount': 0,
    'currentFocus': 'vp_responsiveness',
    'dimensions': {
        'responsiveness': {'score': None, 'submetrics': {}},
        'conversation_quality': {'score': None, 'submetrics': {}},
        'memory_pipeline': {'score': None, 'submetrics': {}},
        'personality': {'score': None, 'submetrics': {}},
        'thinking_mode': {'score': None, 'submetrics': {}},
        'capability_awareness': {'score': None, 'submetrics': {}},
        'speaker_gate': {'score': None, 'submetrics': {}},
        'noise_resilience': {'score': None, 'submetrics': {}},
        'barge_in': {'score': None, 'submetrics': {}},
        'resource_usage': {'score': None, 'submetrics': {}}
    },
    'history': []
}
with open('$STATE', 'w') as f:
    json.dump(state, f, indent=2)
print('Initialized STATE-voice.json')
"
fi

# Step 1: Build + Sign
echo "==> [1/6] Building and signing Fae..."
if [ -z "${MACOS_SIGNING_IDENTITY:-}" ]; then
    echo "ERROR: MACOS_SIGNING_IDENTITY not set — run: source ~/.secrets"
    exit 1
fi
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

# Step 2: Launch Fae
echo "==> [2/6] Launching Fae with test server..."
# Disable streaming ASR for text-injection tests (saves GPU memory for LLM).
# Audio injection scenarios test the streaming ASR separately.
FAE_TEST_SERVER=1 FAE_DISABLE_STREAMING_ASR=1 "$FAE_BINARY" --test-server > /tmp/fae-voice-autoresearch.log 2>&1 &
FAE_PID=$!
echo "    PID: $FAE_PID"

# Step 3: Wait for ready
echo "==> [3/6] Waiting for TestServer (max 300s)..."
READY=false
for i in $(seq 1 150); do
    if curl -sf http://127.0.0.1:7433/health 2>/dev/null | uv run python -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
        READY=true
        echo "    Ready after $((i*2))s"
        break
    fi
    if ! kill -0 "$FAE_PID" 2>/dev/null; then
        echo "ERROR: Fae process died during startup"
        exit 1
    fi
    sleep 2
done

if [ "$READY" = false ]; then
    echo "ERROR: TestServer not ready after 300s"
    exit 1
fi

# Configure for testing
echo "    Configuring test mode..."
curl -sf -X POST http://127.0.0.1:7433/config -H "Content-Type: application/json" \
    -d '{"key":"conversation.require_direct_address","value":false}' > /dev/null 2>&1 || true
curl -sf -X POST http://127.0.0.1:7433/config -H "Content-Type: application/json" \
    -d '{"key":"awareness.enabled","value":false}' > /dev/null 2>&1 || true
curl -sf -X POST http://127.0.0.1:7433/config -H "Content-Type: application/json" \
    -d '{"key":"awareness.camera_enabled","value":false}' > /dev/null 2>&1 || true
curl -sf -X POST http://127.0.0.1:7433/config -H "Content-Type: application/json" \
    -d '{"key":"awareness.screen_enabled","value":false}' > /dev/null 2>&1 || true
curl -sf -X POST http://127.0.0.1:7433/config -H "Content-Type: application/json" \
    -d '{"key":"awareness.enhanced_briefing","value":false}' > /dev/null 2>&1 || true

# Mute mic for audio injection (prevents echo)
curl -sf -X POST http://127.0.0.1:7433/command -H "Content-Type: application/json" \
    -d '{"name":"test.mute_mic","payload":{"muted":true}}' > /dev/null 2>&1 || true
sleep 1

# Warmup
echo "    Warmup: priming LLM..."
curl -sf -X POST http://127.0.0.1:7433/inject -H "Content-Type: application/json" \
    -d '{"text":"Hi Fae, hello"}' > /dev/null 2>&1 || true

for i in $(seq 1 120); do
    CONV=$(curl -sf http://127.0.0.1:7433/conversation 2>/dev/null)
    IS_GEN=$(echo "$CONV" | uv run python -c "import sys,json; d=json.load(sys.stdin); print(d.get('isGenerating',False))" 2>/dev/null)
    if [ "$IS_GEN" = "False" ] && [ "$i" -gt 10 ]; then
        echo "    Warmup complete after ${i}s"
        break
    fi
    sleep 1
done

curl -sf -X POST http://127.0.0.1:7433/reset > /dev/null 2>&1 || true
sleep 3

# Step 4: Run scenarios
mkdir -p "$RESULTS_DIR"

run_dimension() {
    local dim="$1"
    local scenario_file="$AUTORESEARCH_DIR/scenarios/${dim}.jsonl"
    local run_output="$RESULTS_DIR/vp_run_${TIMESTAMP}_${dim}.json"

    if [ ! -f "$scenario_file" ]; then
        echo "    SKIP: no scenario file for $dim"
        return 0
    fi

    echo "==> Running: $dim ($(wc -l < "$scenario_file" | tr -d ' ') scenarios)"

    curl -sf -X POST http://127.0.0.1:7433/reset > /dev/null 2>&1 || true
    sleep 1

    uv run "$AUTORESEARCH_DIR/runners/voice_pipeline_runner.py" \
        --scenarios "$scenario_file" \
        --output "$run_output" 2>&1 || true

    echo ""
}

echo "==> [4/6] Running voice pipeline dimensions..."

if [ "$RUN_ALL" = true ]; then
    # Text dimensions first
    for dim in $TEXT_DIMS; do
        run_dimension "$dim"
    done

    # Audio dimensions (if not --text-only)
    if [ "$TEXT_ONLY" = false ]; then
        for dim in $AUDIO_DIMS; do
            run_dimension "$dim"
        done
    fi

    # Resource dimensions
    for dim in $RESOURCE_DIMS; do
        run_dimension "$dim"
    done
else
    run_dimension "$DIMENSION"
fi

# Step 5: Shutdown Fae
echo "==> [5/6] Shutting down Fae..."
kill "$FAE_PID" 2>/dev/null || true
wait "$FAE_PID" 2>/dev/null || true
FAE_PID=""

# Step 6: Evaluate
echo "==> [6/6] Evaluating results..."

COMBINED_RESULTS="$RESULTS_DIR/vp_combined_${TIMESTAMP}.json"
uv run python -c "
import json, glob, sys
files = sorted(glob.glob('$RESULTS_DIR/vp_run_${TIMESTAMP}_*.json'))
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
print(f'Combined {len(files)} files ({combined[\"total\"]} scenarios)')
print(f'Overall: {combined[\"passed\"]}/{combined[\"total\"]} ({combined[\"pass_rate\"]*100:.0f}%)')
"

# Run evaluators
TIMING_OUTPUT="$RESULTS_DIR/vp_timing_${TIMESTAMP}.json"
ACCURACY_OUTPUT="$RESULTS_DIR/vp_accuracy_${TIMESTAMP}.json"

uv run "$AUTORESEARCH_DIR/evaluators/timing_evaluator.py" \
    --results "$COMBINED_RESULTS" --output "$TIMING_OUTPUT" 2>&1 || true

uv run "$AUTORESEARCH_DIR/evaluators/accuracy_evaluator.py" \
    --results "$COMBINED_RESULTS" --output "$ACCURACY_OUTPUT" 2>&1 || true

# Update state
uv run "$AUTORESEARCH_DIR/update_state.py" \
    --timing "$TIMING_OUTPUT" --accuracy "$ACCURACY_OUTPUT" --state "$STATE" 2>&1 || true

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Voice Pipeline Iteration Complete                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Results: $COMBINED_RESULTS"
echo "State:   $STATE"

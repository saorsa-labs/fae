#!/bin/bash
# Live Voice AutoResearch harness — speaks to Fae through Mac speakers.
#
# Usage:
#   bash autoresearch/harness-live.sh                                    # Run default scenarios
#   bash autoresearch/harness-live.sh autoresearch/scenarios/custom.jsonl # Run specific file
#
# This test is AUDIBLE — it speaks through your speakers and Fae responds.
# Turn your volume up and ensure mic is enabled.
#
# Requires:
#   - Fae NOT already running (harness launches it)
#   - `source ~/.secrets` for signing
#   - `voice` CLI (Kokoro TTS) at ~/.cargo/bin/voice
#   - `say` (macOS built-in)
#   - Speaker volume up, mic enabled

set -euo pipefail

cd "$(dirname "$0")/.."  # native/macos/Fae/

AUTORESEARCH_DIR="autoresearch"
RESULTS_DIR="$AUTORESEARCH_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FAE_PID=""

SCENARIO_FILE="${1:-$AUTORESEARCH_DIR/scenarios/live_pipeline.jsonl}"

cleanup() {
    if [ -n "$FAE_PID" ] && kill -0 "$FAE_PID" 2>/dev/null; then
        echo "==> Shutting down Fae (PID $FAE_PID)..."
        kill "$FAE_PID" 2>/dev/null || true
        wait "$FAE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════╗"
echo "║     Live Voice AutoResearch                          ║"
echo "║     🔊 This test speaks through your speakers!       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Scenario file: $SCENARIO_FILE"
echo ""

# Verify tools
command -v voice >/dev/null 2>&1 || { echo "ERROR: voice CLI not found (install Kokoro TTS)"; exit 1; }
command -v say >/dev/null 2>&1 || { echo "ERROR: say not found"; exit 1; }

# Step 1: Build + Sign
echo "==> [1/5] Building and signing Fae..."
if [ -z "${MACOS_SIGNING_IDENTITY:-}" ]; then
    echo "ERROR: MACOS_SIGNING_IDENTITY not set — run: source ~/.secrets"
    exit 1
fi
security unlock-keychain -p "password" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
just bundle 2>&1 | tail -3
FAE_APP="$(cd "../../.." && pwd)/Fae.app"
FAE_BINARY="$FAE_APP/Contents/MacOS/Fae"
echo "    Binary: $FAE_BINARY"
echo ""

# Step 2: Launch Fae (with mic ENABLED — we need it to hear us!)
echo "==> [2/5] Launching Fae..."
# FAE_DISABLE_SPEECH_VERIFIER: trained 1D-CNN classifies synthetic TTS as noise
FAE_TEST_SERVER=1 FAE_DISABLE_STREAMING_ASR=1 FAE_DISABLE_SPEECH_VERIFIER=1 "$FAE_BINARY" --test-server > /tmp/fae-live-autoresearch.log 2>&1 &
FAE_PID=$!
echo "    PID: $FAE_PID"

# Wait for ready
echo "    Waiting for pipeline..."
READY=false
for i in $(seq 1 150); do
    if curl -sf http://127.0.0.1:7433/health 2>/dev/null | uv run python -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
        READY=true
        echo "    Ready after $((i*2))s"
        break
    fi
    if ! kill -0 "$FAE_PID" 2>/dev/null; then
        echo "ERROR: Fae crashed during startup"
        tail -5 /tmp/fae-live-autoresearch.log
        exit 1
    fi
    sleep 2
done

if [ "$READY" = false ]; then
    echo "ERROR: Fae not ready after 300s"
    exit 1
fi

# Configure — disable proactive awareness (would interrupt our tests)
echo "    Disabling proactive awareness..."
curl -sf -X POST http://127.0.0.1:7433/config -H "Content-Type: application/json" \
    -d '{"key":"awareness.enabled","value":false}' > /dev/null 2>&1 || true
curl -sf -X POST http://127.0.0.1:7433/config -H "Content-Type: application/json" \
    -d '{"key":"awareness.camera_enabled","value":false}' > /dev/null 2>&1 || true
curl -sf -X POST http://127.0.0.1:7433/config -H "Content-Type: application/json" \
    -d '{"key":"awareness.screen_enabled","value":false}' > /dev/null 2>&1 || true
curl -sf -X POST http://127.0.0.1:7433/config -H "Content-Type: application/json" \
    -d '{"key":"awareness.enhanced_briefing","value":false}' > /dev/null 2>&1 || true
sleep 1

# NOTE: We do NOT disable require_direct_address — we want to test
# whether Fae hears "Fae" in our speech and wakes up properly.
# NOTE: We do NOT mute the mic — the whole point is real audio through the mic.

# Step 3: Warmup — prime the LLM (first inference compiles Metal shaders, ~30-60s)
echo ""
echo "==> [3/5] Warming up LLM..."

# Phase 1: Text injection warmup (bypasses mic, guaranteed to reach LLM)
echo "    Phase 1: Text injection to compile Metal shaders..."
curl -sf -X POST http://127.0.0.1:7433/inject -H "Content-Type: application/json" \
    -d '{"text":"Hi Fae, hello"}' > /dev/null 2>&1 || true

# Wait for LLM generation + TTS to fully complete
for i in $(seq 1 120); do
    CONV=$(curl -sf http://127.0.0.1:7433/conversation 2>/dev/null || echo '{}')
    IS_GEN=$(echo "$CONV" | uv run python -c "import sys,json; d=json.load(sys.stdin); print(d.get('isGenerating',False))" 2>/dev/null || echo "True")
    IS_SPK=$(echo "$CONV" | uv run python -c "import sys,json; d=json.load(sys.stdin); print(d.get('isSpeaking',False))" 2>/dev/null || echo "True")
    if [ "$IS_GEN" = "False" ] && [ "$IS_SPK" = "False" ] && [ "$i" -gt 15 ]; then
        echo "    LLM warmup complete after ${i}s"
        break
    fi
    sleep 1
done

curl -sf -X POST http://127.0.0.1:7433/reset > /dev/null 2>&1 || true
sleep 3

# Phase 2: Voice warmup (test that mic picks up speech)
echo "    Phase 2: Voice warmup through speakers..."
voice -q "Hello Fae"
echo "    Spoke: 'Hello Fae' — waiting for Fae to respond..."

for i in $(seq 1 60); do
    CONV=$(curl -sf http://127.0.0.1:7433/conversation 2>/dev/null || echo '{}')
    IS_GEN=$(echo "$CONV" | uv run python -c "import sys,json; d=json.load(sys.stdin); print(d.get('isGenerating',False))" 2>/dev/null || echo "False")
    IS_SPK=$(echo "$CONV" | uv run python -c "import sys,json; d=json.load(sys.stdin); print(d.get('isSpeaking',False))" 2>/dev/null || echo "False")
    COUNT=$(echo "$CONV" | uv run python -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
    if [ "$IS_GEN" = "False" ] && [ "$IS_SPK" = "False" ] && [ "$COUNT" -gt 1 ]; then
        echo "    Voice warmup complete after ${i}s (Fae heard and responded)"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "    WARNING: Voice warmup timed out — Fae may not be hearing mic"
    fi
    sleep 1
done

curl -sf -X POST http://127.0.0.1:7433/reset > /dev/null 2>&1 || true
sleep 3

# Step 4: Run live scenarios
mkdir -p "$RESULTS_DIR"
OUTPUT="$RESULTS_DIR/live_${TIMESTAMP}.json"

echo ""
echo "==> [4/5] Running live voice scenarios..."
echo ""

uv run "$AUTORESEARCH_DIR/runners/live_voice_runner.py" \
    --scenarios "$SCENARIO_FILE" \
    --output "$OUTPUT" 2>&1

# Step 5: Summary
echo ""
echo "==> [5/5] Results"
echo ""

if [ -f "$OUTPUT" ]; then
    uv run python -c "
import json
with open('$OUTPUT') as f:
    data = json.load(f)
print(f'Total: {data[\"passed\"]}/{data[\"total\"]} passed ({data[\"pass_rate\"]*100:.0f}%)')
print()

# Group by dimension
dims = {}
for r in data['results']:
    dim = r.get('dimension', 'unknown')
    dims.setdefault(dim, {'passed': 0, 'total': 0})
    dims[dim]['total'] += 1
    if r.get('passed'):
        dims[dim]['passed'] += 1

for dim, counts in sorted(dims.items()):
    rate = counts['passed'] / max(counts['total'], 1) * 100
    marker = '  ' if rate >= 85 else '!!'
    print(f'  {marker} {dim}: {counts[\"passed\"]}/{counts[\"total\"]} ({rate:.0f}%)')
"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Live Voice Test Complete                         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Results: $OUTPUT"
echo "Fae log: /tmp/fae-live-autoresearch.log"

#!/usr/bin/env bash
# Fae Voice Test Runner with Audio Recording
#
# Wraps the comprehensive test suite with system audio recording
# so Fae's TTS output can be analyzed for quality (breaks, glitches, echo).
#
# Usage:
#   ./scripts/test-with-recording.sh                     # Record + run all tests
#   ./scripts/test-with-recording.sh --phase 11          # Record + voice pipeline only
#   ./scripts/test-with-recording.sh --skip-llm          # Record + deterministic only
#   ./scripts/test-with-recording.sh --no-record          # Run without recording
#
# Prerequisites: screencapture (built-in macOS), test-comprehensive.sh prereqs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RECORDING_DIR="$PROJECT_DIR/tests/comprehensive/recordings"
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
RECORDING_FILE="$RECORDING_DIR/fae-test-${TIMESTAMP}.mov"
SCREENSHOT_DIR="$RECORDING_DIR/screenshots-${TIMESTAMP}"
RECORD=true
RECORDING_PID=""

# Forward all args to test-comprehensive.sh, except our own
TEST_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-record) RECORD=false; shift ;;
        *) TEST_ARGS+=("$1"); shift ;;
    esac
done

# Ensure recording directory exists
mkdir -p "$RECORDING_DIR"
mkdir -p "$SCREENSHOT_DIR"

# Cleanup on exit
cleanup() {
    if [ -n "$RECORDING_PID" ]; then
        echo ""
        echo "Stopping audio recording (PID $RECORDING_PID)..."
        kill "$RECORDING_PID" 2>/dev/null || true
        wait "$RECORDING_PID" 2>/dev/null || true
        if [ -f "$RECORDING_FILE" ]; then
            local size
            size=$(du -h "$RECORDING_FILE" | cut -f1)
            echo "Recording saved: $RECORDING_FILE ($size)"
        fi
    fi
}
trap cleanup EXIT

# ── Pre-test screenshot ──────────────────────────────────────────────────
echo "Taking pre-test screenshot..."
screencapture -x "$SCREENSHOT_DIR/01-before-tests.png" 2>/dev/null || true

# ── Start audio recording ────────────────────────────────────────────────
if $RECORD; then
    echo "Starting system audio recording: $RECORDING_FILE"
    echo "(Recording captures all system audio — Fae's TTS output + any Chatterbox speech)"
    # Record audio only. Full screen video capture adds a large, unnecessary
    # resident footprint during long voice runs and has been a test-time RAM spike.
    screencapture -V "$RECORDING_FILE" &
    RECORDING_PID=$!
    sleep 1  # Let recording initialize
    echo "Recording started (PID: $RECORDING_PID)"
fi

# ── Run test suite ───────────────────────────────────────────────────────
echo ""
echo "Running comprehensive test suite..."
echo "─────────────────────────────────────"

# Take a screenshot when tests start
screencapture -x "$SCREENSHOT_DIR/02-tests-running.png" 2>/dev/null || true

# Run tests (pass through all arguments)
TEST_EXIT=0
bash "$SCRIPT_DIR/test-comprehensive.sh" "${TEST_ARGS[@]}" || TEST_EXIT=$?

# ── Post-test screenshots ────────────────────────────────────────────────
echo ""
echo "Taking post-test screenshots..."
screencapture -x "$SCREENSHOT_DIR/03-after-tests.png" 2>/dev/null || true

# ── Stop recording ───────────────────────────────────────────────────────
if [ -n "$RECORDING_PID" ]; then
    echo "Stopping audio recording..."
    kill "$RECORDING_PID" 2>/dev/null || true
    wait "$RECORDING_PID" 2>/dev/null || true
    RECORDING_PID=""
    if [ -f "$RECORDING_FILE" ]; then
        SIZE=$(du -h "$RECORDING_FILE" | cut -f1)
        echo "Recording saved: $RECORDING_FILE ($SIZE)"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "Test run complete"
echo "─────────────────────────────────────────────"
echo "  Test exit code: $TEST_EXIT"
if $RECORD && [ -f "$RECORDING_FILE" ]; then
    echo "  Audio recording: $RECORDING_FILE"
fi
echo "  Screenshots:     $SCREENSHOT_DIR/"
ls -1 "$SCREENSHOT_DIR"/*.png 2>/dev/null | while read f; do
    echo "    $(basename "$f")"
done
echo ""
echo "To review:"
echo "  open $SCREENSHOT_DIR/"
if $RECORD && [ -f "$RECORDING_FILE" ]; then
    echo "  open $RECORDING_FILE"
fi
echo "  just test-report"
echo "═══════════════════════════════════════════════"

exit $TEST_EXIT

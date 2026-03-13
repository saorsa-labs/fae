#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_DIR="$PROJECT_DIR/tests/comprehensive/specs"
LOCK_FILE="/tmp/fae-test-comprehensive.lock"

MODEL="codex"
PHASE=""
MAX_RSS_MB="${MAX_RSS_MB:-8192}"
RSS_POLL_SECONDS="${RSS_POLL_SECONDS:-5}"
PASSTHROUGH_ARGS=()

usage() {
    cat <<'EOF'
Usage: scripts/test-comprehensive-safe.sh [OPTIONS]

Runs the comprehensive suite phase by phase, restarting Fae between phases and
stopping early if the active Fae test-server + worker RSS exceeds a threshold.

Options:
  --model NAME          Judge model wrapper for test-comprehensive.sh
  --phase NN            Run only a single phase prefix (for example 02)
  --max-rss-mb N        Abort a phase if active Fae RSS exceeds N MB
  --rss-poll-seconds N  Poll interval for RSS sampling [default: 5]
  --skip-llm            Pass through to test-comprehensive.sh
  --thinking-sweep      Pass through to test-comprehensive.sh
  --verbose             Pass through to test-comprehensive.sh
  --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --phase)
            PHASE="$2"
            shift 2
            ;;
        --max-rss-mb)
            MAX_RSS_MB="$2"
            shift 2
            ;;
        --rss-poll-seconds)
            RSS_POLL_SECONDS="$2"
            shift 2
            ;;
        --skip-llm|--thinking-sweep|--verbose)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

active_fae_pids() {
    {
        pgrep -f 'Fae.app/Contents/MacOS/Fae --test-server' || true
        pgrep -f 'Fae.app/Contents/MacOS/Fae --llm-worker' || true
    } | awk '!seen[$0]++'
}

kill_fae_processes() {
    pkill -f 'Fae.app/Contents/MacOS/Fae --llm-worker' 2>/dev/null || true
    pkill -f 'Fae.app/Contents/MacOS/Fae --test-server' 2>/dev/null || true
}

clear_stale_lock() {
    rm -f "$LOCK_FILE"
}

discover_phases() {
    local files=()
    local phases=()

    if [[ -n "$PHASE" ]]; then
        files=("$SPEC_DIR"/"${PHASE}"*.yaml "$SPEC_DIR"/"${PHASE}"*.yml)
    else
        files=("$SPEC_DIR"/*.yaml "$SPEC_DIR"/*.yml)
    fi

    for path in "${files[@]}"; do
        [[ -f "$path" ]] || continue
        local name
        name="$(basename "$path")"
        phases+=("${name%%-*}")
    done

    if [[ ${#phases[@]} -eq 0 ]]; then
        echo "No matching phases found in $SPEC_DIR" >&2
        exit 1
    fi

    printf '%s\n' "${phases[@]}" | sort -u
}

phase_total_rss_mb() {
    local total_kb=0
    local pid

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        local rss_kb
        rss_kb="$(ps -p "$pid" -o rss= 2>/dev/null | awk '{print $1}')"
        [[ -n "$rss_kb" ]] || continue
        total_kb=$((total_kb + rss_kb))
    done < <(active_fae_pids)

    echo $(((total_kb + 1023) / 1024))
}

monitor_phase_rss() {
    local phase="$1"
    local phase_pid="$2"

    while kill -0 "$phase_pid" 2>/dev/null; do
        local total_mb
        total_mb="$(phase_total_rss_mb)"

        if [[ "$total_mb" -gt 0 ]]; then
            echo "  [rss][$phase] ${total_mb} MB"
            if (( total_mb > MAX_RSS_MB )); then
                echo "  [rss][$phase] threshold exceeded (${total_mb} MB > ${MAX_RSS_MB} MB); aborting phase" >&2
                kill "$phase_pid" 2>/dev/null || true
                kill_fae_processes
                return 1
            fi
        fi

        sleep "$RSS_POLL_SECONDS"
    done
}

run_phase() {
    local phase="$1"

    echo ""
    echo "=== Safe Phase ${phase} (max RSS ${MAX_RSS_MB} MB) ==="
    clear_stale_lock
    just test-serve

    (
        cd "$PROJECT_DIR"
        bash scripts/test-comprehensive.sh --skip-build --phase "$phase" --model "$MODEL" "${PASSTHROUGH_ARGS[@]}"
    ) &
    local phase_pid=$!

    monitor_phase_rss "$phase" "$phase_pid" &
    local monitor_pid=$!

    local phase_status=0
    local monitor_status=0

    set +e
    wait "$phase_pid"
    phase_status=$?
    wait "$monitor_pid"
    monitor_status=$?
    set -e

    kill "$monitor_pid" 2>/dev/null || true

    if [[ "$monitor_status" -ne 0 ]]; then
        echo "Phase ${phase} aborted by RSS guard." >&2
        return 1
    fi

    if [[ "$phase_status" -ne 0 ]]; then
        echo "Phase ${phase} failed." >&2
        return "$phase_status"
    fi

    kill_fae_processes
}

main() {
    mapfile -t phases < <(discover_phases)

    echo "Safe comprehensive runner"
    echo "  Model: $MODEL"
    echo "  Max RSS: ${MAX_RSS_MB} MB"
    echo "  Poll interval: ${RSS_POLL_SECONDS}s"
    echo "  Phases: ${phases[*]}"

    local phase
    for phase in "${phases[@]}"; do
        run_phase "$phase"
    done

    echo ""
    echo "All requested phases completed within RSS guard."
}

trap 'kill_fae_processes' EXIT

main

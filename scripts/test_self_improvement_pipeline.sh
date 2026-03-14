#!/usr/bin/env bash
# test_self_improvement_pipeline.sh — E2E test for Fae's Loop 4 self-improvement cycle.
# Usage: bash scripts/test_self_improvement_pipeline.sh [--dry-run] [--skip-train] [--skip-fuse] [--skip-bench] [--model M] [--iters N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKIP_TRAIN=false; SKIP_FUSE=false; SKIP_BENCH=false; SKIP_CLEANUP=false; DRY_RUN=false; VERBOSE=false
MODEL=""; ITERS=10; N_CONV=10; WORKDIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-train) SKIP_TRAIN=true;; --skip-fuse) SKIP_FUSE=true;; --skip-bench) SKIP_BENCH=true;;
        --skip-cleanup) SKIP_CLEANUP=true;; --dry-run) DRY_RUN=true;; -v|--verbose) VERBOSE=true;;
        --model) MODEL="$2"; shift;; --iters) ITERS="$2"; shift;; --conversations) N_CONV="$2"; shift;;
        --workdir) WORKDIR="$2"; shift;; -h|--help) head -4 "$0"; exit 0;; *) echo "Unknown: $1">&2; exit 1;;
    esac; shift
done

G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; B='\033[0;34m'; BD='\033[1m'; RS='\033[0m'
info() { echo -e "${B}[INFO]${RS} $*"; }; pass_() { echo -e "${G}[PASS]${RS} $*"; }
warn() { echo -e "${Y}[WARN]${RS} $*"; }; fail_() { echo -e "${R}[FAIL]${RS} $*"; }
section() { echo -e "\n${BD}=== $* ===${RS}"; }

STEPS=(); RESULTS=(); TIMES=()
record() { STEPS+=("$1"); RESULTS+=("$2"); TIMES+=("$3"); }

# --- Prerequisites ---
section "Step 0: Prerequisites"
OK=true
python3 -c 'import sys; assert sys.version_info >= (3,10)' 2>/dev/null && info "Python 3.10+ OK" || { fail_ "Python 3.10+ required"; OK=false; }
python3 -c 'import mlx_lm' 2>/dev/null && info "mlx-lm OK" || { fail_ "mlx-lm not installed"; OK=false; }
[[ "$(uname -m)" == "arm64" ]] && info "Apple Silicon OK" || warn "Not arm64"
[[ -f "$SCRIPT_DIR/generate_synthetic_training_data.py" ]] && info "Synth generator OK" || { fail_ "Missing generate script"; OK=false; }
[[ -f "$SCRIPT_DIR/prepare_training_data.py" ]] && info "Data prep OK" || { fail_ "Missing prep script"; OK=false; }
[[ "$OK" == "true" ]] || { fail_ "Prerequisites failed"; exit 1; }
pass_ "All prerequisites met"

# Auto-detect model
if [[ -z "$MODEL" ]]; then
    for c in "mlx-community/Qwen3-0.6B-4bit" "mlx-community/Qwen2.5-0.5B-Instruct-4bit"; do
        CACHE="${HOME}/.cache/huggingface/hub/models--$(echo "$c" | tr '/' '--')"
        [[ -d "$CACHE" ]] && { MODEL="$c"; info "Using cached: $MODEL"; break; }
    done
    [[ -z "$MODEL" ]] && { MODEL="mlx-community/Qwen3-0.6B-4bit"; info "Will download: $MODEL (~400MB)"; }
fi

[[ -z "$WORKDIR" ]] && WORKDIR=$(mktemp -d /tmp/fae-pipeline-XXXX)
mkdir -p "$WORKDIR"/{data,training,adapter,fused,bench}
info "Workdir: $WORKDIR | Model: $MODEL"
cleanup() { [[ "$SKIP_CLEANUP" == "true" ]] && info "Keeping: $WORKDIR" || rm -rf "$WORKDIR"; }
trap cleanup EXIT

if [[ "$DRY_RUN" == "true" ]]; then
    section "DRY RUN"
    echo "  1. python3 generate_synthetic_training_data.py --count $N_CONV --with-dpo"
    echo "  2. python3 prepare_training_data.py"
    echo "  3. python3 -m mlx_lm.lora --model $MODEL --iters $ITERS"
    echo "  4. python3 -m mlx_lm.fuse"
    echo "  5. Benchmark (5 prompts, base vs fused)"
    SKIP_CLEANUP=true; exit 0
fi

# --- Step 1: Generate + prepare data ---
section "Step 1: Generate Training Data"
T0=$(date +%s)
python3 "$SCRIPT_DIR/generate_synthetic_training_data.py" --output "$WORKDIR/data/conversations.jsonl" --count "$N_CONV" --with-dpo --seed 42
python3 "$SCRIPT_DIR/prepare_training_data.py" --input "$WORKDIR/data/conversations.jsonl" --outdir "$WORKDIR/training"
SFT=$(wc -l < "$WORKDIR/training/sft_train.jsonl" | tr -d ' ')
DPO=$(wc -l < "$WORKDIR/training/dpo_train.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
cp "$WORKDIR/training/sft_train.jsonl" "$WORKDIR/training/train.jsonl"
T1=$(date +%s)
(( SFT > 0 )) && { pass_ "$SFT SFT + $DPO DPO examples ($((T1-T0))s)"; record "Data" "PASS" "$((T1-T0))s"; } || { fail_ "No SFT data"; record "Data" "FAIL" "0s"; exit 1; }

# --- Step 2: LoRA Training ---
section "Step 2: LoRA Training"
T0=$(date +%s)
if [[ "$SKIP_TRAIN" == "true" ]]; then warn "Skipped"; record "Training" "SKIP" "0s"
else
    set +e
    python3 -m mlx_lm.lora --model "$MODEL" --train --data "$WORKDIR/training" \
        --iters "$ITERS" --batch-size 1 --lora-layers 4 --adapter-path "$WORKDIR/adapter" --lr 2e-4 2>&1 | tee "$WORKDIR/train.log"
    RC=$?; set -e; T1=$(date +%s)
    if [[ $RC -eq 0 ]] && [[ -d "$WORKDIR/adapter" ]]; then
        SZ=$(du -sh "$WORKDIR/adapter" | cut -f1)
        pass_ "Adapter: $SZ ($((T1-T0))s)"; record "Training" "PASS" "$((T1-T0))s"
    else fail_ "Training failed (exit $RC)"; record "Training" "FAIL" "$((T1-T0))s"; fi
fi

# --- Step 3: Fusion ---
section "Step 3: Model Fusion"
T0=$(date +%s)
if [[ "$SKIP_FUSE" == "true" ]] || [[ "$SKIP_TRAIN" == "true" ]]; then warn "Skipped"; record "Fusion" "SKIP" "0s"
else
    set +e; python3 -m mlx_lm.fuse --model "$MODEL" --adapter-path "$WORKDIR/adapter" --save-path "$WORKDIR/fused" 2>&1; RC=$?; set -e; T1=$(date +%s)
    if [[ $RC -eq 0 ]] && [[ -d "$WORKDIR/fused" ]]; then
        SZ=$(du -sh "$WORKDIR/fused" | cut -f1)
        pass_ "Fused: $SZ ($((T1-T0))s)"; record "Fusion" "PASS" "$((T1-T0))s"
    else fail_ "Fusion failed"; record "Fusion" "FAIL" "$((T1-T0))s"; fi
fi

# --- Step 4: Benchmark ---
section "Step 4: Benchmark"
T0=$(date +%s)
if [[ "$SKIP_BENCH" == "true" ]] || [[ ! -d "$WORKDIR/fused" ]]; then warn "Skipped"; record "Benchmark" "SKIP" "0s"
else
    python3 -c "
import json, time, sys
try:
    from mlx_lm import load, generate
except ImportError:
    print(json.dumps({'error':'mlx_lm not available'})); sys.exit(1)

prompts = ['Who are you?', 'Capital of Scotland?', 'Explain recursion briefly.', 'Remember my cat is Pixel.', 'Search for macOS news.']
def score(p, r):
    s = 40 + min(20, len(r)/20)
    if 'fae' in r.lower() or 'local' in r.lower(): s += 15
    if 'edinburgh' in r.lower(): s += 20
    if 'recursion' in r.lower() or 'calls itself' in r.lower(): s += 15
    if 'remember' in r.lower() or 'pixel' in r.lower(): s += 15
    if 'search' in r.lower() or 'tool_call' in r.lower(): s += 15
    return min(100, s)

def bench(model_path):
    m, t = load(model_path)
    scores = []
    for p in prompts:
        msgs = [{'role':'system','content':'You are Fae, a helpful local AI.'},{'role':'user','content':p}]
        fmt = t.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
        r = generate(m, t, prompt=fmt, max_tokens=150, verbose=False)
        scores.append(score(p, r))
    return sum(scores)/len(scores)

base = bench('$MODEL')
fused = bench('$WORKDIR/fused')
delta = fused - base
regression = fused < base * 0.9
print(json.dumps({'base': round(base,1), 'fused': round(fused,1), 'delta': round(delta,1), 'regression': regression}))
" > "$WORKDIR/bench/result.json" 2>"$WORKDIR/bench/stderr.log"

    T1=$(date +%s)
    if [[ -f "$WORKDIR/bench/result.json" ]]; then
        BS=$(python3 -c "import json; print(json.load(open('$WORKDIR/bench/result.json'))['base'])")
        FS=$(python3 -c "import json; print(json.load(open('$WORKDIR/bench/result.json'))['fused'])")
        DL=$(python3 -c "import json; print(json.load(open('$WORKDIR/bench/result.json'))['delta'])")
        RG=$(python3 -c "import json; print(json.load(open('$WORKDIR/bench/result.json'))['regression'])")
        info "Base: $BS | Fused: $FS | Delta: $DL"
        if [[ "$RG" == "True" ]]; then fail_ "REGRESSION"; record "Benchmark" "FAIL" "$((T1-T0))s"
        else pass_ "No regression ($((T1-T0))s)"; record "Benchmark" "PASS" "$((T1-T0))s"; fi
    else
        warn "Benchmark produced no output"; cat "$WORKDIR/bench/stderr.log" | tail -10
        record "Benchmark" "WARN" "$((T1-T0))s"
    fi
fi

# --- Summary ---
section "Summary"
ALL_PASS=true
printf "\n  ${BD}%-16s %-8s %s${RS}\n" "Step" "Result" "Time"
for i in "${!STEPS[@]}"; do
    case "${RESULTS[$i]}" in PASS) C="$G";; FAIL) C="$R"; ALL_PASS=false;; *) C="$Y";; esac
    printf "  %-16s ${C}%-8s${RS} %s\n" "${STEPS[$i]}" "${RESULTS[$i]}" "${TIMES[$i]}"
done
echo
[[ "$ALL_PASS" == "true" ]] && { pass_ "Pipeline functional. Next: use real data, increase iters, try larger models."; exit 0; } || { fail_ "Some steps failed."; exit 1; }

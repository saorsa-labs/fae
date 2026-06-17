#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

LLVM_COV="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-cov"
PROFRAW_DIR=".build/arm64-apple-macosx/debug/codecov"
ACCUM_DIR="/tmp/fae-profraw-accum"
# Resume marker: records suites already run this measurement so interrupted
# runs can continue without re-running early suites. Cleared on a fresh run.
DONE_FILE="$ACCUM_DIR/.done_suites"

# Clean everything fresh UNLESS resuming an interrupted measurement.
if [ "${FAE_COV_RESUME:-0}" != "1" ]; then
  rm -f default.profdata
  rm -rf "$ACCUM_DIR"
fi
mkdir -p "$ACCUM_DIR"
mkdir -p "$PROFRAW_DIR"
# Ensure the done-tracking file exists (resume reads it; fresh run has it empty).
[ -f "$DONE_FILE" ] || : > "$DONE_FILE"

# Get all test suite names (IntegrationTests + HandoffTests, skip EvalTests).
# Cache the discovery result so interrupted/resumed runs skip the ~50s
# `swift test --list-tests` overhead on every invocation.
SUITE_CACHE="$ACCUM_DIR/.suite_list"
echo "==> Discovering test suites..."
if [ -s "$SUITE_CACHE" ]; then
  SUITES=$(cat "$SUITE_CACHE")
else
  SUITES=$(swift test --list-tests 2>&1 | grep -E "^(IntegrationTests|HandoffTests)\." | sed 's|/.*||' | sort -u)
  printf '%s\n' "$SUITES" > "$SUITE_CACHE"
fi
SUITE_COUNT=$(echo "$SUITES" | grep -c .)
echo "Found $SUITE_COUNT test suites"

# Known-flaky: VocabularyHarvestTests hangs under `--enable-code-coverage`
# instrumentation (an audio-decode / coverage interaction — runs fine without
# coverage). Excluded from measurement for reproducibility. Only this one suite
# is affected; the rest of the voice/audio tail runs cleanly under coverage.
# Match with OR without the `IntegrationTests.`/`HandoffTests.` prefix.
SKIP_SUITES="VocabularyHarvestTests"
skip_suite() {
  local bare
  bare="${1#*.}"  # strip leading module prefix if present
  for skip in $SKIP_SUITES; do
    [ "$1" = "$skip" ] && return 0
    [ "$bare" = "$skip" ] && return 0
  done
  return 1
}

# Run each suite individually to avoid profraw corruption when multiple
# XCTest suites share a process. Each suite gets its own clean profraw.
# On resume, skip suites already recorded in DONE_FILE.
RUN=$(wc -l < "$DONE_FILE" | tr -d ' ')
for SUITE in $SUITES; do
  if skip_suite "$SUITE"; then
    echo "==> skipping flaky suite: $SUITE"
    continue
  fi
  if grep -qxF "$SUITE" "$DONE_FILE" 2>/dev/null; then
    continue
  fi
  RUN=$((RUN + 1))
  # Remove old profraws before each run to avoid stale data
  rm -f "$PROFRAW_DIR"/*.profraw
  swift test --enable-code-coverage --filter "$SUITE" > /dev/null 2>&1 || true
  for f in "$PROFRAW_DIR"/*.profraw; do
    [ -f "$f" ] && cp "$f" "$ACCUM_DIR/run${RUN}_$(basename "$f")"
  done
  # Record completion AFTER the profraws are saved so a mid-run kill leaves
  # no half-recorded suite (the next resume re-runs it cleanly).
  echo "$SUITE" >> "$DONE_FILE"
done

echo "==> Done running $SUITE_COUNT suites"

# Merge ALL accumulated profraws
PROFRAW_COUNT=$(ls "$ACCUM_DIR"/*.profraw 2>/dev/null | wc -l | tr -d ' ')
echo "==> Merging $PROFRAW_COUNT profraw files..."
llvm-profdata merge -o default.profdata "$ACCUM_DIR"/*.profraw

# Extract coverage using JSON export (more accurate line counting)
echo "==> Extracting coverage..."
$LLVM_COV export -format=text \
  .build/debug/FaePackageTests.xctest/Contents/MacOS/FaePackageTests \
  -instr-profile=default.profdata > /tmp/fae_coverage.json 2>/dev/null

python3 << 'PYEOF'
import json, sys
with open('/tmp/fae_coverage.json') as f:
    data = json.load(f)
files = data['data'][0].get('files', [])

fae_files = [f for f in files if '/Sources/Fae/' in f.get('filename', '') and '.build' not in f.get('filename', '')]
total_lines = 0
exec_lines = 0
zero_cov = 0
covered_files = 0
for f in fae_files:
    s = f.get('summary', {}).get('lines', {})
    count = s.get('count', 0)
    cov = s.get('covered', 0)
    total_lines += count
    exec_lines += cov
    if count > 0 and cov == 0:
        zero_cov += 1
    elif cov > 0:
        covered_files += 1

pct = (exec_lines / total_lines * 100) if total_lines > 0 else 0
print(f'METRIC coverage_pct={pct:.1f}')
print(f'METRIC total_lines={total_lines}')
print(f'METRIC exec_lines={exec_lines}')
print(f'METRIC files_covered={covered_files}')
print(f'METRIC zero_cov_files={zero_cov}')
PYEOF

echo "METRIC test_count=0"

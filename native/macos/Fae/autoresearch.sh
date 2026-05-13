#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

LLVM_COV="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-cov"
PROFRAW_DIR=".build/arm64-apple-macosx/debug/codecov"
ACCUM_DIR="/tmp/fae-profraw-accum"

# Clean everything fresh
rm -f default.profdata
rm -rf "$ACCUM_DIR"
mkdir -p "$ACCUM_DIR"
mkdir -p "$PROFRAW_DIR"

# Get all test suite names (IntegrationTests + HandoffTests, skip EvalTests)
echo "==> Discovering test suites..."
SUITES=$(swift test --list-tests 2>&1 | grep -E "^(IntegrationTests|HandoffTests)\." | sed 's|/.*||' | sort -u)
SUITE_COUNT=$(echo "$SUITES" | wc -l | tr -d ' ')
echo "Found $SUITE_COUNT test suites"

# Run each suite individually to avoid profraw corruption when multiple
# XCTest suites share a process. Each suite gets its own clean profraw.
RUN=0
for SUITE in $SUITES; do
  RUN=$((RUN + 1))
  # Remove old profraws before each run to avoid stale data
  rm -f "$PROFRAW_DIR"/*.profraw
  swift test --enable-code-coverage --filter "$SUITE" > /dev/null 2>&1 || true
  for f in "$PROFRAW_DIR"/*.profraw; do
    [ -f "$f" ] && cp "$f" "$ACCUM_DIR/run${RUN}_$(basename "$f")"
  done
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

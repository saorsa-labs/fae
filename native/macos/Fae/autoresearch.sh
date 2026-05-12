#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

LLVM_COV="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-cov"

# Fast pre-check: does it compile? (skip if recent)
if [ ! -f .build/debug/FaePackageTests.xctest/Contents/MacOS/FaePackageTests ]; then
  echo "==> swift build..."
  swift build
fi

# Run tests with coverage
echo "==> Running tests with coverage..."
rm -f default.profraw default.profdata
swift test --skip EvalTests --enable-code-coverage > /tmp/fae_test_output.txt 2>&1 || true
# swift test returns non-zero on failure, but we already captured with || true
# Just check the last meaningful line
LAST_LINE=$(tail -1 /tmp/fae_test_output.txt)
case "$LAST_LINE" in
  *"passed after"*) ;; # OK
  *) echo "Warning: unexpected test output end: $LAST_LINE" ;;
esac

# Merge profraw files
PROFRAW_DIR=".build/arm64-apple-macosx/debug/codecov"
if [ ! -d "$PROFRAW_DIR" ]; then
  echo "ERROR: No coverage data at $PROFRAW_DIR"
  exit 1
fi

llvm-profdata merge -o default.profdata "$PROFRAW_DIR"/*.profraw

# Extract coverage
$LLVM_COV export -format=text \
  .build/debug/FaePackageTests.xctest/Contents/MacOS/FaePackageTests \
  -instr-profile=default.profdata > /tmp/fae_coverage.json 2>/dev/null

# Parse coverage for Sources/Fae only
python3 << 'PYEOF'
import json
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
    covered = s.get('covered', 0)
    total_lines += count
    exec_lines += covered
    if count > 0 and covered == 0:
        zero_cov += 1
    elif covered > 0:
        covered_files += 1

pct = (exec_lines / total_lines * 100) if total_lines > 0 else 0
print(f'METRIC coverage_pct={pct:.1f}')
print(f'METRIC total_lines={total_lines}')
print(f'METRIC exec_lines={exec_lines}')
print(f'METRIC files_covered={covered_files}')
print(f'METRIC zero_cov_files={zero_cov}')
print(f'METRIC fae_file_count={len(fae_files)}')
PYEOF

# Count tests
TEST_COUNT=$(grep -c "✔ Test" /tmp/fae_test_output.txt 2>/dev/null || echo "0")
echo "METRIC test_count=${TEST_COUNT}"

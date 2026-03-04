#!/usr/bin/env bash
# Fae Comprehensive Test Suite Runner
#
# Executes YAML test specs against a running Fae test server, scores results
# deterministically or via LLM agent, and produces JSON reports.
#
# Usage:
#   ./scripts/test-comprehensive.sh                    # Full run with Claude scoring
#   ./scripts/test-comprehensive.sh --model codex      # Use Codex for LLM scoring
#   ./scripts/test-comprehensive.sh --skip-llm         # Deterministic only, no LLM
#   ./scripts/test-comprehensive.sh --phase 02         # Single phase
#   ./scripts/test-comprehensive.sh --verbose          # Show curl responses
#
# Prerequisites: curl, python3, jq, PyYAML (pip3 install pyyaml)
# For LLM scoring: claude CLI (pip install claude-code)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_DIR="$PROJECT_DIR/tests/comprehensive/specs"
REPORT_DIR="$PROJECT_DIR/tests/comprehensive/reports"
AGENT_PROMPT="$PROJECT_DIR/tests/comprehensive/agent-prompt.md"
FAE_URL="http://127.0.0.1:7433"

# Defaults
MODEL="claude"
PHASE=""
SKIP_LLM=false
VERBOSE=false
THINKING_SWEEP=false
TIMEOUT_CONNECT=5
TIMEOUT_REQUEST=10

# Counters
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
ERRORS=0

# Results accumulator and report file — initialized after arg parsing
RESULTS_FILE=""
REPORT_FILE=""

# ── Color output ────────────────────────────────────────────────────────────

USE_COLOR=false
if [ -t 1 ]; then USE_COLOR=true; fi

green()  { if $USE_COLOR; then printf "\033[32m%s\033[0m\n" "$*"; else echo "$*"; fi; }
red()    { if $USE_COLOR; then printf "\033[31m%s\033[0m\n" "$*"; else echo "$*"; fi; }
yellow() { if $USE_COLOR; then printf "\033[33m%s\033[0m\n" "$*"; else echo "$*"; fi; }
bold()   { if $USE_COLOR; then printf "\033[1m%s\033[0m\n" "$*"; else echo "$*"; fi; }
dim()    { if $USE_COLOR; then printf "\033[2m%s\033[0m\n" "$*"; else echo "$*"; fi; }

# ── Argument parsing ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)      MODEL="$2"; shift 2 ;;
        --phase)      PHASE="$2"; shift 2 ;;
        --skip-build) shift ;;  # No-op: build handled by justfile, kept for compat
        --skip-llm)   SKIP_LLM=true; shift ;;
        --thinking-sweep) THINKING_SWEEP=true; shift ;;
        --verbose)    VERBOSE=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --model NAME    LLM CLI for scoring [default: claude]"
            echo "                  Any CLI that supports -p (pipe: stdin → stdout)"
            echo "  --phase NN      Run only phase NN (e.g., 02)"
            echo "  --skip-build    No-op (build handled by justfile recipes)"
            echo "  --skip-llm      Skip LLM-scored tests entirely"
            echo "  --thinking-sweep Run each phase twice: thinking OFF then ON"
            echo "  --verbose        Show HTTP responses"
            echo "  --help           Show this help"
            echo ""
            echo "Models — any CLI that accepts 'echo prompt | <cmd> -p':"
            echo "  claude       Claude Code CLI (default)"
            echo "  codex        OpenAI Codex CLI"
            echo "  pi           Inflection Pi CLI"
            echo "  kimi         Moonshot Kimi CLI"
            echo "  gemini       Google Gemini CLI"
            echo "  <anything>   Any command with -p flag (stdin→stdout)"
            echo ""
            echo "Examples:"
            echo "  just test-comprehensive model=claude"
            echo "  just test-comprehensive-quick model=codex"
            echo "  just test-comprehensive-quick model=pi"
            echo "  just test-comprehensive-quick model=kimi"
            exit 0
            ;;
        *) red "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Post-parse initialization ──────────────────────────────────────────────

RESULTS_FILE=$(mktemp /tmp/fae-test-results-XXXXXXXXXX)
echo "[]" > "$RESULTS_FILE"
RUN_TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
REPORT_FILE="$REPORT_DIR/report-${RUN_TIMESTAMP}.json"

# ── Prerequisites ───────────────────────────────────────────────────────────

check_prereqs() {
    local missing=()
    command -v curl    >/dev/null 2>&1 || missing+=("curl")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v jq      >/dev/null 2>&1 || missing+=("jq")

    if [ ${#missing[@]} -gt 0 ]; then
        red "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Check PyYAML
    if ! python3 -c "import yaml" 2>/dev/null; then
        red "PyYAML not installed. Run: pip3 install pyyaml"
        exit 1
    fi

    # Check LLM CLI is available
    if ! $SKIP_LLM; then
        if ! command -v "$MODEL" >/dev/null 2>&1; then
            yellow "Warning: '$MODEL' CLI not found in PATH. LLM-scored tests will be skipped."
            yellow "Install it or use --skip-llm for deterministic-only mode."
            SKIP_LLM=true
        fi
    fi
}

# ── HTTP helpers ────────────────────────────────────────────────────────────

# GET endpoint, return body. Sets HTTP_STATUS global.
fae_get() {
    local path="$1"
    local tmpfile
    tmpfile=$(mktemp /tmp/fae-http-XXXXXX)
    HTTP_STATUS=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        --connect-timeout "$TIMEOUT_CONNECT" \
        --max-time "$TIMEOUT_REQUEST" \
        "${FAE_URL}${path}" 2>/dev/null || echo "000")
    HTTP_BODY=$(cat "$tmpfile" 2>/dev/null || echo "")
    rm -f "$tmpfile"
    if $VERBOSE; then dim "  GET $path -> $HTTP_STATUS" >&2; fi
}

# POST endpoint with JSON body. Sets HTTP_STATUS and HTTP_BODY globals.
fae_post() {
    local path="$1"
    local _empty_obj='{}'
    local body="${2:-$_empty_obj}"
    local tmpfile
    tmpfile=$(mktemp /tmp/fae-http-XXXXXX)
    HTTP_STATUS=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        --connect-timeout "$TIMEOUT_CONNECT" \
        --max-time "$TIMEOUT_REQUEST" \
        -X POST "${FAE_URL}${path}" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null || echo "000")
    HTTP_BODY=$(cat "$tmpfile" 2>/dev/null || echo "")
    rm -f "$tmpfile"
    if $VERBOSE; then dim "  POST $path -> $HTTP_STATUS" >&2; fi
}

# POST /reset to clear state between tests.
fae_reset() {
    fae_post "/reset" "{}"
    if [ "$HTTP_STATUS" != "200" ]; then
        yellow "  Warning: /reset returned $HTTP_STATUS"
    fi
}

# POST /inject with text. Returns turn_id via INJECT_TURN_ID global.
fae_inject() {
    local text="$1"
    local escaped
    escaped=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text")
    fae_post "/inject" "{\"text\":${escaped}}"
    INJECT_TURN_ID=""
    if [ "$HTTP_STATUS" = "200" ]; then
        INJECT_TURN_ID=$(echo "$HTTP_BODY" | jq -r '.turn_id // empty' 2>/dev/null || echo "")
    fi
}

# Poll /conversation until isGenerating==false AND isSpeaking==false, max N seconds.
fae_wait_generation() {
    local max_wait="${1:-60}"
    local elapsed=0

    # Phase 1: Wait for generation to START (isGenerating=true).
    # Inject is async — pipeline takes 1-5s to begin generating.
    local started=false
    while [ "$elapsed" -lt "$max_wait" ]; do
        fae_get "/conversation"
        local generating
        generating=$(echo "$HTTP_BODY" | jq -r '.isGenerating' 2>/dev/null || echo "false")
        if [ "$generating" = "true" ]; then
            started=true
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if ! $started; then
        # Generation never started — check if there's a response anyway
        # (very fast response that completed before first poll)
        local count
        count=$(echo "$HTTP_BODY" | jq -r '.count // 0' 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            return 0  # Response exists
        fi
        return 1  # Timed out waiting for generation to start
    fi

    # Phase 2: Wait for generation to FINISH (isGenerating=false).
    while [ "$elapsed" -lt "$max_wait" ]; do
        fae_get "/conversation"
        local generating
        generating=$(echo "$HTTP_BODY" | jq -r '.isGenerating' 2>/dev/null || echo "true")
        if [ "$generating" = "false" ]; then
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ "$elapsed" -ge "$max_wait" ]; then
        return 1  # Timed out waiting for generation to finish
    fi

    # Phase 3: Wait for TTS speech to FINISH (isSpeaking=false).
    # LLM generation ends before TTS playback — without this, next test
    # injects while Fae is still speaking, causing echo/interruption.
    local speech_wait=0
    local speech_max=30
    while [ "$speech_wait" -lt "$speech_max" ]; do
        fae_get "/conversation"
        local speaking
        speaking=$(echo "$HTTP_BODY" | jq -r '.isSpeaking' 2>/dev/null || echo "false")
        if [ "$speaking" = "false" ]; then
            return 0
        fi
        sleep 1
        speech_wait=$((speech_wait + 1))
    done
    # Speaking timeout — proceed anyway (TTS may be slow)
    return 0
}

# GET /events?since=N, return JSON body.
fae_get_events() {
    local since="${1:-0}"
    fae_get "/events?since=${since}"
    echo "$HTTP_BODY"
}

# POST /config with key/value.
fae_set_config() {
    local key="$1"
    local value="$2"
    local escaped_val
    escaped_val=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$value")
    fae_post "/config" "{\"key\":\"${key}\",\"value\":${escaped_val}}"
}

# Get event baseline (current total count).
fae_event_baseline() {
    fae_get "/events?since=0"
    echo "$HTTP_BODY" | jq -r '.total // 0' 2>/dev/null || echo "0"
}

# Pick a random phrasing from a JSON array string.
random_phrasing() {
    local phrasings_json="$1"
    python3 -c "
import json, random, sys
p = json.loads(sys.argv[1])
print(random.choice(p) if p else '')
" "$phrasings_json"
}

# ── YAML parsing ────────────────────────────────────────────────────────────

parse_spec_file() {
    local yaml_file="$1"
    python3 -c "
import json, sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
" "$yaml_file"
}

# ── Result recording ────────────────────────────────────────────────────────

# Append a test result JSON object to the results file.
record_result() {
    local result_json="$1"
    # Guard: skip if empty or invalid JSON
    if [ -z "$result_json" ]; then
        yellow "  Warning: empty result, skipping record"
        return
    fi
    python3 -c "
import json, sys
results_path = sys.argv[1]
raw = sys.argv[2]
try:
    new_result = json.loads(raw)
except (json.JSONDecodeError, TypeError):
    sys.stderr.write(f'Warning: invalid result JSON, skipping: {raw[:100]}\n')
    sys.exit(0)
with open(results_path) as f:
    results = json.load(f)
results.append(new_result)
with open(results_path, 'w') as f:
    json.dump(results, f, indent=2)
" "$RESULTS_FILE" "$result_json"
}

# ── Criterion evaluation ───────────────────────────────────────────────────

# Evaluate criteria for a deterministic test. Expects globals:
#   EVENTS_JSON — events collected after the test
#   CONV_JSON   — conversation state after the test
#   LAST_HTTP_STATUS — status code of the last HTTP step (if relevant)
evaluate_criteria() {
    local criteria_json="$1"
    CRITERIA_JSON="$criteria_json" python3 << 'PYEOF'
import json, sys, re, os, subprocess

criteria_raw = os.environ.get("CRITERIA_JSON", "[]")
try:
    criteria = json.loads(criteria_raw)
except (json.JSONDecodeError, TypeError):
    criteria = []

if not criteria:
    print("[]")
    sys.exit(0)

events_json = os.environ.get("EVENTS_JSON", "[]")
conv_json = os.environ.get("CONV_JSON", "{}")
last_status = os.environ.get("LAST_HTTP_STATUS", "200")
last_body = os.environ.get("LAST_HTTP_BODY", "{}")

try:
    events = json.loads(events_json)
    if isinstance(events, dict):
        events = events.get("events", [])
except (json.JSONDecodeError, TypeError):
    events = []

try:
    conv = json.loads(conv_json)
except (json.JSONDecodeError, TypeError):
    conv = {}

try:
    body = json.loads(last_body)
except (json.JSONDecodeError, TypeError):
    body = {}

messages = conv.get("messages", [])
assistant_msgs = [m for m in messages if m.get("role") == "assistant"]
last_assistant = assistant_msgs[-1].get("content", "") if assistant_msgs else ""
last_role = messages[-1].get("role", "") if messages else ""

# Check for permission-related failures in events (used for skip detection)
perm_keywords = ["permission", "not granted", "denied", "requires access"]
perm_events = [e for e in events if any(kw in str(e.get("text", "")).lower() for kw in perm_keywords)]


def eval_atom(expr):
    """Evaluate a single atomic expression. Returns (bool, evidence_str)."""
    expr = expr.strip()

    # tagged_events — handled at runner level, placeholder here
    if "tagged_events" in expr:
        return (False, "Tagged event check — evaluated by runner")

    # llm_judge — deferred to LLM scorer
    if "llm_judge" in expr:
        return (True, "LLM judge — requires LLM scoring (placeholder pass)")

    # status_code == NNN
    m = re.match(r'status_code\s*==\s*(\d+)$', expr)
    if m:
        expected = m.group(1)
        ok = last_status == expected
        return (ok, f"HTTP status: {last_status} (expected {expected})")

    # last_message_role == 'X' or last_message_role != 'X'
    m = re.match(r"last_message_role\s*(!?=)=?\s*'([^']+)'$", expr)
    if m:
        op_raw, expected = m.group(1), m.group(2)
        negate = "!" in op_raw
        if negate:
            ok = last_role != expected
        else:
            ok = last_role == expected
        return (ok, f"last_role={last_role!r} ({op_raw}= {expected!r})")

    # body.FIELD is list and len(body.FIELD) > N (compound with len)
    m = re.match(r"body\.(\w+)\s+is\s+list\s+and\s+len\(body\.\w+\)\s*>\s*(\d+)$", expr)
    if m:
        field, threshold = m.group(1), int(m.group(2))
        actual = body.get(field)
        ok = isinstance(actual, list) and len(actual) > threshold
        return (ok, f"body.{field} is list={isinstance(actual, list)}, len={len(actual) if isinstance(actual, list) else 'N/A'} (> {threshold})")

    # body.FIELD is list
    m = re.match(r'body\.(\w+)\s+is\s+list$', expr)
    if m:
        field = m.group(1)
        actual = body.get(field)
        return (isinstance(actual, list), f"body.{field} type = {type(actual).__name__}")

    # body.FIELD is int
    m = re.match(r'body\.(\w+)\s+is\s+int$', expr)
    if m:
        field = m.group(1)
        actual = body.get(field)
        return (isinstance(actual, int), f"body.{field} type = {type(actual).__name__}, value = {actual!r}")

    # body.FIELD in [...]
    m = re.match(r"body\.(\w+)\s+in\s+\[(.+)\]$", expr)
    if m:
        field = m.group(1)
        vals = [v.strip().strip("'\"") for v in m.group(2).split(",")]
        actual = str(body.get(field, ""))
        return (actual in vals, f"body.{field} = {actual!r}, expected one of {vals}")

    # body.FIELD != null
    m = re.match(r'body\.(\w+)\s*!=\s*null$', expr)
    if m:
        field = m.group(1)
        actual = body.get(field)
        return (actual is not None, f"body.{field} = {actual!r}")

    # body.FIELD == VALUE
    m = re.match(r'body\.(\w+)\s*==\s*(.+)$', expr)
    if m:
        field = m.group(1)
        expected = m.group(2).strip().strip("'\"")
        actual = body.get(field)
        if actual is None:
            actual_str = str(conv.get(field, ""))
        else:
            actual_str = str(actual)
        if expected.lower() == "true":
            ok = actual_str.lower() in ("true", "1")
        elif expected.lower() == "false":
            ok = actual_str.lower() in ("false", "0")
        elif expected == "null":
            ok = actual is None
        else:
            ok = actual_str == expected
        return (ok, f"body.{field} = {actual_str!r} (expected {expected!r})")

    # assistant_response_length > N or < N
    m = re.match(r'assistant_response_length\s*(>|<|>=|<=|==)\s*(\d+)$', expr)
    if m:
        op, threshold = m.group(1), int(m.group(2))
        length = len(last_assistant)
        if op == ">": ok = length > threshold
        elif op == "<": ok = length < threshold
        elif op == ">=": ok = length >= threshold
        elif op == "<=": ok = length <= threshold
        elif op == "==": ok = length == threshold
        else: ok = False
        return (ok, f"Response length: {length} chars ({op} {threshold})")

    # assistant_response_contains('text')
    m = re.match(r"assistant_response_contains\('([^']+)'\)$", expr)
    if m:
        needle = m.group(1)
        found = needle.lower() in last_assistant.lower()
        if found:
            idx = last_assistant.lower().index(needle.lower())
            snippet = last_assistant[max(0,idx-20):idx+len(needle)+20]
            return (True, f"Found '{needle}': '...{snippet}...'")
        else:
            return (False, f"'{needle}' not found ({len(last_assistant)} chars)")

    # assistant_response_contains_any([...])
    m = re.match(r"assistant_response_contains_any\(\[(.+)\]\)$", expr)
    if m:
        needles = [n.strip().strip("'\"") for n in m.group(1).split(",")]
        matched = [n for n in needles if n.lower() in last_assistant.lower()]
        return (len(matched) > 0, f"Matched: {matched}" if matched else f"None of {needles} found")

    # events_contain_kind('KIND', 'TOOL') — event with kind==KIND and text contains TOOL
    m = re.match(r"events_contain_kind\('(\w+)',\s*'([^']+)'\)$", expr)
    if m:
        kind, tool = m.group(1), m.group(2)
        # Match: kind field starts with the given kind (e.g., "Tool→" matches "Tool"),
        # and text contains the tool name
        found = any(
            e.get("kind", "").startswith(kind) and tool.lower() in str(e.get("text", "")).lower()
            for e in events
        )
        matching = [e for e in events if e.get("kind", "").startswith(kind) and tool.lower() in str(e.get("text", "")).lower()]
        if found:
            return (True, f"Found {kind} event with '{tool}': {matching[0].get('text', '')[:80]}")
        else:
            kind_events = [e.get("kind", "") for e in events]
            return (False, f"No {kind} event with '{tool}'. Event kinds: {set(kind_events)}")

    # events_contain_kind('KIND') — event with kind matching KIND (no tool filter)
    m = re.match(r"events_contain_kind\('(\w+)'\)$", expr)
    if m:
        kind = m.group(1)
        found = any(e.get("kind", "").startswith(kind) for e in events)
        if found:
            matching = [e for e in events if e.get("kind", "").startswith(kind)]
            return (True, f"Found {len(matching)} {kind} event(s)")
        else:
            return (False, f"No {kind} events in {len(events)} total events")

    # events_contain_any_kind(['KIND1', 'KIND2']) — any event kind matches any in list
    m = re.match(r"events_contain_any_kind\(\[(.+)\]\)$", expr)
    if m:
        kinds = [k.strip().strip("'\"") for k in m.group(1).split(",")]
        found = any(
            any(e.get("kind", "").startswith(k) for k in kinds)
            for e in events
        )
        if found:
            matched_kinds = set()
            for e in events:
                for k in kinds:
                    if e.get("kind", "").startswith(k):
                        matched_kinds.add(k)
            return (True, f"Found event kinds: {matched_kinds}")
        else:
            return (False, f"No events with kinds in {kinds}")

    # events_contain_any(['word1', 'word2']) — any event text contains any word
    m = re.match(r"events_contain_any\(\[(.+)\]\)$", expr)
    if m:
        words = [w.strip().strip("'\"") for w in m.group(1).split(",")]
        found_words = set()
        for e in events:
            text = str(e.get("text", "")).lower()
            for w in words:
                if w.lower() in text:
                    found_words.add(w)
        ok = len(found_words) > 0
        return (ok, f"Found words: {found_words}" if ok else f"None of {words} in events")

    # file_exists('/path')
    m = re.match(r"file_exists\('([^']+)'\)$", expr)
    if m:
        path = m.group(1)
        exists = os.path.exists(path)
        return (exists, f"File {'exists' if exists else 'not found'}: {path}")

    # file_contains('/path', 'text')
    m = re.match(r"file_contains\('([^']+)',\s*'([^']+)'\)$", expr)
    if m:
        path, needle = m.group(1), m.group(2)
        try:
            content = open(path).read()
            found = needle in content
            return (found, f"'{needle}' {'found' if found else 'not found'} in {path}")
        except Exception as e:
            return (False, f"Cannot read {path}: {e}")

    return (None, f"Unknown atom: {expr}")


def eval_expr(expr):
    """Evaluate an expression with not/and/or support. Returns (bool, evidence_str)."""
    expr = expr.strip()

    # Handle ' and ' splits (respecting parentheses)
    # Simple split — works for our flat expressions
    if " and " in expr:
        parts = re.split(r'\s+and\s+', expr)
        results_list = [eval_expr(p) for p in parts]
        all_ok = all(r[0] for r in results_list if r[0] is not None)
        evidence = " AND ".join(r[1] for r in results_list)
        return (all_ok, evidence)

    if " or " in expr:
        parts = re.split(r'\s+or\s+', expr)
        results_list = [eval_expr(p) for p in parts]
        any_ok = any(r[0] for r in results_list if r[0] is not None)
        evidence = " OR ".join(r[1] for r in results_list)
        return (any_ok, evidence)

    # Handle 'not' prefix
    if expr.startswith("not "):
        inner = expr[4:]
        ok, ev = eval_expr(inner)
        if ok is None:
            return (None, ev)
        return (not ok, f"NOT({ev})")

    return eval_atom(expr)


results = []

for crit in criteria:
    name = crit.get("name", "")
    check = crit.get("check", "")
    score = 0.0
    evidence = ""
    skipped = False
    skip_reason = None

    try:
        ok, evidence = eval_expr(check)
        if ok is None:
            # Unknown expression
            score = 0.0
        elif "tagged_events" in check:
            score = 0.0  # Will be overridden by runner
        elif "llm_judge" in check:
            score = 0.5  # Placeholder — real score from LLM
        else:
            score = 1.0 if ok else 0.0

        # Permission skip detection for tool-related checks
        if score == 0.0 and perm_events and "events_contain_kind" in check:
            skipped = True
            skip_reason = f"Permission issue: {perm_events[0].get('text', '')[:100]}"

    except Exception as e:
        evidence = f"Evaluation error: {str(e)}"
        score = 0.0

    result = {"criterion": name, "check": check, "score": score, "evidence": evidence}
    if skipped:
        result["skipped"] = True
        result["skip_reason"] = skip_reason
    results.append(result)

print(json.dumps(results))
PYEOF
}

# ── Step execution ──────────────────────────────────────────────────────────

# Execute a single step from a test spec. Updates globals as needed.
execute_step() {
    local step_json="$1"
    local action
    action=$(echo "$step_json" | jq -r '.action // empty')

    # Skip steps with no action (null, empty, or missing)
    if [ -z "$action" ] || [ "$action" = "null" ]; then
        return
    fi

    case "$action" in
        http_get)
            local url
            url=$(echo "$step_json" | jq -r '.url')
            fae_get "$url"
            LAST_HTTP_STATUS="$HTTP_STATUS"
            LAST_HTTP_BODY="$HTTP_BODY"
            ;;
        http_post)
            local url body
            url=$(echo "$step_json" | jq -r '.url')
            body=$(echo "$step_json" | jq -c '.body // {}')
            fae_post "$url" "$body"
            LAST_HTTP_STATUS="$HTTP_STATUS"
            LAST_HTTP_BODY="$HTTP_BODY"
            # Reset event baseline on /reset (clears debug console)
            if [ "$url" = "/reset" ]; then
                EVENT_BASELINE=0
            fi
            ;;
        inject)
            local text phrasing_mode
            phrasing_mode=$(echo "$step_json" | jq -r '.phrasing // empty')
            text=$(echo "$step_json" | jq -r '.text // empty')
            if [ "$phrasing_mode" = "random" ] && [ -n "$TEST_PHRASINGS" ] && [ "$TEST_PHRASINGS" != "[]" ]; then
                text=$(random_phrasing "$TEST_PHRASINGS")
            fi
            if [ -z "$text" ]; then
                yellow "  Warning: inject step has no text"
                return
            fi
            PHRASING_USED="$text"
            fae_inject "$text"
            ;;
        wait_generation)
            local max_wait
            max_wait=$(echo "$step_json" | jq -r '.max_wait_s // 60')
            if ! fae_wait_generation "$max_wait"; then
                GENERATION_TIMED_OUT=true
                yellow "  Warning: generation timed out after ${max_wait}s"
            fi
            ;;
        collect_events)
            local tag
            tag=$(echo "$step_json" | jq -r '.tag // empty')
            EVENTS_JSON=$(fae_get_events "$EVENT_BASELINE")
            if [ -n "$tag" ]; then
                # Store tagged events for multi-phase tests.
                # Use printf -v (not eval) — JSON may contain spaces in string values
                # which would break unquoted eval assignment.
                printf -v "TAGGED_EVENTS_${tag}" '%s' "$EVENTS_JSON"
                # Reset baseline for next collection
                EVENT_BASELINE=$(echo "$EVENTS_JSON" | jq -r '.total // 0' 2>/dev/null || echo "0")
                # Debug trace for tagged events
                local n_events
                n_events=$(echo "$EVENTS_JSON" | jq '.events | length' 2>/dev/null || echo "?")
                local kinds
                kinds=$(echo "$EVENTS_JSON" | jq -r '[.events[].kind] | group_by(.) | map("\(.[0]):\(length)") | join(", ")' 2>/dev/null || echo "?")
                if $VERBOSE; then
                    dim "  collect_events tag=$tag: $n_events events since=$EVENT_BASELINE, kinds=[$kinds]"
                else
                    dim "    [$tag] $n_events events (kinds: $kinds)"
                fi
            fi
            ;;
        sleep)
            local duration_ms
            duration_ms=$(echo "$step_json" | jq -r '.duration_ms // 1000')
            local duration_s
            duration_s=$(python3 -c "print(${duration_ms} / 1000.0)")
            sleep "$duration_s"
            ;;
        bash)
            local cmd
            cmd=$(echo "$step_json" | jq -r '.command // empty')
            if [ -n "$cmd" ]; then
                if $VERBOSE; then dim "  bash: $cmd"; fi
                eval "$cmd" 2>/dev/null || yellow "  Warning: bash command failed: $cmd"
            fi
            ;;
        *)
            yellow "  Warning: unknown step action '$action'"
            ;;
    esac
}

# ── Test execution ──────────────────────────────────────────────────────────

# Run a single test from a spec. Expects test JSON and phase name.
run_test() {
    local test_json="$1"
    local phase_name="$2"

    local test_id test_name test_class test_timeout
    test_id=$(echo "$test_json" | jq -r '.id')
    test_name=$(echo "$test_json" | jq -r '.name')
    test_class=$(echo "$test_json" | jq -r '.class')
    test_timeout=$(echo "$test_json" | jq -r '.timeout_s // 60')
    local pass_threshold
    pass_threshold=$(echo "$test_json" | jq -r '.pass_threshold // 1.0')

    TOTAL=$((TOTAL + 1))

    # Skip LLM-scored if --skip-llm
    if $SKIP_LLM && [ "$test_class" = "llm_scored" ]; then
        SKIPPED=$((SKIPPED + 1))
        yellow "  SKIP $test_id ($test_name) — llm_scored, --skip-llm set"
        record_result "$(python3 -c "
import json
print(json.dumps({
    'test_id': '$test_id',
    'phase': '$phase_name',
    'class': '$test_class',
    'phrasing_used': None,
    'scores': [],
    'overall_score': 0.0,
    'pass': False,
    'skipped': True,
    'skip_reason': '--skip-llm flag set',
    'notes': ''
}))
")"
        return
    fi

    # Initialize per-test state
    PHRASING_USED=""
    EVENTS_JSON="[]"
    CONV_JSON="{}"
    LAST_HTTP_STATUS="200"
    LAST_HTTP_BODY="{}"
    GENERATION_TIMED_OUT=false
    TEST_PHRASINGS=$(echo "$test_json" | jq -c '.phrasings // []')

    # Execute setup steps (may include /reset which clears events)
    local setup_steps
    setup_steps=$(echo "$test_json" | jq -c '.setup // []')
    local n_setup
    n_setup=$(echo "$setup_steps" | jq 'length')
    for i in $(seq 0 $((n_setup - 1))); do
        local step
        step=$(echo "$setup_steps" | jq -c ".[$i]")
        execute_step "$step"
    done

    # Get event baseline AFTER setup (setup may /reset which clears events)
    EVENT_BASELINE=$(fae_event_baseline)

    # Execute main steps
    local steps
    steps=$(echo "$test_json" | jq -c '.steps // []')
    local n_steps
    n_steps=$(echo "$steps" | jq 'length')
    for i in $(seq 0 $((n_steps - 1))); do
        local step
        step=$(echo "$steps" | jq -c ".[$i]")
        execute_step "$step"
    done

    # Collect final conversation state
    fae_get "/conversation"
    CONV_JSON="$HTTP_BODY"

    # Collect events if not already collected by a step
    if [ "$EVENTS_JSON" = "[]" ]; then
        EVENTS_JSON=$(fae_get_events "$EVENT_BASELINE")
    fi

    # Evaluate criteria
    local criteria_json
    criteria_json=$(echo "$test_json" | jq -c '.criteria // []')

    local scores_json
    if [ "$test_class" = "llm_scored" ] && ! $SKIP_LLM; then
        scores_json=$(run_llm_scored "$test_json" "$EVENTS_JSON" "$CONV_JSON" "$criteria_json")
    else
        export EVENTS_JSON CONV_JSON LAST_HTTP_STATUS LAST_HTTP_BODY
        scores_json=$(evaluate_criteria "$criteria_json")
        unset EVENTS_JSON CONV_JSON LAST_HTTP_STATUS LAST_HTTP_BODY
    fi

    # Post-process tagged_events criteria (e.g., thinking toggle test)
    scores_json=$(SCORES_JSON="$scores_json" \
        TAGGED_EVENTS_thinking_on="${TAGGED_EVENTS_thinking_on:-}" \
        TAGGED_EVENTS_thinking_off="${TAGGED_EVENTS_thinking_off:-}" \
        python3 << 'TAGGED_PYEOF'
import json, os, re

scores = json.loads(os.environ.get("SCORES_JSON", "[]"))
updated = False

for s in scores:
    check = s.get("check", "")
    if "tagged_events" not in check:
        continue

    # Parse: tagged_events('TAG').any_contain_kind('KIND')
    m = re.match(r"(?:not\s+)?tagged_events\('(\w+)'\)\.any_contain_kind\('(\w+)'\)", check)
    if not m:
        continue

    tag = m.group(1)
    kind = m.group(2)
    negated = check.strip().startswith("not ")

    env_key = f"TAGGED_EVENTS_{tag}"
    raw = os.environ.get(env_key, "")
    if not raw:
        s["score"] = 0.0
        s["evidence"] = f"No tagged events for '{tag}' (env {env_key} empty)"
        updated = True
        continue

    try:
        data = json.loads(raw)
        events = data.get("events", []) if isinstance(data, dict) else data
    except (json.JSONDecodeError, TypeError):
        events = []

    # Exact match on event kind field only — do NOT search text field
    # (text may contain "think" in normal LLM responses like "I think...")
    has_kind = any(e.get("kind", "") == kind for e in events)

    if negated:
        s["score"] = 1.0 if not has_kind else 0.0
        s["evidence"] = f"Events for '{tag}': {len(events)} total, kind '{kind}' {'NOT found (good)' if not has_kind else 'FOUND (unexpected)'}"
    else:
        s["score"] = 1.0 if has_kind else 0.0
        s["evidence"] = f"Events for '{tag}': {len(events)} total, kind '{kind}' {'found' if has_kind else 'NOT found'}"
    updated = True

print(json.dumps(scores))
TAGGED_PYEOF
    )

    # Guard: ensure scores_json is valid JSON array
    if [ -z "$scores_json" ] || ! echo "$scores_json" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
        scores_json='[]'
    fi

    # Compute overall score and pass/fail
    local result_json
    result_json=$(python3 -c "
import json, sys

scores = json.loads(sys.argv[1])
test_id = sys.argv[2]
phase = sys.argv[3]
test_class = sys.argv[4]
phrasing = sys.argv[5] if sys.argv[5] else None
pass_threshold = float(sys.argv[6])
timed_out = sys.argv[7] == 'true'

non_skipped = [s for s in scores if not s.get('skipped', False)]
all_skipped = len(non_skipped) == 0 and len(scores) > 0

if timed_out:
    # Only zero scores that weren't already evaluated by post-processors (tagged_events).
    # Multi-step tests may timeout on one phase but have valid tagged scores.
    any_positive = any(s.get('score', 0) > 0 for s in scores)
    if any_positive:
        # Some post-processors scored positively — trust those, mark rest as timeout
        for s in scores:
            if s.get('score', 0) == 0 and 'tagged_events' not in s.get('check', ''):
                s['evidence'] = s.get('evidence', '') + ' [TIMEOUT]'
        overall = sum(s['score'] for s in scores) / len(scores) if scores else 0.0
    else:
        overall = 0.0
        for s in scores:
            s['score'] = 0.0
            s['evidence'] = s.get('evidence', '') + ' [TIMEOUT]'
elif all_skipped:
    overall = 0.0
else:
    overall = sum(s['score'] for s in non_skipped) / len(non_skipped) if non_skipped else 0.0

passed = overall >= pass_threshold and not all_skipped

result = {
    'test_id': test_id,
    'phase': phase,
    'class': test_class,
    'phrasing_used': phrasing,
    'scores': scores,
    'overall_score': round(overall, 4),
    'pass': passed,
    'skipped': all_skipped,
    'skip_reason': 'All criteria skipped (permissions)' if all_skipped else None,
    'notes': 'Generation timed out' if timed_out else ''
}
print(json.dumps(result))
" "$scores_json" "$test_id" "$phase_name" "$test_class" "$PHRASING_USED" "$pass_threshold" "$GENERATION_TIMED_OUT")

    # Record and display
    record_result "$result_json"

    local did_pass did_skip
    did_pass=$(echo "$result_json" | jq -r '.pass')
    did_skip=$(echo "$result_json" | jq -r '.skipped')
    local overall_score
    overall_score=$(echo "$result_json" | jq -r '.overall_score')

    if [ "$did_skip" = "true" ]; then
        SKIPPED=$((SKIPPED + 1))
        yellow "  SKIP $test_id ($test_name) — permissions"
    elif [ "$did_pass" = "true" ]; then
        PASSED=$((PASSED + 1))
        green "  PASS $test_id ($test_name) [${overall_score}]"
    else
        FAILED=$((FAILED + 1))
        red "  FAIL $test_id ($test_name) [${overall_score}]"
        if $VERBOSE; then
            echo "$result_json" | jq -r '.scores[] | "       \(.criterion): \(.score) — \(.evidence)"' 2>/dev/null || true
        fi
    fi

    # Execute teardown steps
    local teardown_steps
    teardown_steps=$(echo "$test_json" | jq -c '.teardown // []')
    local n_teardown
    n_teardown=$(echo "$teardown_steps" | jq 'length')
    for i in $(seq 0 $((n_teardown - 1))); do
        local step
        step=$(echo "$teardown_steps" | jq -c ".[$i]")
        execute_step "$step"
    done
}

# ── LLM scoring ─────────────────────────────────────────────────────────────

run_llm_scored() {
    local test_json="$1"
    local events_json="$2"
    local conv_json="$3"
    local criteria_json="$4"

    local prompt
    prompt="$(cat "$AGENT_PROMPT")

## Test Specification
$test_json

## Collected Events
$events_json

## Conversation State
$conv_json

## Criteria to Score
$criteria_json

Score each criterion. For deterministic criteria, score 0 or 1. For llm_judge criteria, score 0.0-1.0.
Return ONLY a JSON array of score objects like:
[{\"criterion\": \"name\", \"check\": \"...\", \"score\": 0.8, \"evidence\": \"...\"}]"

    # All models use the same pattern: echo prompt | <cmd> -p
    # This works with any CLI that supports pipe mode (stdin → stdout):
    #   claude -p, codex -p, pi -p, kimi -p, gemini -p, etc.
    local llm_output
    # Pipe prompt to LLM CLI, strip terminal escape sequences (OSC+BEL, CSI, etc.)
    local raw_output
    raw_output=$(echo "$prompt" | "$MODEL" -p 2>/dev/null || echo "")
    llm_output=$(printf '%s' "$raw_output" | python3 -c "
import sys, re
raw = sys.stdin.buffer.read().decode('utf-8', errors='replace')
# Strip OSC sequences: ESC ] ... BEL  or  ESC ] ... ESC \\
raw = re.sub(r'\x1b\][^\x07\x1b]*[\x07]', '', raw)
raw = re.sub(r'\x1b\][^\x1b]*\x1b\\\\', '', raw)
# Strip CSI sequences: ESC [ ... letter
raw = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', raw)
print(raw.strip())
" 2>/dev/null || echo "$raw_output")

    if [ -z "$llm_output" ]; then
        yellow "  Warning: '$MODEL -p' returned empty output"
        yellow "  Is '$MODEL' installed and logged in? Try: $MODEL -p <<< 'hello'"
        yellow "  Falling back to deterministic scoring for this test"
        export EVENTS_JSON="$events_json" CONV_JSON="$conv_json"
        llm_output=$(evaluate_criteria "$criteria_json")
        unset EVENTS_JSON CONV_JSON
        echo "$llm_output"
        return
    fi

    # Try to extract JSON array from LLM output
    local parsed
    parsed=$(python3 -c "
import json, sys, re

raw = sys.argv[1]
# Try direct parse
try:
    result = json.loads(raw)
    if isinstance(result, list):
        print(json.dumps(result))
        sys.exit(0)
except json.JSONDecodeError:
    pass

# Try to find JSON array in output
m = re.search(r'\[[\s\S]*\]', raw)
if m:
    try:
        result = json.loads(m.group())
        if isinstance(result, list):
            print(json.dumps(result))
            sys.exit(0)
    except json.JSONDecodeError:
        pass

# Fallback: return empty with error
print(json.dumps([{'criterion': 'llm_parse_error', 'check': '', 'score': 0.0, 'evidence': 'Failed to parse LLM output'}]))
" "$llm_output" 2>/dev/null || echo "[]")

    echo "$parsed"
}

# ── Wait for Fae ────────────────────────────────────────────────────────────

wait_for_fae() {
    bold "Waiting for Fae test server at $FAE_URL ..."
    local elapsed=0
    local max_wait=30
    while [ "$elapsed" -lt "$max_wait" ]; do
        if curl -sf "${FAE_URL}/health" > /dev/null 2>&1; then
            local status pipeline
            fae_get "/health"
            status=$(echo "$HTTP_BODY" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
            pipeline=$(echo "$HTTP_BODY" | jq -r '.pipeline // "unknown"' 2>/dev/null || echo "unknown")
            green "Connected (status=$status, pipeline=$pipeline)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    red "Fae test server not reachable after ${max_wait}s"
    red "Start with: just test-serve"
    return 1
}

# ── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    bold "================================================================="
    bold "  Fae Comprehensive Test Suite — Results"
    bold "================================================================="
    echo ""

    # Per-phase summary
    python3 -c "
import json, sys

with open(sys.argv[1]) as f:
    results = json.load(f)

phases = {}
for r in results:
    p = r['phase']
    if p not in phases:
        phases[p] = {'pass': 0, 'fail': 0, 'skip': 0, 'total': 0}
    phases[p]['total'] += 1
    if r.get('skipped'):
        phases[p]['skip'] += 1
    elif r.get('pass'):
        phases[p]['pass'] += 1
    else:
        phases[p]['fail'] += 1

print(f'  {\"Phase\":<30s} {\"Pass\":>5s} {\"Fail\":>5s} {\"Skip\":>5s} {\"Total\":>6s}')
print('  ' + '-' * 52)
for p in sorted(phases.keys()):
    s = phases[p]
    print(f'  {p:<30s} {s[\"pass\"]:>5d} {s[\"fail\"]:>5d} {s[\"skip\"]:>5d} {s[\"total\"]:>6d}')

total_p = sum(s['pass'] for s in phases.values())
total_f = sum(s['fail'] for s in phases.values())
total_s = sum(s['skip'] for s in phases.values())
total_t = sum(s['total'] for s in phases.values())
print('  ' + '-' * 52)
print(f'  {\"TOTAL\":<30s} {total_p:>5d} {total_f:>5d} {total_s:>5d} {total_t:>6d}')
" "$RESULTS_FILE"

    echo ""

    # Failed test details
    local fail_count
    fail_count=$(python3 -c "
import json
with open('$RESULTS_FILE') as f:
    results = json.load(f)
failed = [r for r in results if not r.get('pass') and not r.get('skipped')]
print(len(failed))
")

    if [ "$fail_count" -gt 0 ]; then
        red "  Failed tests:"
        python3 -c "
import json
with open('$RESULTS_FILE') as f:
    results = json.load(f)
for r in results:
    if not r.get('pass') and not r.get('skipped'):
        failed_criteria = [s for s in r.get('scores', []) if s.get('score', 0) < 1.0 and not s.get('skipped')]
        details = ', '.join(f\"{s['criterion']}={s['score']}\" for s in failed_criteria[:3])
        print(f\"    {r['test_id']}: {details}\")
"
        echo ""
    fi
}

write_report() {
    mkdir -p "$REPORT_DIR"
    python3 -c "
import json, datetime

with open('$RESULTS_FILE') as f:
    results = json.load(f)

report = {
    'timestamp': '$RUN_TIMESTAMP',
    'model': '$MODEL',
    'skip_llm': $( $SKIP_LLM && echo "true" || echo "false" ),
    'thinking_sweep': $( $THINKING_SWEEP && echo "true" || echo "false" ),
    'phase_filter': '$PHASE' if '$PHASE' else None,
    'fae_url': '$FAE_URL',
    'total': len(results),
    'passed': sum(1 for r in results if r.get('pass')),
    'failed': sum(1 for r in results if not r.get('pass') and not r.get('skipped')),
    'skipped': sum(1 for r in results if r.get('skipped')),
    'results': results
}

with open('$REPORT_FILE', 'w') as f:
    json.dump(report, f, indent=2)

print('$REPORT_FILE')
"
}

# ── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
    # Always print summary even on error
    if [ "$TOTAL" -gt 0 ]; then
        print_summary
        local report_path
        report_path=$(write_report 2>/dev/null || echo "")
        if [ -n "$report_path" ]; then
            dim "  Report: $report_path"
        fi
    fi
    rm -f "$RESULTS_FILE"
}
trap cleanup EXIT

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    bold "================================================================="
    bold "  Fae Comprehensive Test Suite"
    bold "================================================================="
    echo ""
    dim "  Model: $MODEL | Skip LLM: $SKIP_LLM | Phase: ${PHASE:-all} | Thinking sweep: $THINKING_SWEEP | Verbose: $VERBOSE"
    echo ""

    check_prereqs
    wait_for_fae || exit 1

    # Disable thinking mode for consistent, faster test execution.
    # The 35B model with thinking adds 30-60s overhead per query.
    # Phase 01 base-008 explicitly tests thinking toggle.
    dim "  Disabling thinking mode for test speed..."
    fae_set_config "llm.thinking_enabled" "false"

    # Warm-up: first LLM generation in a fresh session may produce EOS immediately
    # (35B model prefill cache not yet populated). Run one throwaway generation.
    dim "  Warming up LLM (first generation)..."
    fae_set_config "tool_mode" "off"
    fae_inject "Fae, say hello"
    fae_wait_generation 120
    fae_post "/reset" "{}"
    sleep 2
    dim "  Warm-up complete."

    echo ""

    # Discover spec files
    local spec_files=()
    if [ -n "$PHASE" ]; then
        # Filter by phase number prefix
        for f in "$SPEC_DIR"/${PHASE}*.yaml "$SPEC_DIR"/${PHASE}*.yml; do
            [ -f "$f" ] && spec_files+=("$f")
        done
        if [ ${#spec_files[@]} -eq 0 ]; then
            red "No spec files found matching phase '$PHASE' in $SPEC_DIR"
            exit 1
        fi
    else
        for f in "$SPEC_DIR"/*.yaml "$SPEC_DIR"/*.yml; do
            [ -f "$f" ] && spec_files+=("$f")
        done
    fi

    if [ ${#spec_files[@]} -eq 0 ]; then
        red "No spec files found in $SPEC_DIR"
        exit 1
    fi

    # Sort spec files by name (phases execute in order)
    IFS=$'\n' spec_files=($(sort <<< "${spec_files[*]}")); unset IFS

    dim "  Found ${#spec_files[@]} spec file(s)"
    echo ""

    # Build the list of thinking modes to sweep over.
    local thinking_modes=("off")
    if $THINKING_SWEEP; then
        thinking_modes=("off" "on")
    fi

    # Run each spec file (optionally twice for thinking sweep)
    for thinking_mode in "${thinking_modes[@]}"; do
        if $THINKING_SWEEP; then
            echo ""
            bold "========== THINKING MODE: ${thinking_mode^^} =========="
            if [ "$thinking_mode" = "on" ]; then
                dim "  Enabling thinking mode..."
                fae_set_config "llm.thinking_enabled" "true"
            else
                dim "  Disabling thinking mode..."
                fae_set_config "llm.thinking_enabled" "false"
            fi
            sleep 1
        fi

        for spec_file in "${spec_files[@]}"; do
            local spec_json
            spec_json=$(parse_spec_file "$spec_file")

            if echo "$spec_json" | jq -e '.error' > /dev/null 2>&1; then
                local err
                err=$(echo "$spec_json" | jq -r '.error')
                red "Error parsing $spec_file: $err"
                ERRORS=$((ERRORS + 1))
                continue
            fi

            local phase_id phase_desc
            phase_id=$(echo "$spec_json" | jq -r '.phase')
            phase_desc=$(echo "$spec_json" | jq -r '.name // .phase')

            # Tag phase with thinking mode when sweeping
            local phase_label="$phase_id"
            if $THINKING_SWEEP; then
                phase_label="${phase_id}/think_${thinking_mode}"
            fi

            bold "--- Phase: $phase_label ($phase_desc) ---"

            local n_tests
            n_tests=$(echo "$spec_json" | jq '.tests | length')

            for i in $(seq 0 $((n_tests - 1))); do
                local test_json
                test_json=$(echo "$spec_json" | jq -c ".tests[$i]")

                # When sweeping, prefix test IDs with thinking mode to avoid collisions
                if $THINKING_SWEEP; then
                    test_json=$(echo "$test_json" | jq -c --arg suffix "_think_${thinking_mode}" '.id = .id + $suffix')
                fi

                run_test "$test_json" "$phase_label" || true
            done

            echo ""
        done
    done

    # Restore thinking OFF after sweep (leave Fae in clean state)
    if $THINKING_SWEEP; then
        dim "  Restoring thinking mode OFF..."
        fae_set_config "llm.thinking_enabled" "false"
    fi
}

main
echo ""

# Exit code: 0 if all non-skipped tests passed, 1 if any failed
if [ "$FAILED" -gt 0 ] || [ "$ERRORS" -gt 0 ]; then
    exit 1
else
    exit 0
fi

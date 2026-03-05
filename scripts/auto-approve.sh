#!/usr/bin/env bash
# Auto-approve tool requests during testing
# Usage: ./scripts/auto-approve.sh &
# Kill with: kill $!

BASE_URL="${FAE_TEST_URL:-http://127.0.0.1:7433}"
INTERVAL="${APPROVE_INTERVAL:-2}"

echo "[auto-approve] Polling $BASE_URL/approvals every ${INTERVAL}s (PID $$)"

while true; do
    pending=$(curl -sf "$BASE_URL/approvals" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$pending" ]; then
        count=$(echo "$pending" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('pending',[])))" 2>/dev/null)
        if [ "$count" != "0" ] && [ -n "$count" ]; then
            for i in $(seq 1 "$count"); do
                result=$(curl -sf -X POST "$BASE_URL/approve" -H "Content-Type: application/json" -d '{"approved": true}' 2>/dev/null)
                tool=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('decision','?'))" 2>/dev/null)
                echo "[auto-approve] Approved request (decision=$tool)"
            done
        fi
    fi
    sleep "$INTERVAL"
done

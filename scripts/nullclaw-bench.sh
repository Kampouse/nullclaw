#!/usr/bin/env bash
# nullclaw-bench.sh — Automated latency benchmark for NullClaw /bench endpoint
# Usage: ./nullclaw-bench.sh [iterations] [message]
#   iterations: number of requests (default: 5)
#   message: prompt to send (default: "2+2")
#
# Output: p50/p95/p99 latency, per-request breakdown
# Logs: trace IDs are printed so you can grep ~/nullclaw.log for phase breakdowns

set -euo pipefail

BENCH_URL="${BENCH_URL:-http://127.0.0.1:3000/bench}"
ITERATIONS="${1:-5}"
MESSAGE="${2:-2+2}"
LOG_FILE="${LOG_FILE:-$HOME/nullclaw.log}"

# Colors (no-op if not a terminal)
if [ -t 1 ]; then
    BOLD='\033[1m'
    DIM='\033[2m'
    CYAN='\033[36m'
    YELLOW='\033[33m'
    GREEN='\033[32m'
    RED='\033[31m'
    RESET='\033[0m'
else
    BOLD='' DIM='' CYAN='' YELLOW='' GREEN='' RED='' RESET=''
fi

echo -e "${BOLD}NullClaw Benchmark${RESET}"
echo -e "${DIM}URL: $BENCH_URL | Iterations: $ITERATIONS | Message: \"$MESSAGE\"${RESET}"
echo ""

# Collect results
declare -a LATENCIES
declare -a TRACE_IDS
FAILED=0

for i in $(seq 1 "$ITERATIONS"); do
    printf "  [%d/%d] " "$i" "$ITERATIONS"

    RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$BENCH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"message\": \"$MESSAGE\"}" \
        --max-time 120 2>/dev/null) || {
        echo -e "${RED}FAILED (curl error)${RESET}"
        ((FAILED++)) || true
        LATENCIES+=(-1)
        TRACE_IDS+=("")
        continue
    }

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" != "200" ]; then
        echo -e "${RED}HTTP $HTTP_CODE: $BODY${RESET}"
        ((FAILED++)) || true
        LATENCIES+=(-1)
        TRACE_IDS+=("")
        continue
    fi

    # Parse JSON (uses python for reliability)
    RESULT=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ms = d.get('total_ms', -1)
err = d.get('error', '')
if err:
    print(f'ERROR: {err}')
else:
    print(f'{ms:.1f}ms (reply: {d.get(\"reply_len\", 0)} bytes)')
" 2>/dev/null) || RESULT="PARSE_ERROR: $BODY"

    MS=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_ms', -1))" 2>/dev/null || echo "-1")

    # Get trace ID from the most recent log line
    TRACE_ID=$(grep -oE 't=[a-f0-9]{8}' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")

    if (( $(echo "$MS < 0" | bc -l 2>/dev/null || echo "1") )); then
        echo -e "${YELLOW}$RESULT${RESET}"
    else
        echo -e "${CYAN}$RESULT${RESET}  ${DIM}trace=$TRACE_ID${RESET}"
    fi

    LATENCIES+=("$MS")
    TRACE_IDS+=("$TRACE_ID")
done

echo ""

# Compute percentiles (using python)
SUCCESSFUL=()
for ms in "${LATENCIES[@]}"; do
    if (( $(echo "$ms >= 0" | bc -l 2>/dev/null || echo "0") )); then
        SUCCESSFUL+=("$ms")
    fi
done

COUNT=${#SUCCESSFUL[@]}

if [ "$COUNT" -eq 0 ]; then
    echo -e "${RED}All $ITERATIONS requests failed.${RESET}"
    exit 1
fi

STATS=$(python3 -c "
import statistics, sys

latencies = sorted([float(x) for x in sys.argv[1:]])
n = len(latencies)

def percentile(data, p):
    k = (len(data) - 1) * p / 100
    f = int(k)
    c = f + 1
    if c >= len(data):
        return data[-1]
    return data[f] + (k - f) * (data[c] - data[f])

p50 = percentile(latencies, 50)
p95 = percentile(latencies, 95)
p99 = percentile(latencies, 99)
mean = statistics.mean(latencies)
mn = min(latencies)
mx = max(latencies)

print(f'min={mn:.1f}  p50={p50:.1f}  p95={p95:.1f}  p99={p99:.1f}  mean={mean:.1f}  max={mx:.1f}')
" "${SUCCESSFUL[@]}")

echo -e "${BOLD}Results ($COUNT/${ITERATIONS} succeeded)${RESET}"
echo -e "  ${GREEN}$STATS${RESET}"

if [ "$FAILED" -gt 0 ]; then
    echo -e "  ${RED}$FAILED failed${RESET}"
fi

echo ""
echo -e "${DIM}To see per-phase breakdown, grep logs with trace IDs:${RESET}"
echo -e "${DIM}  grep -E 't=($(echo "${TRACE_IDS[*]}" | tr ' ' '|'))' ~/nullclaw.log | grep span${RESET}"

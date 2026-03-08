#!/usr/bin/env bash
# Run all test modules in parallel and capture issues
set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m' # No Color

MODULES=(
    "agent"
    "channels"
    "channels/cli"
    "channels/telegram"
    "channels/discord"
    "channels/slack"
    "channels/signal"
    "channels/matrix"
    "channels/email"
    "channels/irc"
    "memory"
    "memory/engines"
    "memory/engines/contract_test"
    "memory/engines/markdown"
    "memory/engines/sqlite"
    "memory/lifecycle"
    "memory/lifecycle/cache"
    "memory/lifecycle/hygiene"
    "memory/lifecycle/snapshot"
    "memory/retrieval"
    "memory/vector"
    "providers"
    "providers/anthropic"
    "providers/openai"
    "providers/gemini"
    "providers/ollama"
    "providers/factory"
    "security"
    "security/policy"
    "security/pairing"
    "security/secrets"
    "security/tracker"
    "tools"
    "tools/shell"
    "tools/file_append"
    "tools/memory"
    "tools/browser"
    "tools/cron"
)

OUTPUT_DIR="test_results"
HISTORY_DIR="$OUTPUT_DIR/history"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$HISTORY_DIR"

# Timestamp for this run
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
CURRENT_RUN_FILE="$HISTORY_DIR/run_$TIMESTAMP.json"

# Load previous run data if exists
PREVIOUS_RUN_FILE="$HISTORY_DIR/latest.json"
if [ -f "$PREVIOUS_RUN_FILE" ]; then
    echo -e "${GRAY}Found previous run: $(basename $PREVIOUS_RUN_FILE .json | sed 's/run_//')${NC}"
fi

# Clear current results
> "$OUTPUT_DIR/issues.txt"
> "$OUTPUT_DIR/progress.txt"

MAX_JOBS=8
ACTIVE_JOBS=0

# Function to run a single test module
run_test() {
    local module=$1
    local output_file="$OUTPUT_DIR/${module//\//_}.txt"

    echo -e "${GRAY}[$(date '+%H:%M:%S')]${NC} Starting: $module" | tee -a "$OUTPUT_DIR/progress.txt"

    if zig build test -Dtest-file="$module" --summary all > "$output_file" 2>&1; then
        # Check for leaks
        if grep -q "leaks\|leaked" "$output_file"; then
            echo "FAIL_LEAKS: $module" >> "$OUTPUT_DIR/issues.txt"
            echo "  Leaks found:" >> "$OUTPUT_DIR/issues.txt"
            LEAK_INFO=$(grep -E "leaked [0-9]+ allocation" "$output_file" | sed 's/^/    /')
            echo "$LEAK_INFO" >> "$OUTPUT_DIR/issues.txt"
            echo "---" >> "$OUTPUT_DIR/issues.txt"

            # Show in terminal with details
            echo -e "${GRAY}[$(date '+%H:%M:%S')]${NC} ${YELLOW}FAIL_LEAKS:${NC} $module"
            echo -e "    ${YELLOW}Memory leaks:${NC}"
            echo "$LEAK_INFO" | tee -a "$OUTPUT_DIR/progress.txt"
        else
            echo "PASS: $module" >> "$OUTPUT_DIR/issues.txt"
            echo -e "${GRAY}[$(date '+%H:%M:%S')]${NC} ${GREEN}PASS:${NC} $module" | tee -a "$OUTPUT_DIR/progress.txt"
        fi
    else
        echo "FAIL_ERROR: $module" >> "$OUTPUT_DIR/issues.txt"

        # Extract and clean up test names
        FAILED_TESTS=$(grep "error: '" "$output_file" 2>/dev/null | head -10 | sed "s/error: '//g" | sed "s/'.*$//g" | sed 's/^/    • /')

        if [ -n "$FAILED_TESTS" ]; then
            echo "  Failed tests:" >> "$OUTPUT_DIR/issues.txt"
            echo "$FAILED_TESTS" >> "$OUTPUT_DIR/issues.txt"
        else
            echo "  Failed tests: (unable to parse error details)" >> "$OUTPUT_DIR/issues.txt"
        fi

        # Also capture crash information if present
        if grep -q "terminated with signal" "$output_file" 2>/dev/null; then
            echo "" >> "$OUTPUT_DIR/issues.txt"
            echo "  ${RED}💥 CRASH DETECTED:${NC}" >> "$OUTPUT_DIR/issues.txt"
            grep -A 3 "terminated with signal" "$output_file" 2>/dev/null | head -4 | grep -v "terminated with signal" | sed 's/^/    /' >> "$OUTPUT_DIR/issues.txt"
        fi
        echo "---" >> "$OUTPUT_DIR/issues.txt"

        # Show in terminal with details
        echo -e "${GRAY}[$(date '+%H:%M:%S')]${NC} ${RED}FAIL_ERROR:${NC} $module"
        echo -e "    ${RED}Failed tests:${NC}"
        if [ -n "$FAILED_TESTS" ]; then
            echo "$FAILED_TESTS" | head -5
            if [ $(echo "$FAILED_TESTS" | wc -l) -gt 5 ]; then
                echo "    ... and $(( $(echo "$FAILED_TESTS" | wc -l) - 5 )) more"
            fi
            echo "$FAILED_TESTS" | tee -a "$OUTPUT_DIR/progress.txt" > /dev/null
        else
            echo "    (unable to parse error details from output file)"
        fi
    fi
}

export -f run_test
export OUTPUT_DIR

echo -e "${CYAN}========================================"
echo -e "Running ${#MODULES[@]} test modules in parallel (max $MAX_JOBS concurrent)"
echo -e "========================================${NC}"
echo ""

# Use GNU parallel if available, otherwise use background jobs
if command -v parallel &> /dev/null; then
    echo "Using GNU parallel..."
    printf '%s\n' "${MODULES[@]}" | parallel -j "$MAX_JOBS" run_test {}
else
    echo "Using bash background jobs..."
    for module in "${MODULES[@]}"; do
        # Wait if we've reached max jobs
        while [ $(jobs -r | wc -l) -ge "$MAX_JOBS" ]; do
            sleep 0.1
        done
        run_test "$module" &
    done

    # Wait for all background jobs to complete
    wait
fi

echo ""
echo -e "${CYAN}========================================"
echo -e "TEST SUMMARY"
echo -e "========================================${NC}"
echo ""

echo -e "${GREEN}✅ PASSING MODULES:${NC}"
PASS_COUNT=$(grep "^PASS:" "$OUTPUT_DIR/issues.txt" 2>/dev/null | wc -l)
PASS_COUNT=${PASS_COUNT// /}  # Remove spaces
echo -e "  ${BOLD}Total:${NC} $PASS_COUNT"
grep "^PASS:" "$OUTPUT_DIR/issues.txt" | sed 's/^PASS: /    - /'

echo ""
echo -e "${YELLOW}🔴 FAILING MODULES (LEAKS):${NC}"
LEAK_COUNT=$(grep "^FAIL_LEAKS:" "$OUTPUT_DIR/issues.txt" 2>/dev/null | wc -l)
LEAK_COUNT=${LEAK_COUNT// /}  # Remove spaces
echo -e "  ${BOLD}Total:${NC} $LEAK_COUNT"
if [ "$LEAK_COUNT" -gt 0 ]; then
    grep "^FAIL_LEAKS:" "$OUTPUT_DIR/issues.txt" | sed 's/^FAIL_LEAKS: /    - /'
    echo ""
    echo "  Detailed leaks:"
    grep -A 2 "^FAIL_LEAKS:" "$OUTPUT_DIR/issues.txt" | grep -v "^FAIL_LEAKS:" | grep -v "^---$" | grep -v "^$" | sed 's/^/    /'
fi

echo ""
echo -e "${RED}❌ FAILING MODULES (ERRORS):${NC}"
ERROR_COUNT=$(grep "^FAIL_ERROR:" "$OUTPUT_DIR/issues.txt" 2>/dev/null | wc -l)
ERROR_COUNT=${ERROR_COUNT// /}  # Remove spaces
echo -e "  ${BOLD}Total:${NC} $ERROR_COUNT"
if [ "$ERROR_COUNT" -gt 0 ]; then
    grep "^FAIL_ERROR:" "$OUTPUT_DIR/issues.txt" | sed 's/^FAIL_ERROR: /    - /'
    echo ""
    echo -e "  ${BOLD}Detailed errors:${NC}"
    # Show error details for each failing module
    grep -A 10 "^FAIL_ERROR:" "$OUTPUT_DIR/issues.txt" | grep -v "^FAIL_ERROR:" | grep -v "^---$" | grep -v "^$" | head -50 | sed 's/^/    /'
fi

echo ""
echo -e "${MAGENTA}========================================"
echo -e "📊 OVERALL STATS"
echo -e "========================================${NC}"

# Ensure we have numbers
PASS_COUNT=${PASS_COUNT:-0}
LEAK_COUNT=${LEAK_COUNT:-0}
ERROR_COUNT=${ERROR_COUNT:-0}

TOTAL=$((PASS_COUNT + LEAK_COUNT + ERROR_COUNT))

echo -e "  ${BOLD}Total tested:${NC} $TOTAL"
echo -e "  ${GREEN}Passing:${NC} $PASS_COUNT"
if [ "$TOTAL" -gt 0 ]; then
    echo -e "  ${YELLOW}Leaks:${NC} $LEAK_COUNT ($(( LEAK_COUNT * 100 / TOTAL ))%)"
    echo -e "  ${RED}Errors:${NC} $ERROR_COUNT ($(( ERROR_COUNT * 100 / TOTAL ))%)"
else
    echo -e "  ${YELLOW}Leaks:${NC} $LEAK_COUNT"
    echo -e "  ${RED}Errors:${NC} $ERROR_COUNT"
fi
echo ""
echo -e "${CYAN}Full results saved to:${NC} $OUTPUT_DIR/"
echo -e "${CYAN}Issues summary:${NC} $OUTPUT_DIR/issues.txt"
echo -e "${CYAN}Progress log:${NC} $OUTPUT_DIR/progress.txt"

# ── Save current run results for comparison ───────────────────────────
echo "{
  \"timestamp\": \"$TIMESTAMP\",
  \"date\": \"$(date -Iseconds)\",
  \"passing\": $PASS_COUNT,
  \"leaks\": $LEAK_COUNT,
  \"errors\": $ERROR_COUNT,
  \"total\": $TOTAL
}" > "$CURRENT_RUN_FILE"

# Also save detailed module status
{
  echo "{"
  echo "  \"timestamp\": \"$TIMESTAMP\","
  echo "  \"modules\": {"
  first=true
  for module in "${MODULES[@]}"; do
    if grep -q "^PASS: $module\$" "$OUTPUT_DIR/issues.txt" 2>/dev/null; then
      status="\"pass\""
    elif grep -q "^FAIL_LEAKS: $module\$" "$OUTPUT_DIR/issues.txt" 2>/dev/null; then
      status="\"leak\""
    elif grep -q "^FAIL_ERROR: $module\$" "$OUTPUT_DIR/issues.txt" 2>/dev/null; then
      status="\"error\""
    else
      status="\"unknown\""
    fi

    if [ "$first" = true ]; then
      first=false
    else
      echo ","
    fi
    echo -n "    \"$module\": $status"
  done
  echo ""
  echo "  }"
  echo "}"
} > "$CURRENT_RUN_FILE.detailed"

# Update latest symlink
ln -sf "$(basename $CURRENT_RUN_FILE)" "$HISTORY_DIR/latest.json"
ln -sf "$(basename $CURRENT_RUN_FILE.detailed)" "$HISTORY_DIR/latest.detailed.json"

# ── Compare with previous run ────────────────────────────────────────────
if [ -f "$PREVIOUS_RUN_FILE" ]; then
    echo ""
    echo -e "${MAGENTA}========================================"
    echo -e "📊 COMPARISON WITH PREVIOUS RUN"
    echo -e "========================================${NC}"
    echo ""

    # Extract stats from previous run
    PREV_PASS=$(grep -o '"passing":[[:space:]]*[0-9]*' "$PREVIOUS_RUN_FILE" | grep -o '[0-9]*' || echo "0")
    PREV_LEAKS=$(grep -o '"leaks":[[:space:]]*[0-9]*' "$PREVIOUS_RUN_FILE" | grep -o '[0-9]*' || echo "0")
    PREV_ERRORS=$(grep -o '"errors":[[:space:]]*[0-9]*' "$PREVIOUS_RUN_FILE" | grep -o '[0-9]*' || echo "0")
    PREV_TOTAL=$(grep -o '"total":[[:space:]]*[0-9]*' "$PREVIOUS_RUN_FILE" | grep -o '[0-9]*' || echo "0")

    # Calculate differences
    PASS_DIFF=$((PASS_COUNT - PREV_PASS))
    LEAK_DIFF=$((LEAK_COUNT - PREV_LEAKS))
    ERROR_DIFF=$((ERROR_COUNT - PREV_ERRORS))

    # Show stats comparison
    echo -e "  ${BOLD}Previous run:${NC} $PREV_PASS passing, $PREV_LEAKS leaks, $PREV_ERRORS errors"
    echo -e "  ${BOLD}Current run:${NC}  $PASS_COUNT passing, $LEAK_COUNT leaks, $ERROR_COUNT errors"
    echo ""
    echo -e "  ${BOLD}Changes:${NC}"

    if [ $PASS_DIFF -gt 0 ]; then
        echo -e "    ${GREEN}✓+$PASS_DIFF${NC} more tests passing"
    elif [ $PASS_DIFF -lt 0 ]; then
        echo -e "    ${RED}✗$PASS_DIFF${NC} fewer tests passing"
    else
        echo -e "    ${GRAY}→ No change in passing tests${NC}"
    fi

    if [ $LEAK_DIFF -gt 0 ]; then
        echo -e "    ${YELLOW}⚠+$LEAK_DIFF${NC} more leaks"
    elif [ $LEAK_DIFF -lt 0 ]; then
        echo -e "    ${GREEN}✓$LEAK_DIFF${NC} fewer leaks"
    else
        echo -e "    ${GRAY}→ No change in leaks${NC}"
    fi

    if [ $ERROR_DIFF -gt 0 ]; then
        echo -e "    ${RED}✗+$ERROR_DIFF${NC} more errors"
    elif [ $ERROR_DIFF -lt 0 ]; then
        echo -e "    ${GREEN}✓$ERROR_DIFF${NC} fewer errors"
    else
        echo -e "    ${GRAY}→ No change in errors${NC}"
    fi

    # Compare individual modules if detailed file exists
    PREV_DETAILED="$HISTORY_DIR/latest.detailed.json"
    if [ -f "$PREV_DETAILED" ]; then
        echo ""
        echo -e "  ${BOLD}Module changes:${NC}"

        # Find newly passing modules
        while IFS= read -r module; do
            echo -e "    ${GREEN}✓ FIXED:${NC} $module"
        done < <(grep -o '"[^"]*":[[:space:]]*"pass"' "$CURRENT_RUN_FILE.detailed" | sed 's/"//g' | sed 's/:.*$//' | while read m; do
            grep -q "\"$m\":[[:space:]]*\"pass\"" "$PREV_DETAILED" || echo "$m"
        done)

        # Find newly failing modules
        while IFS= read -r module; do
            echo -e "    ${RED}✗ BROKEN:${NC} $module"
        done < <(grep -E '"(error|leak)"' "$CURRENT_RUN_FILE.detailed" | grep -o '"[^"]*":' | sed 's/"//g' | sed 's/:$//' | while read m; do
            grep -q "\"$m\":[[:space:]]*\"pass\"" "$PREV_DETAILED" && echo "$m"
        done)
    fi

    echo ""
    echo -e "${GRAY}Previous run:${NC} $(basename $PREVIOUS_RUN_FILE .json | sed 's/run_//')"
    echo -e "${GRAY}Current run:${NC}  $TIMESTAMP"
fi


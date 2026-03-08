#!/usr/bin/env bash
# View test run history and comparisons

HISTORY_DIR="test_results/history"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$1" = "--list" ] || [ "$1" = "-l" ]; then
    echo -e "${CYAN}=== Test Run History ===${NC}"
    echo ""

    if [ ! -d "$HISTORY_DIR" ]; then
        echo "No history found. Run ./test_nullclaw.sh first."
        exit 1
    fi

    ls -lt "$HISTORY_DIR"/run_*.json 2>/dev/null | head -20 | while read -r line; do
        file=$(echo "$line" | awk '{print $NF}')
        timestamp=$(basename "$file" .json | sed 's/run_//')

        # Parse the JSON file
        passing=$(grep -o '"passing":[[:space:]]*[0-9]*' "$file" | grep -o '[0-9]*')
        leaks=$(grep -o '"leaks":[[:space:]]*[0-9]*' "$file" | grep -o '[0-9]*')
        errors=$(grep -o '"errors":[[:space:]]*[0-9]*' "$file" | grep -o '[0-9]*')

        # Determine status color
        if [ "$leaks" -eq 0 ] && [ "$errors" -eq 0 ]; then
            status="${GREEN}✓ ALL PASS${NC}"
        elif [ "$errors" -gt 10 ]; then
            status="${RED}✗ MANY FAILURES${NC}"
        else
            status="${YELLOW}⚠ SOME ISSUES${NC}"
        fi

        printf "${GRAY}%s${NC} - Pass: ${GREEN}%s${NC}, Leaks: ${YELLOW}%s${NC}, Errors: ${RED}%s${NC} %s\n" \
            "$timestamp" "$passing" "$leaks" "$errors" "$status"
    done

elif [ "$1" = "--compare" ] || [ "$1" = "-c" ]; then
    # Compare two specific runs
    if [ -z "$2" ] || [ -z "$3" ]; then
        echo "Usage: $0 --compare <run1> <run2>"
        echo "Example: $0 --compare 20260307_195500 20260307_200000"
        exit 1
    fi

    RUN1="$HISTORY_DIR/run_$2.json"
    RUN2="$HISTORY_DIR/run_$3.json"

    if [ ! -f "$RUN1" ]; then
        echo "Run not found: $2"
        exit 1
    fi

    if [ ! -f "$RUN2" ]; then
        echo "Run not found: $3"
        exit 1
    fi

    echo -e "${CYAN}=== Comparing Runs ===${NC}"
    echo ""
    echo -e "${BOLD}Run 1:${NC} $2"
    echo -e "${BOLD}Run 2:${NC} $3"
    echo ""

    # Extract stats
    PASS1=$(grep -o '"passing":[[:space:]]*[0-9]*' "$RUN1" | grep -o '[0-9]*')
    PASS2=$(grep -o '"passing":[[:space:]]*[0-9]*' "$RUN2" | grep -o '[0-9]*')
    LEAK1=$(grep -o '"leaks":[[:space:]]*[0-9]*' "$RUN1" | grep -o '[0-9]*')
    LEAK2=$(grep -o '"leaks":[[:space:]]*[0-9]*' "$RUN2" | grep -o '[0-9]*')
    ERR1=$(grep -o '"errors":[[:space:]]*[0-9]*' "$RUN1" | grep -o '[0-9]*')
    ERR2=$(grep -o '"errors":[[:space:]]*[0-9]*' "$RUN2" | grep -o '[0-9]*')

    echo -e "${BOLD}Passing:${NC} $PASS1 → $PASS2 ($((PASS2 - PASS1)))"
    echo -e "${BOLD}Leaks:${NC}   $LEAK1 → $LEAK2 ($((LEAK2 - LEAK1)))"
    echo -e "${BOLD}Errors:${NC}  $ERR1 → $ERR2 ($((ERR2 - ERR1)))"

elif [ "$1" = "--graph" ] || [ "$1" = "-g" ]; then
    # Show a simple ASCII graph of trends
    echo -e "${CYAN}=== Test Trends (Last 10 runs) ===${NC}"
    echo ""

    runs=($(ls -t "$HISTORY_DIR"/run_*.json 2>/dev/null | head -10))

    if [ ${#runs[@]} -eq 0 ]; then
        echo "No history found. Run ./test_nullclaw.sh first."
        exit 1
    fi

    # Extract passing counts
    pass_counts=()
    for run in "${runs[@]}"; do
        pass=$(grep -o '"passing":[[:space:]]*[0-9]*' "$run" | grep -o '[0-9]*')
        pass_counts+=("$pass")
    done

    # Find max for scaling
    max_pass=0
    for count in "${pass_counts[@]}"; do
        if [ "$count" -gt "$max_pass" ]; then
            max_pass=$count
        fi
    done

    # Print graph
    idx=0
    for run in "${runs[@]}"; do
        count=${pass_counts[$idx]}
        timestamp=$(basename "$run" .json | sed 's/run_//' | cut -d'_' -f2 | cut -c1-4)

        # Scale bar
        bar_length=$((count * 50 / max_pass))
        bar=$(printf "%${bar_length}s" | tr ' ' '█')

        printf "${GRAY}%s${NC} [%2s] ${GREEN}%s${NC}\n" "$timestamp" "$count" "$bar"
        idx=$((idx + 1))
    done

else
    cat << 'EOF'
Test History Viewer - Usage:

  ./test_history.sh --list, -l     List all test runs
  ./test_history.sh --compare, -c  Compare two specific runs
  ./test_history.sh --graph, -g    Show ASCII graph of trends

Examples:
  ./test_history.sh --list
  ./test_history.sh --compare 20260307_195500 20260307_200000
  ./test_history.sh --graph
EOF
fi

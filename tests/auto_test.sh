#!/usr/bin/env bash
# TRUE Auto-Discovery Test Runner
# Actually discovers all test modules and runs them

set -e

echo "🔍 Auto-discovering test modules..."

# Find all modules with tests
MODULES=$(find src -name '*.zig' -exec grep -l 'test "' {} \; | sed 's|^src/||' | sed 's|\.zig$||' | sort | uniq)

TOTAL=$(echo "$MODULES" | wc -l | tr -d ' ')
echo "Found $TOTAL test modules"
echo ""

PASSED=0
FAILED=0
LEAKED=0

# Test each module
for module in $MODULES; do
    if [ -z "$module" ]; then continue; fi

    echo -n "  $module... "

    # Run the test
    if OUTPUT=$(zig build test "-Dtest-file=$module" --summary all 2>&1); then
        # Check for leaks
        if echo "$OUTPUT" | grep -q "leaked"; then
            echo "❌ (leaks)"
            LEAK_COUNT=$(echo "$OUTPUT" | grep -c "leaked" || true)
            echo "    ($LEAK_COUNT leaks)"
            ((LEAKED++))
            ((FAILED++))
        else
            echo "✅"
            ((PASSED++))
        fi
    else
        echo "❌ (error)"
        ((FAILED++))
    fi
done

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed, $LEAKED with leaks"
echo "========================================"

if [ $FAILED -gt 0 ] || [ $LEAKED -gt 0 ]; then
    exit 1
fi

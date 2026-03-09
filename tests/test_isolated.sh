#!/usr/bin/env bash
# Run tests with full isolation - each test file in its own process
# This eliminates test isolation issues caused by global state pollution

set -e

ZIG="${ZIG:-/Users/asil/.local/share/zigup/0.16.0-dev.2694+74f361a5c/files/zig}"
PARALLEL="${PARALLEL:-8}"

# Find all test files
TEST_FILES=$(find src -name "*.zig" -exec grep -l "^test " {} \; | sort)

TOTAL=0
PASS=0
FAIL=0
LEAK=0

run_test() {
    local file=$1
    local result
    
    # Run test in isolated process
    if $ZIG build test -Dtest-file="${file#src/}" --summary all > /dev/null 2>&1; then
        if $ZIG build test -Dtest-file="${file#src/}" 2>&1 | grep -q "leaked"; then
            echo "LEAK: $file"
            return 2
        else
            echo "PASS: $file"
            return 0
        fi
    else
        echo "FAIL: $file"
        return 1
    fi
}

export -f run_test
export ZIG

echo "Running tests with full isolation..."
echo "Using Zig: $ZIG"
echo "Parallelism: $PARALLEL"
echo ""

# Run tests in parallel with GNU parallel or xargs
if command -v parallel &> /dev/null; then
    echo "$TEST_FILES" | parallel -j$PARALLEL run_test
else
    echo "$TEST_FILES" | xargs -P$PARALLEL -I{} bash -c 'run_test "$@"' _ {}
fi

echo ""
echo "==================================="
echo "Test isolation complete"
echo "Each test file ran in separate process"
echo "==================================="

#!/usr/bin/env bash
# Quick test run on just a few modules

MODULES=(
    "channels/cli"
    "memory/engines/markdown"
    "tools/shell"
)

for module in "${MODULES[@]}"; do
    echo "Testing: $module"
    zig build test -Dtest-file="$module" --summary all 2>&1 | tee "test_${module//\//_}.txt"
    echo ""
done

echo "========================================"
echo "QUICK TEST SUMMARY"
echo "========================================"

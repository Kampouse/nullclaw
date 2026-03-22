#!/bin/bash

echo "Testing markdown memory leaks..."
zig build test --summary all 2>&1 | grep -E "(markdown.*leaked|All tests passed)"

echo ""
echo "Testing agent tool output leaks..."
zig build test --summary all 2>&1 | grep -E "(Agent tool loop.*leaked|All tests passed)"

echo ""
echo "Counting total leaks..."
zig build test --summary all 2>&1 | grep -c "leaked" || echo "0"

echo ""
echo "Showing all leaks..."
zig build test --summary all 2>&1 | grep "leaked"

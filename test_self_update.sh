#!/bin/bash

echo "========================================="
echo "Self-Update Feature End-to-End Test"
echo "========================================="
echo ""

# Test 1: Status operation
echo "Test 1: STATUS Operation"
echo "----------------------------"
./zig-out/bin/nullclaw agent -m 'use self_update with operation status' 2>&1 | grep -E "(Agent Status|Branch:|Commit:|Uncommitted:|✅|❌)" | head -10
echo ""

# Test 2: Health check operation
echo "Test 2: HEALTH_CHECK Operation"
echo "----------------------------"
./zig-out/bin/nullclaw agent -m 'use self_update with operation health_check' 2>&1 | grep -E "(Health check|Version:|Binary:|✅|❌|PASSED|FAILED)" | head -10
echo ""

# Test 3: Verify binary exists and works
echo "Test 3: Binary Verification"
echo "----------------------------"
echo "Binary version:"
./zig-out/bin/nullclaw --version
echo ""

# Test 4: Verify git operations
echo "Test 4: Git Operations"
echo "----------------------------"
echo "Current branch:"
git branch --show-current
echo "Current commit:"
git log -1 --format="%h - %s"
echo ""

echo "========================================="
echo "All Tests Completed!"
echo "========================================="

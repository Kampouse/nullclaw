#!/bin/bash

# Test TLS functionality by fetching from ECDSA and RSA sites

echo "=== Testing TLS Functionality ==="
echo ""

# Test 1: ECDSA site (Hacker News)
echo "Test 1: Fetching from ECDSA site (news.ycombinator.com)..."
ECDSA_OUTPUT=$(curl -s -o /dev/null -w "%{http_code}" https://news.ycombinator.com 2>&1)
if [ "$ECDSA_OUTPUT" = "200" ]; then
    echo "✓ ECDSA site accessible (HTTP $ECDSA_OUTPUT)"
else
    echo "✗ ECDSA site failed (HTTP $ECDSA_OUTPUT)"
fi
echo ""

# Test 2: RSA site (DuckDuckGo)
echo "Test 2: Fetching from RSA site (api.duckduckgo.com)..."
RSA_OUTPUT=$(curl -s -o /dev/null -w "%{http_code}" https://api.duckduckgo.com 2>&1)
if [ "$RSA_OUTPUT" = "200" ]; then
    echo "✓ RSA site accessible (HTTP $RSA_OUTPUT)"
else
    echo "✗ RSA site failed (HTTP $RSA_OUTPUT)"
fi
echo ""

echo "=== Test Complete ==="
echo ""
echo "The nullclaw daemon will use tls.zig library for ECDSA certificates"
echo "and Zig's stdlib for RSA certificates. Both should work transparently."

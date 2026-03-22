#!/bin/bash

# Test runner script for nullclaw

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== Running NullClaw Tests ===${NC}"
echo ""

echo -e "${YELLOW}Running zig build test...${NC}"
echo ""

zig build test 2>&1 | tee /tmp/nullclaw_test.log

EXIT_CODE=${PIPESTATUS[0]}

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    # Extract summary
    grep -E "passed|failed" /tmp/nullclaw_test.log | tail -5
else
    echo -e "${RED}✗ Some tests failed${NC}"
    echo "Check /tmp/nullclaw_test.log for details"
fi

exit $EXIT_CODE

#!/bin/bash

# Quick status check for nullclaw

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== NullClaw Status ===${NC}"
echo ""

# Check if binary exists
if [ -f "./zig-out/bin/nullclaw" ]; then
    SIZE=$(ls -lh ./zig-out/bin/nullclaw | awk '{print $5}')
    echo -e "${GREEN}✓ Binary exists${NC} (${SIZE})"
else
    echo -e "${RED}✗ Binary not found${NC} - run ./build.sh first"
    exit 1
fi
echo ""

# Check running processes
echo -e "${BLUE}Running processes:${NC}"
PROCS=$(ps aux | grep nullclaw | grep -v grep | wc -l | tr -d ' ')
if [ "$PROCS" -gt 0 ]; then
    echo -e "${GREEN}✓ $PROCS nullclaw process(es) running${NC}"
    ps aux | grep nullclaw | grep -v grep | awk '{print "  PID: " $2 " | " $11 " " $12 " " $13}'
else
    echo -e "${YELLOW}○ No nullclaw processes running${NC}"
fi
echo ""

# Show capabilities
echo -e "${BLUE}Available tools:${NC}"
./zig-out/bin/nullclaw capabilities 2>&1 | grep "tools.*:"
echo ""

# Show config status
echo -e "${BLUE}Configuration status:${NC}"
./zig-out/bin/nullclaw status 2>&1 | head -12
echo ""

# Quick health check
echo -e "${BLUE}Health check:${NC}"
./zig-out/bin/nullclaw doctor 2>&1 | grep -E "ok|warning|error" | head -5

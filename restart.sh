#!/bin/bash

# NullClaw rebuild and restart script
# Makes it easy to apply code changes and restart the agent

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== NullClaw Rebuild & Restart Script ===${NC}"
echo ""

# Step 1: Kill all nullclaw processes
echo -e "${YELLOW}→ Step 1: Stopping all nullclaw processes...${NC}"
pkill -9 nullclaw 2>/dev/null || true
sleep 2

# Verify they're all stopped
if pgrep -x nullclaw > /dev/null; then
    echo -e "${RED}✗ Failed to stop some processes${NC}"
    pgrep -x nullclaw
    exit 1
fi
echo -e "${GREEN}✓ All nullclaw processes stopped${NC}"
echo ""

# Step 2: Rebuild
echo -e "${YELLOW}→ Step 2: Rebuilding nullclaw...${NC}"
if [ "$1" = "--release" ] || [ "$1" = "-r" ]; then
    echo "Building with ReleaseSmall optimization..."
    zig build -Doptimize=ReleaseSmall
else
    echo "Building with debug settings..."
    zig build
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Build successful${NC}"
echo ""

# Show binary info
BINARY_SIZE=$(ls -lh ./zig-out/bin/nullclaw | awk '{print $5}')
echo -e "${BLUE}Binary: ./zig-out/bin/nullclaw (${BINARY_SIZE})${NC}"
echo ""

# Step 3: Show capabilities
echo -e "${YELLOW}→ Step 3: Verifying new tools...${NC}"
./zig-out/bin/nullclaw capabilities 2>&1 | grep "tools.*:"
echo ""

# Step 4: Restart agent (optional)
if [ "$1" = "--no-start" ] || [ "$1" = "-n" ]; then
    echo -e "${BLUE}== Skipping agent start (as requested) ==${NC}"
    echo ""
    echo "To start manually:"
    echo "  ./zig-out/bin/nullclaw agent"
    echo "  ./zig-out/bin/nullclaw gateway"
else
    echo -e "${YELLOW}→ Step 4: Starting agent...${NC}"
    echo -e "${BLUE}Agent starting... (Ctrl+C to stop)${NC}"
    echo ""

    # Start agent
    exec ./zig-out/bin/nullclaw agent
fi

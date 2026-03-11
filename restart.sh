#!/bin/bash

# NullClaw rebuild and restart script
# Makes it easy to apply code changes and restart the Telegram bot

set -e

# Parse flags
RELEASE_BUILD=false  # Default to debug mode for trace output
NO_START=false
SHOW_HELP=false
ENABLE_TRACE=true

for arg in "$@"; do
    case $arg in
        --help|-h)
            SHOW_HELP=true
            ;;
        --release|-r)
            RELEASE_BUILD=true
            ;;
        --no-trace)
            ENABLE_TRACE=false
            ;;
        --no-start|-n)
            NO_START=true
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use '$0 --help' for usage information"
            exit 1
            ;;
    esac
done

# Show help and exit
if [ "$SHOW_HELP" = true ]; then
    cat << EOF
NullClaw Rebuild & Restart Script (Telegram Bot)

Usage:
  $0 [OPTIONS]

Options:
  -h, --help       Show this help message
  -r, --release    Build in release mode (no trace output, smaller binary)
  --no-trace       Disable detailed trace logging (default: enabled)
  -n, --no-start   Build but don't start the bot

Examples:
  $0                    Build debug with trace and start Telegram bot (default)
  $0 --release        Build release without trace and start Telegram bot
  $0 --no-trace       Build debug without trace logging
  $0 -n               Build but don't start
  $0 --release -n     Build release, don't start

Binary sizes:
  Debug:    ~26M   (faster compile, includes trace output)
  Release:  ~3.2M  (optimized, no trace output)

Trace output:
  Debug builds include detailed [TRACE] logging for debugging
  Release builds have no trace output for better performance
EOF
    exit 0
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== NullClaw Rebuild & Restart Script ===${NC}"
echo ""

# Step 1: Build first (safer - keeps old process running if build fails)
echo -e "${YELLOW}→ Step 1: Building nullclaw...${NC}"
if [ "$RELEASE_BUILD" = true ]; then
    echo -e "${BLUE}Building with ReleaseSmall optimization (no trace output)...${NC}"
    zig build -Doptimize=ReleaseSmall
else
    echo -e "${BLUE}Building debug mode with trace output enabled...${NC}"
    zig build
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Build failed - keeping existing process running${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Build successful${NC}"
echo ""

# Show binary info with version
BINARY_SIZE=$(ls -lh ./zig-out/bin/nullclaw | awk '{print $5}')
VERSION_INFO=$(./zig-out/bin/nullclaw --version 2>&1)
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Version:${NC}   ${VERSION_INFO}"
echo -e "${BLUE}Binary:${NC}    ./zig-out/bin/nullclaw (${BINARY_SIZE})"
if [ "$RELEASE_BUILD" = false ]; then
    echo -e "${GREEN}Trace:${NC}     ENABLED - detailed [TRACE] logging will be shown"
else
    echo -e "${YELLOW}Trace:${NC}     DISABLED - optimized for performance"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Step 2: Verify capabilities
echo -e "${YELLOW}→ Step 2: Verifying new tools...${NC}"
./zig-out/bin/nullclaw capabilities 2>&1 | grep "tools.*:"
echo ""

# Step 3: Stop old processes (only after successful build)
echo -e "${YELLOW}→ Step 3: Stopping all nullclaw processes...${NC}"
pkill -9 -f "zig-out/bin/nullclaw" 2>/dev/null || true
pkill -9 -f "nullclaw" 2>/dev/null || true
sleep 2

# Verify they're all stopped
if pgrep -f "nullclaw" > /dev/null; then
    echo -e "${RED}✗ Failed to stop some processes${NC}"
    pgrep -f -l "nullclaw"
    exit 1
fi
echo -e "${GREEN}✓ All nullclaw processes stopped${NC}"
echo ""

# Step 4: Start Telegram bot (optional)
if [ "$NO_START" = true ]; then
    echo -e "${BLUE}== Skipping bot start (as requested) ==${NC}"
    echo ""
    echo "To start manually:"
    echo "  ./zig-out/bin/nullclaw channel start telegram"
    echo "  ./zig-out/bin/nullclaw agent"
else
    echo -e "${YELLOW}→ Step 4: Starting Telegram bot...${NC}"
    echo -e "${BLUE}Telegram bot starting... (Ctrl+C to stop)${NC}"
    echo ""

    # Start Telegram bot
    exec ./zig-out/bin/nullclaw channel start telegram
fi

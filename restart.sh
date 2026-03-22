#!/bin/bash

# NullClaw rebuild and restart script
# Makes it easy to apply code changes and restart the Telegram bot

set -e

# Parse flags
RELEASE_BUILD=false  # Default to debug mode for trace output
NO_START=false
SHOW_HELP=false
ENABLE_TRACE=true
SHOW_LOGS=false
TAIL_LOGS=false

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
        --logs|-l)
            SHOW_LOGS=true
            ;;
        --tail|-t)
            TAIL_LOGS=true
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
  -l, --logs       Show recent logs before restart
  -t, --tail       Tail logs after restart (Ctrl+C to stop)

Examples:
  $0                    Build debug with trace and start Telegram bot (default)
  $0 --release        Build release without trace and start Telegram bot
  $0 --no-trace       Build debug without trace logging
  $0 -n               Build but don't start
  $0 --release -n     Build release, don't start
  $0 --logs           Show recent logs before restart
  $0 --tail           Tail logs after restart

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
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

START_TIME=$(date +%s)

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         NullClaw Rebuild & Restart Script                    ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check for crash logs before starting
if [ "$SHOW_LOGS" = true ]; then
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}Recent Crash Logs (last 5):${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    CRASH_LOGS=$(ls -t ~/Library/Logs/DiagnosticReports/nullclaw* 2>/dev/null | head -5)
    if [ -n "$CRASH_LOGS" ]; then
        echo "$CRASH_LOGS" | while read -r log; do
            echo -e "${YELLOW}• $(basename "$log")${NC}"
            echo "  Crashed: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$log" 2>/dev/null || stat -c "%y" "$log" 2>/dev/null)"
        done
        echo ""
    else
        echo -e "${GREEN}✓ No crash logs found${NC}"
        echo ""
    fi
fi

# Show current running processes
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Current nullclaw processes:${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
PROCESSES=$(pgrep -f -l "nullclaw" 2>/dev/null || true)
if [ -n "$PROCESSES" ]; then
    echo "$PROCESSES" | while read -r line; do
        PID=$(echo "$line" | awk '{print $1}')
        CMD=$(echo "$line" | awk '{print $2}')
        echo -e "${YELLOW}PID $PID:${NC} $CMD"
    done
    echo ""
else
    echo -e "${GREEN}✓ No nullclaw processes running${NC}"
    echo ""
fi

# Step 1: Build first (safer - keeps old process running if build fails)
echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║ Step 1: Building nullclaw                                    ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
BUILD_START=$(date +%s)

if [ "$RELEASE_BUILD" = true ]; then
    echo -e "${BLUE}Building with ReleaseSmall optimization (no trace output)...${NC}"
    echo -e "${CYAN}Command: zig build -Doptimize=ReleaseSmall${NC}"
    zig build -Doptimize=ReleaseSmall
else
    echo -e "${BLUE}Building debug mode with trace output enabled...${NC}"
    echo -e "${CYAN}Command: zig build${NC}"
    zig build
fi

if [ $? -ne 0 ]; then
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║ ✗ BUILD FAILED - keeping existing process running           ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║ ✓ BUILD SUCCESSFUL (${BUILD_TIME}s)                                  ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
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
echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║ Step 2: Verifying new tools                                  ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo -e "${CYAN}Command: ./zig-out/bin/nullclaw capabilities${NC}"
./zig-out/bin/nullclaw capabilities 2>&1 | grep "tools.*:" || echo -e "${YELLOW}No tools found${NC}"
echo ""

# Step 3: Stop old processes (only after successful build)
echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║ Step 3: Stopping all nullclaw processes                     ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"

echo -e "${CYAN}Sending SIGTERM to all nullclaw processes...${NC}"
pkill -f "zig-out/bin/nullclaw" 2>/dev/null || true
pkill -f "nullclaw" 2>/dev/null || true

echo -e "${CYAN}Waiting 2 seconds for graceful shutdown...${NC}"
sleep 2

# Force kill if still running
if pgrep -f "nullclaw" > /dev/null; then
    echo -e "${YELLOW}Some processes still running, sending SIGKILL...${NC}"
    pkill -9 -f "zig-out/bin/nullclaw" 2>/dev/null || true
    pkill -9 -f "nullclaw" 2>/dev/null || true
    sleep 1
fi

# Verify they're all stopped
if pgrep -f "nullclaw" > /dev/null; then
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║ ✗ FAILED TO STOP PROCESSES                                   ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    pgrep -f -l "nullclaw"
    exit 1
fi

echo -e "${GREEN}✓ All nullclaw processes stopped${NC}"
echo ""

# Step 4: Start Telegram bot (optional)
if [ "$NO_START" = true ]; then
    END_TIME=$(date +%s)
    TOTAL_TIME=$((END_TIME - START_TIME))
    
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║ ✓ READY (Total time: ${TOTAL_TIME}s)                                 ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "To start manually:"
    echo -e "${CYAN}  ./zig-out/bin/nullclaw channel start telegram${NC}"
    echo -e "${CYAN}  ./zig-out/bin/nullclaw agent${NC}"
else
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║ Step 4: Starting Telegram bot                                ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    END_TIME=$(date +%s)
    TOTAL_TIME=$((END_TIME - START_TIME))
    
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ ✓ RESTART COMPLETE (Total time: ${TOTAL_TIME}s)                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${CYAN}Starting Telegram bot... (Ctrl+C to stop)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Start Telegram bot with optional log tailing
    if [ "$TAIL_LOGS" = true ]; then
        # Start in background and tail logs
        ./zig-out/bin/nullclaw channel start telegram 2>&1 | tee -a ~/nullclaw.log &
        BOT_PID=$!
        echo -e "${GREEN}Bot started with PID: $BOT_PID${NC}"
        echo -e "${CYAN}Tailing logs (Ctrl+C to stop tailing, bot will continue)...${NC}"
        echo ""
        wait $BOT_PID
    else
        # Start in foreground
        exec ./zig-out/bin/nullclaw channel start telegram
    fi
fi

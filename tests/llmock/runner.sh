#!/bin/bash
# NullClaw Integration Test Runner with native Zig mock server
# Usage: ./tests/llmock/runner.sh [test-name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PORT=4010
MOCK_PID=""
ZIG="/Users/asil/.local/share/zigup/0.16.0-dev.2694+74f361a5c/files/zig"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup function
cleanup() {
    if [ -n "$MOCK_PID" ]; then
        log_info "Stopping mock server (PID: $MOCK_PID)..."
        kill $MOCK_PID 2>/dev/null || true
        wait $MOCK_PID 2>/dev/null || true
    fi
}

# Register cleanup on exit
trap cleanup EXIT

# Build mock server executable
log_info "Building mock server..."
cd "$PROJECT_ROOT"

$ZIG build-exe \
    -ODebug \
    --dep http_util \
    -Mroot=tests/mock_server.zig \
    -Mhttp_util=src/http_util.zig \
    --name mock-server \
    2>&1 | grep -E "error:" && exit 1 || true

if [ ! -f "mock-server" ]; then
    log_error "Mock server build failed"
    exit 1
fi

log_info "Mock server built successfully"

# Start mock server in background
log_info "Starting mock server on port $PORT..."
./mock-server &
MOCK_PID=$!

# Wait for server to start
sleep 2

# Check if server is running
if ! kill -0 $MOCK_PID 2>/dev/null; then
    log_error "Failed to start mock server"
    exit 1
fi

log_info "Mock server started at http://localhost:$PORT (PID: $MOCK_PID)"

# Set environment variables for Zig tests
export OPENAI_BASE_URL="http://localhost:$PORT/v1/chat/completions"
export ANTHROPIC_BASE_URL="http://localhost:$PORT/v1/messages"
export GEMINI_BASE_URL="http://localhost:$PORT/v1beta"
export OPENAI_API_KEY="mock-key"
export ANTHROPIC_API_KEY="mock-key"
export GEMINI_API_KEY="mock-key"

log_info "Environment: OPENAI_BASE_URL=$OPENAI_BASE_URL"

# Run test
cd "$PROJECT_ROOT"

if [ -n "$1" ]; then
    if [ "$1" = "tool-calls" ]; then
        log_info "Running tool calling test..."
        $ZIG build test-tool-calls 2>&1
    elif [ "$1" = "comprehensive" ]; then
        log_info "Running comprehensive integration tests..."
        $ZIG build test-comprehensive 2>&1
    else
        log_error "Unknown test: $1"
        exit 1
    fi
else
    log_info "Running all integration tests..."
    $ZIG build test-integration 2>&1
fi

#!/bin/bash
# NullClaw Integration Test Runner with native Zig mock server
# Usage: ./tests/llmock/runner.sh [test-name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PORT=4010
MOCK_PID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
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

# Start Zig mock server
log_info "Starting Zig mock server on port $PORT..."
cd "$PROJECT_ROOT"

/Users/asil/.local/share/zigup/0.16.0-dev.2694+74f361a5c/files/zig build mock-server -- $PORT &
MOCK_PID=$!

# Wait for server to start
sleep 1

# Check if server is running
if ! kill -0 $MOCK_PID 2>/dev/null; then
    log_error "Failed to start mock server"
    exit 1
fi

log_info "Mock server started at http://localhost:$PORT"

# Set environment variables for Zig tests
export OPENAI_BASE_URL="http://localhost:$PORT/v1/chat/completions"
export ANTHROPIC_BASE_URL="http://localhost:$PORT/v1/messages"
export GEMINI_BASE_URL="http://localhost:$PORT/v1beta"
export OPENAI_API_KEY="mock-key"
export ANTHROPIC_API_KEY="mock-key"
export GEMINI_API_KEY="mock-key"

log_info "Environment variables set:"
log_info "  OPENAI_BASE_URL=$OPENAI_BASE_URL"
log_info "  ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"
log_info "  GEMINI_BASE_URL=$GEMINI_BASE_URL"

# Run Zig integration tests
log_info "Running Zig integration tests..."

if [ -n "$1" ]; then
    # Run specific test
    cd "$PROJECT_ROOT"
    if [ "$1" = "tool-calls" ]; then
        /Users/asil/.local/share/zigup/0.16.0-dev.2694+74f361a5c/files/zig build test-tool-calls 2>&1
    else
        log_error "Unknown test: $1"
        log_info "Available tests: tool-calls, all"
        exit 1
    fi
else
    # Run all integration tests using zig build with correct Zig version
    cd "$PROJECT_ROOT"
    /Users/asil/.local/share/zigup/0.16.0-dev.2694+74f361a5c/files/zig build test-integration 2>&1
fi

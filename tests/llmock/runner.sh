#!/bin/bash
# NullClaw Integration Test Runner with llmock
# Usage: ./tests/llmock/runner.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
PORT=4010
LLMOCK_PID=""

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
    if [ -n "$LLMOCK_PID" ]; then
        log_info "Stopping llmock (PID: $LLMOCK_PID)..."
        kill $LLMOCK_PID 2>/dev/null || true
        wait $LLMOCK_PID 2>/dev/null || true
    fi
}

# Register cleanup on exit
trap cleanup EXIT

# Check if npm is available
if ! command -v npm &> /dev/null; then
    log_error "npm is required but not installed"
    exit 1
fi

# Install dependencies if needed
if [ ! -d "$PROJECT_ROOT/node_modules" ]; then
    log_info "Installing dependencies..."
    cd "$PROJECT_ROOT"
    npm install --silent
fi

# Start llmock server
log_info "Starting llmock server on port $PORT..."
cd "$PROJECT_ROOT"
npx llmock -p $PORT -f "$FIXTURES_DIR" &
LLMOCK_PID=$!

# Wait for server to start
sleep 2

# Check if server is running
if ! kill -0 $LLMOCK_PID 2>/dev/null; then
    log_error "Failed to start llmock server"
    exit 1
fi

log_info "llmock server started at http://localhost:$PORT"

# Set environment variables for Zig tests
export OPENAI_BASE_URL="http://localhost:$PORT/v1"
export ANTHROPIC_BASE_URL="http://localhost:$PORT/v1"
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
cd "$PROJECT_ROOT"

if [ -n "$1" ]; then
    # Run specific test file
    zig test "$1"
else
    # Run all integration tests
    zig build test-integration 2>/dev/null || zig test tests/integration/*.zig
fi

TEST_EXIT_CODE=$?

if [ $TEST_EXIT_CODE -eq 0 ]; then
    log_info "All tests passed!"
else
    log_error "Tests failed with exit code $TEST_EXIT_CODE"
fi

exit $TEST_EXIT_CODE

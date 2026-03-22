#!/bin/bash
# Example: Trace NullClaw daemon startup

echo "Starting NullClaw with tracing enabled..."
echo ""

# Create log directory
mkdir -p /tmp/nullclaw-trace

# Run with trace file
export NULLCLAW_TRACE=debug
export NULLCLAW_TRACE_FILE=/tmp/nullclaw-trace/daemon.log

./zig-out/bin/nullclaw daemon --port 4001 &
DAEMON_PID=$!

echo "Daemon started (PID: $DAEMON_PID)"
echo "Trace file: /tmp/nullclaw-trace/daemon.log"
echo ""
echo "Watch trace output:"
echo "  tail -f /tmp/nullclaw-trace/daemon.log"
echo ""
echo "Press Ctrl+C to stop"

wait $DAEMON_PID

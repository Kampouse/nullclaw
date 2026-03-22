#!/bin/bash
cd /Users/asil/.openclaw/workspace/nullclaw

# Run daemon and capture ALL output
./zig-out/bin/nullclaw daemon --port 4001 > /tmp/nullclaw_output.log 2>&1 &
PID=$!

# Wait a bit for startup
sleep 2

# Kill daemon
kill $PID 2>/dev/null

# Wait for process to finish
wait $PID 2>/dev/null

# Show output
echo "=== Daemon Output ==="
cat /tmp/nullclaw_output.log

# Check for trace markers
echo ""
echo "=== Trace Markers ==="
grep -E "\[INFO\]|\[DEBUG\]|\[ERROR\]|Span|subsystem" /tmp/nullclaw_output.log || echo "No trace markers found"

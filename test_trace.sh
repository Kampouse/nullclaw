#!/bin/bash
cd /Users/asil/.openclaw/workspace/nullclaw

# Run nullclaw briefly and capture output
timeout 2 ./zig-out/bin/nullclaw daemon --port 4001 2>&1 | tee /tmp/nullclaw_trace_test.log

echo ""
echo "=== Captured output ==="
cat /tmp/nullclaw_trace_test.log

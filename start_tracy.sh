#!/bin/bash
# Tracy Profiler + nullclaw launcher

set -e

echo "🚀 Starting Tracy Profiler + nullclaw..."
echo "=========================================="
echo ""

# Check if Tracy is already running
if pgrep -f "tracy-glfw.*tracy" > /dev/null; then
    echo "✅ Tracy Profiler is already running"
    echo "   Using existing instance"
else
    # Start Tracy in background
    echo "📊 Starting Tracy Profiler..."
    nix-shell -p tracy-glfw --run "tracy" &
    TRACY_PID=$!
    echo "   Tracy PID: $TRACY_PID"
    echo ""
    # Give Tracy a moment to start up
    sleep 2
fi

# Check if binary already exists
BINARY="./zig-out/bin/nullclaw"
if [ -f "$BINARY" ]; then
    echo "✅ Binary already exists at $BINARY"
    echo "   Skipping build (use 'zig build -Dtracy=true' to rebuild)"
else
    echo "🔨 Building nullclaw with Tracy profiling enabled..."
    zig build -Dtracy=true
    echo ""
fi

# Run nullclaw
echo "🤖 Running nullclaw (Tracy will auto-connect)..."
echo ""
./zig-out/bin/nullclaw gateway

# Clean up Tracy when nullclaw exits (only if we started it)
echo ""
if [ -n "$TRACY_PID" ]; then
    echo "✅ nullclaw exited. Killing Tracy (PID: $TRACY_PID)..."
    kill $TRACY_PID 2>/dev/null || true
else
    echo "✅ nullclaw exited. Tracy left running (was already started)"
fi
echo "Done!"

#!/bin/bash
# Tracy Profiler + nullclaw launcher
#
# === HOW TRACY CONNECTION WORKS ===
#
# Tracy uses a CLIENT-SERVER model with UDP BROADCAST for discovery:
#   1. Tracy GUI = SERVER (listens on port 8086)
#   2. nullclaw = CLIENT (broadcasts to find Tracy, then connects)
#
# The profiled application (nullclaw) uses UDP BROADCAST to discover
# Tracy on the local network. If broadcast is blocked (macOS firewall,
# VPN, Docker, etc.), the connection will fail.
#
# === CONFIGURATION ===
#
# Environment variables:
#   TRACY_PORT      - Port for Tracy to listen on (default: 8086)
#   NULLCLAW_CMD    - Command to run (default: gateway)
#   NO_BUILD        - Skip building if set to "1"
#   KEEP_TRACY      - Keep Tracy running after nullclaw exits if set to "1"
#
# === TROUBLESHOOTING ===
#
# If Tracy shows "Waiting for connection" indefinitely:
#
# 1. CHECK FIREWALL: macOS may block UDP broadcast
#    System Settings > Privacy & Security > Firewall > Options
#    Allow incoming connections to "tracy" or disable firewall temporarily
#
# 2. START TRACY MANUALLY FIRST:
#    nix-shell -p tracy-glfw --run "tracy"
#    Then in another terminal:
#    zig build -Dtracy=true && ./zig-out/bin/nullclaw gateway
#
# 3. USE TRACY ON-DEMAND MODE (reverses connection model):
#    zig build -Dtracy=true -Dtracy_on_demand=true
#    Then in Tracy GUI: File > Connect to > localhost
#
# 4. CHECK NETWORK: VPNs, Docker, and some network configs block broadcast

set -e

# Configuration with defaults
TRACY_PORT="${TRACY_PORT:-8086}"
NULLCLAW_CMD="${NULLCLAW_CMD:-gateway}"
NO_BUILD="${NO_BUILD:-}"
KEEP_TRACY="${KEEP_TRACY:-}"

echo "🚀 Tracy Profiler + nullclaw Launcher"
echo "======================================"
echo ""
echo "📋 Configuration:"
echo "   Tracy Port: $TRACY_PORT"
echo "   Nullclaw Command: $NULLCLAW_CMD"
echo ""

# Function to check if Nix is available
check_nix() {
    if ! command -v nix-shell &> /dev/null; then
        echo "❌ nix-shell not found. Please install Nix or use Homebrew:"
        echo "   brew install tracy"
        echo ""
        echo "   Then run: tracy &"
        exit 1
    fi
}

# Check if Tracy is already running
if pgrep -f "tracy" > /dev/null 2>&1; then
    echo "✅ Tracy Profiler is already running"
    TRACY_PID=""
else
    check_nix

    echo "📊 Starting Tracy Profiler on port $TRACY_PORT..."
    echo ""
    echo "   Using: nix-shell -p tracy-glfw --run 'tracy'"
    echo ""

    # Start Tracy using Nix
    nix-shell -p tracy-glfw --run "tracy" &
    TRACY_PID=$!
    echo "   Tracy PID: $TRACY_PID"

    # Wait for Tracy to be ready - this is crucial!
    echo "   Waiting for Tracy to initialize..."
    sleep 3

    # Verify Tracy started
    if ! kill -0 $TRACY_PID 2>/dev/null; then
        echo "❌ Tracy failed to start."
        echo "   Try running manually: nix-shell -p tracy-glfw --run 'tracy'"
        exit 1
    fi
    echo "   ✅ Tracy is ready"
fi

echo ""

# Build or skip
if [ -n "$NO_BUILD" ]; then
    echo "⏭️  Skipping build (NO_BUILD is set)"
else
    echo "🔨 Building nullclaw with Tracy profiling enabled..."
    zig build -Dtracy=true
fi

# Check binary exists
BINARY="./zig-out/bin/nullclaw"
if [ ! -f "$BINARY" ]; then
    echo "❌ Binary not found at $BINARY"
    echo "   Run without NO_BUILD or build manually: zig build -Dtracy=true"
    exit 1
fi

echo ""
echo "🤖 Running nullclaw..."
echo ""
echo "📌 IMPORTANT: If Tracy shows 'Waiting for connection':"
echo "   1. Check macOS Firewall settings (may block UDP broadcast)"
echo "   2. In Tracy GUI, try: File > Connect to > localhost"
echo "   3. Or start Tracy manually first, then run nullclaw"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Run nullclaw
./zig-out/bin/nullclaw $NULLCLAW_CMD

# Clean up Tracy when nullclaw exits
echo ""
if [ -n "$TRACY_PID" ]; then
    if [ -n "$KEEP_TRACY" ]; then
        echo "✅ nullclaw exited. Tracy is still running (PID: $TRACY_PID)."
        echo "   To stop Tracy: kill $TRACY_PID"
    else
        echo "✅ nullclaw exited. Stopping Tracy (PID: $TRACY_PID)..."
        kill $TRACY_PID 2>/dev/null || true
        wait $TRACY_PID 2>/dev/null || true
    fi
else
    echo "✅ nullclaw exited. Tracy is still running."
    echo "   To stop Tracy: pkill -f tracy"
fi
echo "Done!"

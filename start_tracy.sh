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
#   NULLCLAW_CMD    - Command to run (default: channel start telegram)
#   NO_BUILD        - Skip building if set to "1"
#   KEEP_TRACY      - Keep Tracy running after nullclaw exits if set to "1"
#   TRACY_BUILD_DIR - Directory for Tracy build (default: .tracy-build)
#   TRACY_VERSION    - Tracy version to download (default: v0.10.0)
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
#    zig build -Dtracy=true -p .tracy-build && ./.tracy-build/bin/nullclaw channel start telegram
#
# 3. USE TRACY ON-DEMAND MODE (reverses connection model):
#    zig build -Dtracy=true -Dtracy_on_demand=true -p .tracy-build
#    Then in Tracy GUI: File > Connect to > localhost
#
# 4. CHECK NETWORK: VPNs, Docker, and some network configs block broadcast

set -e

# Configuration with defaults
TRACY_PORT="${TRACY_PORT:-8086}"
NULLCLAW_CMD="${NULLCLAW_CMD:-channel start telegram}"
NO_BUILD="${NO_BUILD:-}"
KEEP_TRACY="${KEEP_TRACY:-}"
TRACY_BUILD_DIR="${TRACY_BUILD_DIR:-.tracy-build}"
TRACY_VERSION="${TRACY_VERSION:-v0.10.0}"

echo "🚀 Tracy Profiler + nullclaw Launcher"
echo "======================================"
echo ""
echo "📋 Configuration:"
echo "   Tracy Port: $TRACY_PORT"
echo "   Nullclaw Command: $NULLCLAW_CMD"
echo "   Build Directory: $TRACY_BUILD_DIR"
echo "   Tracy Version: $TRACY_VERSION"
echo ""

# Create build directory if it doesn't exist
mkdir -p "$TRACY_BUILD_DIR/bin"

# Function to download Tracy for macOS
download_tracy_macos() {
    local TRACY_DIR="$1"
    local TRACY_BIN="$TRACY_DIR/bin/tracy"

    echo "📥 Downloading Tracy $TRACY_VERSION for macOS..."

    # Tracy releases URL pattern
    local TRACY_URL="https://github.com/wolfpld/tracy/releases/download/${TRACY_VERSION}/tracy-macos.zip"

    # Check if already downloaded
    if [ -f "$TRACY_BIN" ]; then
        echo "✅ Tracy already installed at $TRACY_BIN"
        return 0
    fi

    # Download and extract
    local TEMP_DIR=$(mktemp -d)
    local TEMP_ZIP="$TEMP_DIR/tracy.zip"

    echo "   Downloading from: $TRACY_URL"
    if command -v curl &> /dev/null; then
        curl -L -o "$TEMP_ZIP" "$TRACY_URL" 2>/dev/null || {
            echo "⚠️  Failed to download Tracy from GitHub"
            echo "   Falling back to nix-shell..."
            rm -rf "$TEMP_DIR"
            return 1
        }
    elif command -v wget &> /dev/null; then
        wget -q -O "$TEMP_ZIP" "$TRACY_URL" || {
            echo "⚠️  Failed to download Tracy from GitHub"
            echo "   Falling back to nix-shell..."
            rm -rf "$TEMP_DIR"
            return 1
        }
    else
        echo "⚠️  No curl or wget found"
        echo "   Falling back to nix-shell..."
        rm -rf "$TEMP_DIR"
        return 1
    fi

    echo "   Extracting..."
    unzip -q "$TEMP_ZIP" -d "$TEMP_DIR" 2>/dev/null || {
        echo "⚠️  Failed to extract Tracy"
        rm -rf "$TEMP_DIR"
        return 1
    }

    # Find and copy the binary
    local TRACY_EXE=$(find "$TEMP_DIR" -name "tracy" -o -name "Tracy" 2>/dev/null | head -1)
    if [ -z "$TRACY_EXE" ]; then
        echo "⚠️  Tracy binary not found in archive"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    cp "$TRACY_EXE" "$TRACY_BIN"
    chmod +x "$TRACY_BIN"

    # Cleanup
    rm -rf "$TEMP_DIR"

    echo "✅ Tracy installed to $TRACY_BIN"
    return 0
}

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

# Start Tracy Profiler
start_tracy() {
    local TRACY_BIN="$TRACY_BUILD_DIR/bin/tracy"

    # Try to use local Tracy first
    if [ -f "$TRACY_BIN" ]; then
        echo "📊 Starting Tracy Profiler from $TRACY_BUILD_DIR..."
        "$TRACY_BIN" &
        TRACY_PID=$!
        echo "   Tracy PID: $TRACY_PID"
        return 0
    fi

    # Try to download Tracy
    echo "📊 Tracy not found locally, attempting to download..."
    if download_tracy_macos "$TRACY_BUILD_DIR"; then
        echo "📊 Starting Tracy Profiler from $TRACY_BUILD_DIR..."
        "$TRACY_BIN" &
        TRACY_PID=$!
        echo "   Tracy PID: $TRACY_PID"
        return 0
    fi

    # Fall back to nix-shell
    echo "📊 Starting Tracy Profiler via nix-shell..."
    echo "   Using: nix-shell -p tracy-glfw --run 'tracy'"
}

# Check if Tracy is already running
if pgrep -f "tracy" > /dev/null 2>&1; then
    echo "✅ Tracy Profiler is already running"
    TRACY_PID=""
else
    start_tracy

    # Wait for Tracy to be ready - this is crucial!
    echo "   Waiting for Tracy to initialize..."
    sleep 3

    # Verify Tracy started
    if [ -n "$TRACY_PID" ] && ! kill -0 $TRACY_PID 2>/dev/null; then
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
    echo "   Output directory: $TRACY_BUILD_DIR"
    zig build -Dtracy=true -p "$TRACY_BUILD_DIR"
fi

# Check binary exists
BINARY="./$TRACY_BUILD_DIR/bin/nullclaw"
if [ ! -f "$BINARY" ]; then
    echo "❌ Binary not found at $BINARY"
    echo "   Run without NO_BUILD or build manually: zig build -Dtracy=true -p $TRACY_BUILD_DIR"
    exit 1
fi

echo ""
echo "🤖 Running nullclaw from $TRACY_BUILD_DIR..."
echo ""
echo "📌 IMPORTANT: If Tracy shows 'Waiting for connection':"
echo "   1. Check macOS Firewall settings (may block UDP broadcast)"
echo "   2. In Tracy GUI, try: File > Connect to > localhost"
echo "   3. Or start Tracy manually first, then run nullclaw"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Run nullclaw from the build directory
cd "$TRACY_BUILD_DIR" && ./bin/nullclaw $NULLCLAW_CMD

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

# Build Tracy Profiler from vendored source (macOS)
#
# This script builds the Tracy profiler (GUI) from the vendored source
# at vendor/tracy. On macOS, it uses Homebrew or Nix for dependencies.
#
# Usage:
#   ./build_tracy.sh              # Build Tracy
#   ./build_tracy.sh --run        # Build and run Tracy
#   ./build_tracy.sh --clean      # Clean build artifacts
#
# Requirements (macOS):
#   - Xcode Command Line Tools: xcode-select --install
#   - One of: Homebrew (brew) OR Nix (nix-shell)
#   - The vendored Tracy source at vendor/tracy

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACY_SRC="$SCRIPT_DIR/vendor/tracy"
BUILD_DIR="$SCRIPT_DIR/.tracy-build"

# Parse arguments
RUN_AFTER=false
CLEAN=false
for arg in "$@"; do
    case $arg in
        --run) RUN_AFTER=true ;;
        --clean) CLEAN=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# Clean if requested
if [ "$CLEAN" = true ]; then
    echo "🧹 Cleaning Tracy build artifacts..."
    rm -rf "$BUILD_DIR"
    echo "✅ Clean complete"
    exit 0
fi

# Check Tracy source exists
if [ ! -d "$TRACY_SRC" ]; then
    echo "❌ Tracy source not found at: $TRACY_SRC"
    exit 1
fi

# Detect OS
OS="$(uname -s)"
case "$OS" in
    Darwin*)
        echo "🍎 Building Tracy on macOS"
        ;;
    Linux*)
        echo "🐧 Building Tracy on Linux"
        ;;
    *)
        echo "❌ Unsupported OS: $OS"
        exit 1
        ;;
esac

echo "   Source: $TRACY_SRC"
echo "   Build: $BUILD_DIR"
echo ""

# Create build directory
mkdir -p "$BUILD_DIR"

# Build function using Homebrew
build_with_homebrew() {
    echo "📦 Using Homebrew for dependencies..."

    # Check for Homebrew
    if ! command -v brew &> /dev/null; then
        echo "❌ Homebrew not found. Install with:"
        echo "   /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi

    # Install dependencies
    echo "📦 Installing dependencies..."
    brew install cmake glfw capstone freetype tbb pkg-config || true

    # Build
    echo "🔧 Configuring Tracy..."
    cd "$BUILD_DIR"

    # Configure
    cmake "$TRACY_SRC/profiler" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$(brew --prefix)" \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

    # Build
    echo "🏗️  Building Tracy..."
    local NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    make -j"$NPROC"

    echo "✅ Tracy build complete!"
}

# Build function using Nix
build_with_nix() {
    echo "📦 Using Nix for dependencies..."

    # Check for Nix
    if ! command -v nix-shell &> /dev/null; then
        echo "❌ Nix not found. Install from: https://nixos.org/download.html"
        echo "   Or use Homebrew: brew install cmake glfw capstone freetype tbb"
        exit 1
    fi

    # macOS-specific packages (no Wayland/X11 needed)
    local NIX_PKGS="cmake ninja glfw capstone freetype tbb pkg-config"

    # Add macOS frameworks via impure paths
    echo "🔧 Building Tracy with Nix..."

    nix-shell -p $NIX_PKGS --run "
        set -e
        cd '$BUILD_DIR'

        echo '🔧 Configuring Tracy...'
        cmake '$TRACY_SRC/profiler' \
            -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

        echo '🏗️  Building Tracy...'
        ninja

        echo '✅ Tracy build complete!'
    "
}

# Try Homebrew first, then Nix
if command -v brew &> /dev/null; then
    build_with_homebrew
elif command -v nix-shell &> /dev/null; then
    build_with_nix
else
    echo "❌ Neither Homebrew nor Nix found!"
    echo ""
    echo "Install one of:"
    echo "  Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo "  Nix:      sh <(curl -L https://nixos.org/nix/install)"
    exit 1
fi

# Find the binary
TRACY_BIN=$(find "$BUILD_DIR" -name "tracy" -type f -executable 2>/dev/null | head -1)

if [ -z "$TRACY_BIN" ]; then
    # Try common output locations
    for path in "$BUILD_DIR/tracy" "$BUILD_DIR/src/tracy" "$BUILD_DIR/bin/tracy"; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            TRACY_BIN="$path"
            break
        fi
    done
fi

if [ -z "$TRACY_BIN" ]; then
    echo ""
    echo "⚠️  Tracy binary not found. Build may have failed."
    echo "   Check the build output above for errors."
    echo ""
    echo "   You can also try building manually:"
    echo "   cd $BUILD_DIR"
    echo "   cmake $TRACY_SRC/profiler -DCMAKE_BUILD_TYPE=Release"
    echo "   make"
    exit 1
fi

echo ""
echo "✅ Tracy built successfully!"
echo "   Binary: $TRACY_BIN"
echo ""
echo "To run:"
echo "   $TRACY_BIN"
echo ""
echo "Or use: ./build_tracy.sh --run"

# Run if requested
if [ "$RUN_AFTER" = true ]; then
    echo ""
    echo "🚀 Running Tracy..."
    echo ""
    exec "$TRACY_BIN"
fi

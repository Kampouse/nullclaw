#!/bin/bash
# Run real web_search test

ZIG="${ZIG:-zig}"

echo "Building test_web_search_real..."

$ZIG build-exe test_web_search_real.zig \
  -I src \
  --mod root:src \
  --mod tls:lib/tls_zig/src/root.zig \
  -femit-bin=test_web_search_real_bin \
  --cache-dir .zig-cache \
  --global-cache-dir ~/.cache/zig \
  2>&1

if [ $? -eq 0 ]; then
    echo "Build successful, running test..."
    echo ""
    ./test_web_search_real_bin
    rm -f test_web_search_real_bin
else
    echo "Build failed"
    exit 1
fi

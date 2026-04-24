#!/bin/bash

# Quick build script for nullclaw

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Building NullClaw ===${NC}"
echo ""

if [ "$1" = "--release" ] || [ "$1" = "-r" ]; then
    echo -e "${YELLOW}Building with ReleaseSmall...${NC}"
    zig build -Doptimize=ReleaseSmall
else
    echo -e "${YELLOW}Building debug version...${NC}"
    zig build
fi

if [ $? -eq 0 ]; then
    SIZE=$(ls -lh ./zig-out/bin/nullclaw | awk '{print $5}')
    echo -e "${GREEN}✓ Build successful!${NC}"
    echo -e "${BLUE}Binary: ./zig-out/bin/nullclaw (${SIZE})${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

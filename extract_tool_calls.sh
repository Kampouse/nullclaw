#!/bin/bash

# Extract tool calls from nullclaw logs for testing
# Usage: ./extract_tool_calls.sh [log_file]

LOG_FILE="${1:-/tmp/nullclaw_gateway.log}"
OUTPUT_DIR="test_results/tool_calls"
MINIMAX_FILE="$OUTPUT_DIR/minimax_examples.txt"
NATIVE_FILE="$OUTPUT_DIR/native_examples.txt"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Clear previous output
> "$MINIMAX_FILE"
> "$NATIVE_FILE"

echo "Extracting tool calls from $LOG_FILE..."
echo ""

# Extract MiniMax tool calls
echo "=== MiniMax Tool Calls ===" | tee -a "$MINIMAX_FILE"
grep -A2 "Detected MiniMax tool call" "$LOG_FILE" | while read -r line; do
    if echo "$line" | grep -q "Detected MiniMax tool call"; then
        echo "" | tee -a "$MINIMAX_FILE"
        echo "$line" | tee -a "$MINIMAX_FILE"
    elif echo "$line" | grep -q "Raw MiniMax content:"; then
        echo "$line" | sed 's/.*Raw MiniMax content: //' | tee -a "$MINIMAX_FILE"
    elif echo "$line" | grep -q "Parsed MiniMax tool call:"; then
        echo "$line" | tee -a "$MINIMAX_FILE"
    fi
done

# Extract native tool calls
echo "" | tee -a "$NATIVE_FILE"
echo "=== Native Tool Calls ===" | tee -a "$NATIVE_FILE"
grep -A2 "Detected native OpenAI tool call format" "$LOG_FILE" | while read -r line; do
    if echo "$line" | grep -q "Detected native"; then
        echo "" | tee -a "$NATIVE_FILE"
        echo "$line" | tee -a "$NATIVE_FILE"
    elif echo "$line" | grep -q "Raw native response:"; then
        echo "$line" | sed 's/.*Raw native response: //' | tee -a "$NATIVE_FILE"
    elif echo "$line" | grep -q "Parsed native tool call:"; then
        echo "$line" | tee -a "$NATIVE_FILE"
    fi
done

echo ""
echo "Extraction complete!"
echo "MiniMax examples saved to: $MINIMAX_FILE"
echo "Native examples saved to: $NATIVE_FILE"
echo ""
echo "Summary:"
echo "  MiniMax calls: $(grep -c "Detected MiniMax tool call" "$LOG_FILE" || echo 0)"
echo "  Native calls: $(grep -c "Detected native OpenAI tool call format" "$LOG_FILE" || echo 0)"

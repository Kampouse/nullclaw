#!/bin/bash

# Monitor nullclaw logs for tool calls in real-time
# Usage: ./monitor_tool_calls.sh

LOG_FILE="/tmp/nullclaw_gateway_debug.log"

echo "🔍 Monitoring for tool calls..."
echo "   Log file: $LOG_FILE"
echo ""
echo "Send a message to the agent that requires tools (e.g., 'what's the weather?')"
echo ""
echo "Press Ctrl+C to stop"
echo ""

tail -f "$LOG_FILE" 2>/dev/null | while read -r line; do
    # Highlight tool call detections
    if echo "$line" | grep -q "Detected.*tool call"; then
        echo -e "\033[1;33m[DETECTION]\033[0m $line"
    # Highlight successful parses
    elif echo "$line" | grep -q "✓ Parsed.*tool call"; then
        echo -e "\033[1;32m[SUCCESS]\033[0m $line"
    # Highlight raw content
    elif echo "$line" | grep -q "Raw.*content:"; then
        echo -e "\033[1;36m[RAW]\033[0m $line"
    # Highlight errors
    elif echo "$line" | grep -q "Failed to parse"; then
        echo -e "\033[1;31m[ERROR]\033[0m $line"
    fi
done

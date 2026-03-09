#!/bin/bash
# Watch nullclaw logs in real-time with color coding

echo "╔═══════════════════════════════════════════════════════╗"
echo "║  Watching nullclaw logs (Ctrl+C to stop)            ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "Waiting for logs to appear..."
echo ""

# Tail all nullclaw logs with color highlighting
tail -f /tmp/nullclaw*.log 2>/dev/null | while read line; do
    # Color code different log levels
    if echo "$line" | grep -q "\[error\]"; then
        echo -e "\033[0;31m$line\033[0m"  # Red
    elif echo "$line" | grep -q "\[warn\]"; then
        echo -e "\033[0;33m$line\033[0m"  # Yellow
    elif echo "$line" | grep -q "\[info\]"; then
        echo -e "\033[0;32m$line\033[0m"  # Green
    elif echo "$line" | grep -q "\[debug\]"; then
        echo -e "\033[0;36m$line\033[0m"  # Cyan
    elif echo "$line" | grep -q "✓\|✓✓✓"; then
        echo -e "\033[0;32m$line\033[0m"  # Green for success
    elif echo "$line" | grep -q "✗\|error\|Error\|ERROR"; then
        echo -e "\033[0;31m$line\033[0m"  # Red for errors
    elif echo "$line" | grep -q "web_fetch\|web_search"; then
        echo -e "\033[0;35m$line\033[0m"  # Magenta for web tools
    else
        echo "$line"
    fi
done

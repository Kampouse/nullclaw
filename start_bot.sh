#!/bin/bash
# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect workspace: use script directory if it's a git repo, otherwise use default
if [ -d "$SCRIPT_DIR/.git" ]; then
    export NULLCLAW_WORKSPACE="$SCRIPT_DIR"
elif [ -d "$PWD/.git" ]; then
    export NULLCLAW_WORKSPACE="$PWD"
else
    # Fallback to hardcoded path
    export NULLCLAW_WORKSPACE=/Users/jean/dev/nullclaw
fi

# Preserve SSH agent environment for git operations
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK}"
export SSH_AGENT_PID="${SSH_AGENT_PID}"

cd "$NULLCLAW_WORKSPACE"
./zig-out/bin/nullclaw "$@"

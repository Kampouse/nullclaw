# Starting the Bot

## Quick Start

The easiest way to start the bot is using the provided script:

```bash
./start_bot.sh channel start telegram
```

## What the Script Does

The `start_bot.sh` script automatically:

1. **Detects your workspace** - Finds the git repository directory
2. **Sets up environment** - Configures `NULLCLAW_WORKSPACE` automatically
3. **Preserves SSH keys** - Makes git operations work seamlessly
4. **Starts the bot** - Runs from the correct directory

## Features

- ✅ **No setup required** - Just run the script
- ✅ **Works from any directory** - Auto-detects workspace
- ✅ **Git integration** - SSH keys preserved for updates
- ✅ **Self-update compatible** - Workspace persists across updates

## Manual Start (Advanced)

If you need to start the bot manually without the script:

```bash
cd /path/to/your/repo
export NULLCLAW_WORKSPACE=$(pwd)
./zig-out/bin/nullclaw channel start telegram
```

## After Self-Update

When the bot updates itself via the `self_update` tool:
1. It pulls latest code from git
2. Rebuilds using the same workspace
3. Restarts with the same configuration
4. No manual intervention needed!

## Troubleshooting

**Bot using wrong workspace?**
```bash
# Check current workspace
./zig-out/bin/nullclaw status | grep Workspace

# Force specific workspace
NULLCLAW_WORKSPACE=/path/to/repo ./zig-out/bin/nullclaw channel start telegram
```

**Git operations failing?**
```bash
# Make sure SSH agent is running
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_gork  # or your key

# Then start the bot
./start_bot.sh channel start telegram
```

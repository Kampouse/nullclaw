# Portable Zig Tool Setup

## Problem

The nullclaw agent runs as a **daemon/service** and doesn't inherit your user shell's environment (PATH, etc.). This means it can't find tools like `zig` even if they're in your PATH.

## Solutions

### Option 1: Configure zig_path (RECOMMENDED - Most Portable)

**File**: `~/.nullclaw/config.json`

The zig tool now supports a configurable path. Add this to your config:

```json
{
  "tools": {
    "zig_path": "/Users/jean/.local/bin/zig"
  }
}
```

**For other systems**, change the path:
- **Linux**: `"/usr/local/bin/zig"` or `"/usr/bin/zig"`
- **macOS**: `"/opt/homebrew/bin/zig"` or `"/usr/local/bin/zig"`
- **Windows**: `C:\Program Files\zig\zig.exe`

### Option 2: Use Wildcard Security Policy

**File**: `~/.nullclaw/config.json`

Add `"*"` to allowed_commands to allow all tool paths:

```json
{
  "autonomy": {
    "allowed_commands": ["*", "zig", "cargo", ...]
  }
}
```

### Option 3: Set Environment for Service

If running as a systemd service, create `~/.config/systemd/user/nullclaw.service.d/override.conf`:

```ini
[Service]
Environment="PATH=/Users/jean/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
```

Then reload: `systemctl --user daemon-reload`

## Testing

Test if zig is accessible:

```bash
# Direct test
/Users/jean/.local/bin/zig version

# Through agent
./zig-out/bin/nullclaw agent -m "run zig version"
```

## Cross-Platform Paths

| Platform | Common Zig Locations |
|----------|---------------------|
| macOS (Homebrew) | `/opt/homebrew/bin/zig` |
| macOS (manual) | `/usr/local/bin/zig` |
| Linux (distro) | `/usr/bin/zig` |
| Linux (manual) | `/usr/local/bin/zig` |
| Windows | `C:\Program Files\zig\zig.exe` |
| Windows (Scoop) | `C:\Users\<user>\scoop\shims\zig.exe` |

## How It Works

The zig tool (`src/tools/zig_build.zig`) now:
1. Reads `zig_path` from config
2. Falls back to `"zig"` (PATH lookup) if not set
3. Uses the configured full path to execute zig

This makes it portable across different systems while still allowing users to customize their zig location.

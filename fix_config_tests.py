#!/usr/bin/env python3
"""Fix config tests to use temporary directories"""

import re

with open('/Users/asil/.openclaw/workspace/nullclaw/src/config.zig', 'r') as f:
    content = f.read()

# Pattern 1: Tests starting with const tmp_path = "/tmp/..."
# Need to:
# 1. Add var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
# 2. Add const base = try tmp.dir.realPathFileAlloc(...)
# 3. Change tmp_path to use base
# 4. Change workspace_dir to use base
# 5. Remove defer deleteFile statements

# Find tests that need fixing
tests_to_fix = [
    "save includes dm_relays in nostr section",
    "dm_relays round-trips through save and load",
    "nostr display_name with special chars round-trips correctly"
]

for test_name in tests_to_fix:
    # Find the test
    pattern = rf'(test "{re.escape(test_name)}" \{{\s*const allocator = std\.testing\.allocator;)\s*const tmp_path = "/tmp/[^"]+";'
    
    replacement = r'''\1
    var tmp = std.testing.tmpDir(.{{}});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base.ptr[0 .. base.len + 1]);
    const tmp_path = try std.fs.path.join(allocator, &.{{ base.ptr[0..base.len], "config.json" }});
    defer allocator.free(tmp_path);'''
    
    content = re.sub(pattern, replacement, content)
    
    # Change workspace_dir from "/tmp" to base
    content = re.sub(
        rf'(test "{re.escape(test_name)}".*?\.workspace_dir = )"/tmp"(,)',
        r'\1base.ptr[0..base.len]\2',
        content,
        flags=re.DOTALL
    )
    
    # Remove defer deleteFile statements
    content = re.sub(
        r'defer std\.Io\.Dir\.cwd\(\)\.deleteFile\(std\.Options\.debug_io, tmp_path\) catch \{\{\};',
        '',
        content
    )

# Write back
with open('/Users/asil/.openclaw/workspace/nullclaw/src/config.zig', 'w') as f:
    f.write(content)

print("✅ Fixed config tests")

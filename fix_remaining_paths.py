#!/usr/bin/env python3
"""Fix remaining path issues in test files"""

import re

files_to_fix = [
    '/Users/asil/.openclaw/workspace/nullclaw/src/channel_loop.zig',
    '/Users/asil/.openclaw/workspace/nullclaw/src/channels/cli.zig'
]

for filepath in files_to_fix:
    with open(filepath, 'r') as f:
        content = f.read()

    # Replace the pattern
    content = content.replace(
        'const base = try std.testing.allocator.dupe(u8, ".");\n    defer allocator.free(base);',
        'const base = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);\n    defer std.testing.allocator.free(base.ptr[0 .. base.len + 1]);'
    )

    # Fix usages of base to base.ptr[0..base.len]
    content = re.sub(r'\{base\}', r'{base.ptr[0..base.len]}', content)
    content = re.sub(r', \{base,', r', {base.ptr[0..base.len],', content)

    with open(filepath, 'w') as f:
        f.write(content)

    print(f"✅ Fixed: {filepath}")

print("\n✅ All files fixed")

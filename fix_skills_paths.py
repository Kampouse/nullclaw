#!/usr/bin/env python3
"""Fix skills tests to use real paths"""

import re

with open('/Users/asil/.openclaw/workspace/nullclaw/src/skills.zig', 'r') as f:
    content = f.read()

# Count occurrences before
before_count = content.count('const base = try std.testing.allocator.dupe(u8, ".");')
print(f"Before: {before_count} occurrences of 'const base = try std.testing.allocator.dupe(u8, \".\")'")

# Pattern to match:
# const base = try std.testing.allocator.dupe(u8, ".");
# defer allocator.free(base);
# Replace with:
# const base = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
# defer std.testing.allocator.free(base.ptr[0 .. base.len + 1]);

content = content.replace(
    'const base = try std.testing.allocator.dupe(u8, ".");\n    defer allocator.free(base);',
    'const base = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);\n    defer std.testing.allocator.free(base.ptr[0 .. base.len + 1]);'
)

# Now need to change usages of 'base' to 'base.ptr[0..base.len]'
# This is tricky because base might be used in various contexts
# Let me handle the most common pattern: std.fs.path.join(allocator, &.{ base, ...

content = re.sub(
    r'std\.fs\.path\.join\(allocator, &\.\{ base,',
    r'std.fs.path.join(allocator, &.{ base.ptr[0..base.len],',
    content
)

# Count occurrences after
after_count = content.count('const base = try tmp.dir.realPathFileAlloc')
print(f"After: {after_count} occurrences of realPathFileAlloc")

# Write back
with open('/Users/asil/.openclaw/workspace/nullclaw/src/skills.zig', 'w') as f:
    f.write(content)

print("✅ Fixed skills tests")

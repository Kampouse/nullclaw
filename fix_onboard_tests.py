#!/usr/bin/env python3
"""Fix onboard tests to use real paths"""

import re

with open('/Users/asil/.openclaw/workspace/nullclaw/src/onboard.zig', 'r') as f:
    content = f.read()

# Find all tests that use: const base = try std.testing.allocator.dupe(u8, ".");
# Replace with: const base = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
# And add: defer std.testing.allocator.free(base.ptr[0 .. base.len + 1]);

# Also need to update usages of base to base.ptr[0..base.len]

# Pattern for scaffoldWorkspace tests
pattern = r'(test "scaffoldWorkspace[^"]*"\s*\{\s*var tmp = std\.testing\.tmpDir\(\.\{\}\);\s*defer tmp\.cleanup\(\);\s*)const base = try std\.testing\.allocator\.dupe\(u8, "\."\);(\s*defer std\.testing\.allocator\.free\(base\);)'

replacement = r'''\1const base = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base.ptr[0 .. base.len + 1]);'''

content = re.sub(pattern, replacement, content)

# Fix cache tests that use "."
pattern = r'(test "cache[^"]*"\s*\{\s*var tmp = std\.testing\.tmpDir\(\.\{\}\);\s*defer tmp\.cleanup\(\);\s*)const base = try std\.testing\.allocator\.dupe\(u8, "\."\);(\s*defer std\.testing\.allocator\.free\(base\);)'

content = re.sub(pattern, replacement, content)

# Now fix usages of base in function calls
# Pattern: scaffoldWorkspace(std.testing.allocator, base, -> scaffoldWorkspace(std.testing.allocator, base.ptr[0..base.len],
content = content.replace('scaffoldWorkspace(std.testing.allocator, base, &ProjectContext{})', 'scaffoldWorkspace(std.testing.allocator, base.ptr[0..base.len], &ProjectContext{})')

# Fix readWorkspaceOnboardingState(std.testing.allocator, base)
content = content.replace('readWorkspaceOnboardingState(std.testing.allocator, base)', 'readWorkspaceOnboardingState(std.testing.allocator, base.ptr[0..base.len])')

# Write back
with open('/Users/asil/.openclaw/workspace/nullclaw/src/onboard.zig', 'w') as f:
    f.write(content)

print("✅ Fixed onboard tests")

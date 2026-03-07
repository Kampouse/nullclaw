#!/usr/bin/env python3
"""Fix skills tests to use real path instead of "." """

import re

with open('/Users/asil/.openclaw/workspace/nullclaw/src/skills.zig', 'r') as f:
    content = f.read()

# Pattern: const base = try std.testing.allocator.dupe(u8, ".");
# Replace with: const base = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
# And add: defer std.testing.allocator.free(base.ptr[0 .. base.len + 1]);

# Also need to fix the usage to use base.ptr[0..base.len] instead of just base

# Find all test functions
tests = re.findall(r'(test ".*?" \{.*?^\})', content, re.MULTILINE | re.DOTALL)

print(f"Found {len(tests)} tests")

# For each test that uses tmp and base = "."
count = 0
for test_match in tests:
    if 'var tmp = std.testing.tmpDir' in test_match and 'const base = try std.testing.allocator.dupe(u8, ".")' in test_match:
        count += 1
        # Extract test name
        test_name = re.search(r'test "(.*?)"', test_match).group(1)
        print(f"  Test needs fix: {test_name}")

print(f"\nTotal tests needing fix: {count}")

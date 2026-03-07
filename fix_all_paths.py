#!/usr/bin/env python3
"""Fix all remaining tests using "." instead of real paths"""

import re
import os

def fix_file(filepath):
    """Fix all test instances in a single file"""
    with open(filepath, 'r') as f:
        content = f.read()

    original = content

    # Pattern 1: const base = try std.testing.allocator.dupe(u8, ".");
    # Replace with realPathFileAlloc pattern
    content = re.sub(
        r'const base = try std\.testing\.allocator\.dupe\(u8, "\."\);(\s+)defer std\.testing\.allocator\.free\(base\);',
        r'const base = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);\1defer std.testing.allocator.free(base.ptr[0 .. base.len + 1]);',
        content
    )

    # Fix usages of base in path joins and function calls
    # Pattern: std.fs.path.join(allocator, &.{ base, -> &.{ base.ptr[0..base.len],
    content = re.sub(
        r'std\.fs\.path\.join\(allocator, &\.\{ base,',
        r'std.fs.path.join(allocator, &.{ base.ptr[0..base.len],',
        content
    )

    # Pattern: some_function(allocator, base, -> some_function(allocator, base.ptr[0..base.len],
    # But only for certain functions that expect paths
    functions = [
        'scaffoldWorkspace', 'readWorkspaceOnboardingState', 'writeWorkspaceOnboardingState',
        'loadSkill', 'listSkills', 'installSkill', 'removeSkill',
        'writeStateFile', 'loadScheduler', 'saveScheduler',
        'loadConfig', 'saveConfig'
    ]

    for func in functions:
        # Pattern: func(allocator, base, -> func(allocator, base.ptr[0..base.len],
        content = re.sub(
            rf'{func}\(allocator, base,',
            rf'{func}(allocator, base.ptr[0..base.len],',
            content
        )
        # Pattern: func(allocator, base) -> func(allocator, base.ptr[0..base.len])
        content = re.sub(
            rf'{func}\(allocator, base\)',
            rf'{func}(allocator, base.ptr[0..base.len])',
            content
        )

    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        return True
    return False

def main():
    src_dir = '/Users/asil/.openclaw/workspace/nullclaw/src'

    fixed_count = 0
    for root, dirs, files in os.walk(src_dir):
        for file in files:
            if file.endswith('.zig'):
                filepath = os.path.join(root, file)
                if fix_file(filepath):
                    print(f"✅ Fixed: {filepath}")
                    fixed_count += 1

    print(f"\n✅ Total files fixed: {fixed_count}")

if __name__ == '__main__':
    main()

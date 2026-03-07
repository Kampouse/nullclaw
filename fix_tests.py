#!/usr/bin/env python3
"""Fix test code to use ToolResult.deinit() instead of manual free"""

import os
import re
import sys

def fix_file(filepath):
    """Fix test defer statements in a single file"""
    with open(filepath, 'r') as f:
        content = f.read()
    
    original = content
    
    # Fix defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    # Fix defer if (result.error_msg) |e| std.testing.allocator.free(e);
    # Replace with: defer result.deinit(std.testing.allocator);
    
    # Pattern 1: Both output and error_msg frees
    content = re.sub(
        r'defer if \(result\.output\.len > 0\) std\.testing\.allocator\.free\(result\.output\);\s*defer if \(result\.error_msg\) \|e\| std\.testing\.allocator\.free\(e\);',
        r'defer result.deinit(std.testing.allocator);',
        content
    )
    
    # Pattern 2: Error msg only
    content = re.sub(
        r'defer if \(result\.error_msg\) \|e\| std\.testing\.allocator\.free\(e\);',
        r'defer result.deinit(std.testing.allocator);',
        content
    )
    
    # Pattern 3: Output only
    content = re.sub(
        r'defer if \(result\.output\.len > 0\) std\.testing\.allocator\.free\(result\.output\);',
        r'defer result.deinit(std.testing.allocator);',
        content
    )
    
    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        return True
    return False

def main():
    src_dir = sys.argv[1] if len(sys.argv) > 1 else '.'
    
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

#!/usr/bin/env python3
"""Fix ToolResult initialization to track ownership"""

import os
import re
import sys

def fix_file(filepath):
    """Fix ToolResult initialization in a single file"""
    with open(filepath, 'r') as f:
        content = f.read()
    
    original = content
    
    # Fix ToolResult{ .success = false, .output = "", .error_msg = msg }
    # Add .owns_error_msg = true
    content = re.sub(
        r'(return ToolResult\{ \.success = false, \.output = "", \.error_msg = )([^,}]+)( \})',
        r'\1\2, .owns_error_msg = true\3',
        content
    )
    
    # Fix ToolResult{ .success = true, .output = msg, .error_msg = null }
    # Add .owns_output = true
    content = re.sub(
        r'(return ToolResult\{ \.success = true, \.output = )([^,]+)(, \.error_msg = null \})',
        r'\1\2, .owns_output = true\3',
        content
    )
    
    # Fix ToolResult{ .success = true, .output = msg }
    # Add .owns_output = true
    content = re.sub(
        r'(return ToolResult\{ \.success = true, \.output = )([^,}]+)( \})',
        r'\1\2, .owns_output = true\3',
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

#!/usr/bin/env python3
"""Fix Zig 0.16 API changes in NullClaw source files"""

import os
import re
import sys

def fix_file(filepath):
    """Fix Zig 0.16 API in a single file"""
    with open(filepath, 'r') as f:
        content = f.read()
    
    original = content
    
    # Fix openFileAbsolute with std.Options.debug_io
    content = re.sub(
        r'std\.Io\.Dir\.openFileAbsolute\(std\.Options\.debug_io,\s*([^,]+),\s*\.{\s*}\)',
        r'std.Io.Dir.cwd().openFile(std.Options.debug_io, \1, .{})',
        content
    )
    
    # Fix openFileAbsolute with io parameter
    content = re.sub(
        r'std\.Io\.Dir\.openFileAbsolute\(io,\s*([^,]+),\s*\.{\s*}\)',
        r'std.Io.Dir.cwd().openFile(io, \1, .{})',
        content
    )
    
    # Fix createFileAbsolute with std.Options.debug_io
    content = re.sub(
        r'std\.Io\.Dir\.createFileAbsolute\(std\.Options\.debug_io,\s*([^,]+),\s*\.{\s*([^}]*)}\)',
        r'std.Io.Dir.cwd().createFile(std.Options.debug_io, \1, .{\2})',
        content
    )
    
    # Fix createFileAbsolute with io parameter
    content = re.sub(
        r'std\.Io\.Dir\.createFileAbsolute\(io,\s*([^,]+),\s*\.{\s*([^}]*)}\)',
        r'std.Io.Dir.cwd().createFile(io, \1, .{\2})',
        content
    )
    
    # Fix deleteFileAbsolute with std.Options.debug_io
    content = re.sub(
        r'std\.Io\.Dir\.deleteFileAbsolute\(std\.Options\.debug_io,\s*([^)]+)\)',
        r'std.Io.Dir.cwd().deleteFile(std.Options.debug_io, \1)',
        content
    )
    
    # Fix std.fs.openFileAbsolute (deprecated)
    content = re.sub(
        r'std\.fs\.openFileAbsolute\(([^,]+),\s*\.{\s*([^}]*)}\)',
        r'std.Io.Dir.cwd().openFile(std.Options.debug_io, \1, .{\2})',
        content
    )
    
    # Fix std.fs.createFileAbsolute (deprecated)
    content = re.sub(
        r'std\.fs\.createFileAbsolute\(([^,]+),\s*\.{\s*([^}]*)}\)',
        r'std.Io.Dir.cwd().createFile(std.Options.debug_io, \1, .{\2})',
        content
    )
    
    # Fix createDirAbsolute
    content = re.sub(
        r'std\.Io\.Dir\.createDirAbsolute\(std\.Options\.debug_io,\s*([^,]+),\s*\.default_dir\)',
        r'std.Io.Dir.cwd().createDirPath(std.Options.debug_io, \1)',
        content
    )
    
    # Fix makeDir calls (changed to createDirPath in Zig 0.16)
    content = re.sub(
        r'std\.Io\.Dir\.cwd\(\)\.makeDir\(std\.Options\.debug_io,\s*([^,]+),\s*\.default_dir\)',
        r'std.Io.Dir.cwd().createDirPath(std.Options.debug_io, \1)',
        content
    )
    
    # Fix deleteDirAbsolute
    content = re.sub(
        r'std\.Io\.Dir\.deleteDirAbsolute\(std\.Options\.debug_io,\s*([^)]+)\)',
        r'std.Io.Dir.cwd().deleteDir(std.Options.debug_io, \1)',
        content
    )
    
    # Fix renameAbsolute
    content = re.sub(
        r'std\.Io\.Dir\.renameAbsolute\(([^,]+),\s*([^,]+),\s*std\.Options\.debug_io\)',
        r'std.Io.Dir.cwd().rename(\1, std.Io.Dir.cwd(), \2, std.Options.debug_io)',
        content
    )
    
    # Fix incorrect cwd().rename() calls (3 args -> 4 args)
    content = re.sub(
        r'std\.Io\.Dir\.cwd\(\)\.rename\(std\.Options\.debug_io,\s*([^,]+),\s*([^)]+)\)',
        r'std.Io.Dir.cwd().rename(\1, std.Io.Dir.cwd(), \2, std.Options.debug_io)',
        content
    )
    
    # Fix accessAbsolute
    content = re.sub(
        r'std\.Io\.Dir\.accessAbsolute\(io,\s*([^,]+),\s*\.{\s*([^}]*)}\)',
        r'std.Io.Dir.cwd().access(io, \1, .{\2})',
        content
    )
    
    # Fix statFileAbsolute
    content = re.sub(
        r'std\.Io\.Dir\.statFileAbsolute\(io,\s*([^)]+)\)',
        r'std.Io.Dir.cwd().statFile(io, \1)',
        content
    )
    
    # Fix openDirAbsolute
    content = re.sub(
        r'std\.Io\.Dir\.openDirAbsolute\(io,\s*([^,]+),\s*\.{\s*([^}]*)}\)',
        r'std.Io.Dir.cwd().openDir(io, \1, .{\2})',
        content
    )
    
    # Fix std.fs.deleteFileAbsolute (deprecated)
    content = re.sub(
        r'std\.fs\.deleteFileAbsolute\(([^)]+)\)',
        r'std.Io.Dir.cwd().deleteFile(std.Options.debug_io, \1)',
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

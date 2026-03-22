#!/usr/bin/env python3
import sys
import re

def add_util_import(filename):
    with open(filename, 'r') as f:
        content = f.read()
    
    # Check if util import already exists
    if 'const util = @import' in content:
        print(f"{filename}: already has util import")
        return
    
    # Determine the import path based on file location
    if '/channels/' in filename:
        import_path = '../util.zig'
    elif '/security/' in filename:
        import_path = '../util.zig'
    else:
        import_path = 'util.zig'
    
    # Find the last import statement
    lines = content.split('\n')
    last_import_idx = 0
    for i, line in enumerate(lines):
        if line.startswith('const ') and '@import' in line:
            last_import_idx = i
    
    # Insert util import after the last import
    util_line = f'const util = @import("{import_path}");'
    lines.insert(last_import_idx + 1, util_line)
    
    with open(filename, 'w') as f:
        f.write('\n'.join(lines))
    
    print(f"{filename}: added util import")

if __name__ == '__main__':
    for filename in sys.argv[1:]:
        try:
            add_util_import(filename)
        except Exception as e:
            print(f"{filename}: ERROR - {e}")

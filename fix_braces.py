#!/usr/bin/env python3
"""Fix double braces in config tests"""

with open('/Users/asil/.openclaw/workspace/nullclaw/src/config.zig', 'r') as f:
    content = f.read()

# Fix double braces
content = content.replace('.tmpDir(.{{}})', '.tmpDir(.{})')
content = content.replace('&.{{ base.ptr[0..base.len], "config.json" }}', '&.{ base.ptr[0..base.len], "config.json" }')

with open('/Users/asil/.openclaw/workspace/nullclaw/src/config.zig', 'w') as f:
    f.write(content)

print("✅ Fixed double braces")

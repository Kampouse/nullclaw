# Tool Development Quick Reference

## 🎯 Essential Components

```zig
pub const MyTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},

    pub const tool_name = "my_tool";
    pub const tool_description = "Description";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{...},\"required\":[...]}";

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MyTool) Tool { /* ... */ }
    pub fn execute(self: *MyTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult { /* ... */ }
};
```

## 🔐 Memory Safety Cheat Sheet

| Pattern | Code | Safety |
|---------|------|--------|
| **Transfer ownership** | `return ToolResult{ .owns_output = true };` | ✅ Safe |
| **Borrowed data** | `return ToolResult{ .owns_output = false };` | ⚠️ Static only |
| **Cleanup with defer** | `defer allocator.free(temp);` | ✅ Safe |
| **Error path cleanup** | `defer allocator.free(error_data);` | ✅ Safe |
| **Stack buffer** | `var buffer: [1024]u8 = undefined;` | ✅ Safe |
| **Leak** | `const data = allocator.dupe(...);` (no free) | ❌ Unsafe |

## 📋 Parameter Extraction

```zig
// Required string parameter
const param1 = root.getString(args, "param1") orelse
    return ToolResult.fail("Missing 'param1' parameter");

// Optional string parameter
const param2 = root.getString(args, "param2") orelse "default_value";

// Boolean parameter
const flag = root.getBool(args, "flag") orelse false;

// Integer parameter
const count = root.getInt(args, "count") orelse 1;
```

## 🧪 Standard Tests

```zig
test "my_tool tool name" {
    var mt = MyTool{ .workspace_dir = "/tmp" };
    const t = mt.tool();
    try std.testing.expectEqualStrings("my_tool", t.name());
}

test "my_tool executes successfully" {
    var mt = MyTool{ .workspace_dir = "/tmp" };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"param1\": \"value\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
}

test "my_tool handles missing parameters" {
    var mt = MyTool{ .workspace_dir = "/tmp" };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
}
```

## 🔧 Registration Checklist

- [ ] `src/tools/root.zig`: Add import `pub const my_tool = @import("my_tool.zig");`
- [ ] `src/tools/root.zig`: Add instance in `allTools()`
- [ ] `src/capabilities.zig`: Add to `core_tool_names`
- [ ] Test: `zig build test -Dtest-file=tools/my_tool`
- [ ] Integration test: `zig build test -Dtest-file=tools`

## 🚨 Common Pitfalls

| Issue | Symptom | Fix |
|-------|---------|-----|
| **Memory leak** | Tests pass but memory grows | Add `defer allocator.free()` for all allocations |
| **Use after free** | Random crashes | Don't return stack buffers, use `allocator.dupe()` |
| **Missing registration** | Tool not found | Check all three registration locations |
| **Schema error** | Agent can't parse parameters | Validate JSON schema format |
| **Path traversal** | Security vulnerability | Use `path_security.resolvePathAlloc()` |

## 💡 Pro Tips

1. **Always use defer** for cleanup - it works even in error paths
2. **Set owns_output=true** when you've allocated new memory for the result
3. **Test with GeneralPurposeAllocator** to detect leaks
4. **Copy existing tools** as templates rather than starting from scratch
5. **Use page_allocator** for temporary, small allocations
6. **Test error paths** as thoroughly as success paths

## 📁 File Structure

```
src/tools/
├── root.zig           # Tool interface and registry
├── my_tool.zig        # Your new tool implementation
└── my_tool.test.zig   # Optional: separate test file

src/
├── capabilities.zig   # Tool capability declarations
└── ...
```

## 🧪 Testing Commands

```bash
# Test single tool
zig build test -Dtest-file=tools/my_tool --summary all

# Test all tools
zig build test -Dtest-file=tools --summary all

# Memory leak detection
zig build test -Dtest-file=tools/my_tool -freference-trace
```

## 🎨 JSON Schema Template

```json
{
  "type": "object",
  "properties": {
    "required_param": {
      "type": "string",
      "description": "Description of required parameter"
    },
    "optional_param": {
      "type": "boolean",
      "description": "Description of optional parameter"
    },
    "param_with_default": {
      "type": "integer",
      "description": "Parameter with default value",
      "default": 42
    }
  },
  "required": ["required_param"]
}
```

## 🔍 Debugging

```zig
// Enable debug output
const debug = root.getBool(args, "debug") orelse false;
if (debug) {
    std.debug.print("Debug: processing {s}\n", .{param1});
}

// Trace execution
std.debug.print("Executing tool: {s} with args: {any}\n", .{tool_name, args});
```

---

**Need help?** Check `docs/TOOL_DEVELOPMENT_GUIDE.md` for comprehensive guide!
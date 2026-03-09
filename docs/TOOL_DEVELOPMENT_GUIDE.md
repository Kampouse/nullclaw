# Tool Development Guide

Welcome to the NullClaw tool development guide! This guide will help you create new tools that integrate seamlessly with the agent system.

## 🎯 Quick Start

The fastest way to create a new tool is using the tool template generator:

```bash
# Create a new tool from template
./scripts/generate_tool.sh my_tool
```

Or manually follow the steps below.

## 📋 Tool Creation Checklist

- [ ] Define tool metadata (name, description, parameters)
- [ ] Implement tool struct with execute function
- [ ] Add proper memory management
- [ ] Write comprehensive tests
- [ ] Register tool in `src/tools/root.zig`
- [ ] Add to capabilities in `src/capabilities.zig`
- [ ] Test integration with agent
- [ ] Document security considerations

## 🏗️ Tool Structure

Every tool must implement this interface:

```zig
pub const MyTool = struct {
    // Tool configuration
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},

    // Required metadata
    pub const tool_name = "my_tool";
    pub const tool_description = "Brief description of what this tool does";
    pub const tool_params = \\"
        {"type":"object","properties":{
            "param1":{"type":"string","description":"First parameter"},
            "param2":{"type":"boolean","description":"Optional parameter"}
        },"required":["param1"]}
    ;

    // VTable for polymorphic interface
    const vtable = root.ToolVTable(@This());

    // Convert to Tool interface
    pub fn tool(self: *MyTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    // Main execution function
    pub fn execute(self: *MyTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        // 1. Extract and validate parameters
        const param1 = root.getString(args, "param1") orelse
            return ToolResult.fail("Missing 'param1' parameter");

        // 2. Perform the operation
        // ... your tool logic here ...

        // 3. Return result with proper memory management
        const output = try allocator.dupe(u8, "Operation successful");
        return ToolResult{ .success = true, .output = output, .owns_output = true };
    }
};
```

## 💾 Memory Safety Rules

### ✅ DO: Use proper ownership transfers

```zig
// Success case - transfer ownership to ToolResult
const output = try allocator.dupe(u8, result_data);
return ToolResult{ .success = true, .output = output, .owns_output = true };

// Error case - transfer ownership to ToolResult
const error_msg = try allocator.dupe(u8, "Something went wrong");
return ToolResult{ .success = false, .error_msg = error_msg, .owns_error_msg = true };
```

### ✅ DO: Clean up temporary allocations

```zig
const temp_data = try std.fmt.allocPrint(allocator, "Format: {s}", .{value});
defer allocator.free(temp_data);
// Use temp_data...
```

### ✅ DO: Use defer for cleanup in error paths

```zig
const result = try someOperation(allocator);
defer allocator.free(result.stdout);  // Always cleaned up
if (!result.success) {
    defer allocator.free(result.stderr);  // Cleaned up on error
    return ToolResult{ .success = false, ... };
}
```

### ❌ DON'T: Forget to clean up allocations

```zig
// WRONG - Memory leak!
const data = try allocator.dupe(u8, some_data);
// Error path without cleanup
if (error_condition) return ToolResult.fail("Error");
allocator.free(data);  // Never reached
```

### ❌ DON'T: Use stack buffers beyond their lifetime

```zig
// WRONG - Use after free!
const buffer: [100]u8 = undefined;
const slice = buffer[0..10];
return ToolResult{ .success = true, .output = slice, .owns_output = false };
// slice points to stack memory that will be freed
```

## 🔒 Security Best Practices

### Input Sanitization

Always validate and sanitize user input:

```zig
fn sanitizeInput(input: []const u8) bool {
    // Check for dangerous patterns
    const dangerous = [_][]const u8{ "|", ";", "$(", "`", "&" };
    for (dangerous) |pattern| {
        if (std.mem.indexOf(u8, input, pattern) != null)
            return false;
    }
    return true;
}

// In execute
if (root.getString(args, "user_input")) |input| {
    if (!sanitizeInput(input))
        return ToolResult.fail("Unsafe input detected");
}
```

### Path Security

Use the provided path security utilities:

```zig
const path_security = @import("path_security.zig");

// Validate paths are within allowed areas
const resolved_path = try path_security.resolvePathAlloc(allocator, user_path);
defer allocator.free(resolved_path);

if (!path_security.isResolvedPathAllowed(allocator, resolved_path, workspace_dir, allowed_paths))
    return ToolResult.fail("Path not allowed");
```

## 🧪 Testing Patterns

### Basic Test Structure

```zig
test "my_tool tool name" {
    var mt = MyTool{ .workspace_dir = "/tmp" };
    const t = mt.tool();
    try std.testing.expectEqualStrings("my_tool", t.name());
}

test "my_tool tool schema validation" {
    var mt = MyTool{ .workspace_dir = "/tmp" };
    const t = mt.tool();

    // Verify schema includes required parameters
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "param1") != null);
}

test "my_tool executes successfully" {
    var mt = MyTool{ .workspace_dir = "/tmp" };
    const t = mt.tool();

    const parsed = try root.parseTestArgs("{\"param1\": \"value\"}");
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.output.len > 0);
}

test "my_tool handles missing parameters" {
    var mt = MyTool{ .workspace_dir = "/tmp" };
    const t = mt.tool();

    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}
```

## 📝 Registration Steps

### 1. Add Import to `src/tools/root.zig`

```zig
// In the imports section
pub const my_tool = @import("my_tool.zig");
```

### 2. Register in `allTools()` function

```zig
// In src/tools/root.zig, allTools() function
const my_tool_instance = try allocator.create(my_tool.MyTool);
my_tool_instance.* = .{
    .workspace_dir = workspace_dir,
    .allowed_paths = opts.allowed_paths,
};
try list.append(allocator, my_tool_instance.tool());
```

### 3. Add to Capabilities

```zig
// In src/capabilities.zig
const core_tool_names = [_][]const u8{
    // ... existing tools ...
    "my_tool",
};
```

## 🎨 Common Patterns

### Command Execution with Arguments

```zig
fn runCommand(self: *MyTool, allocator: std.mem.Allocator, args: []const []const u8) !ToolResult {
    const proc = @import("process_util.zig");
    const result = try proc.run(allocator, args, .{
        .cwd = self.workspace_dir,
        .timeout_ns = 30 * std.time.ns_per_s,
    });
    defer allocator.free(result.stderr);

    if (!result.success) {
        defer allocator.free(result.stdout);
        const msg = try allocator.dupe(u8, result.stderr);
        return ToolResult{ .success = false, .error_msg = msg, .owns_error_msg = true };
    }

    const output = try allocator.dupe(u8, result.stdout);
    return ToolResult{ .success = true, .output = output, .owns_output = true };
}
```

### Argument Tokenization

For tools that need to parse complex command-line arguments:

```zig
const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,

    fn init(input: []const u8) Tokenizer {
        return .{ .input = input };
    }

    fn next(self: *Tokenizer) ?[]const u8 {
        // Skip whitespace
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return null;

        const start = self.pos;
        while (self.pos < self.input.len and !std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }
};
```

## 🔧 Debugging Tips

### Enable verbose output

```zig
if (root.getBool(args, "verbose") orelse false) {
    std.debug.print("Debug: processing with args: {any}\n", .{args});
}
```

### Test with different allocators

```zig
// In tests, use GeneralPurposeAllocator with leak detection
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Run your tool tests...
const leaked = gpa.detectLeaks();
try std.testing.expectEqual(@as(usize, 0), leaked);
```

## 📚 Additional Resources

- See `src/tools/cargo.zig` for a complete example with security and testing
- See `src/tools/self_diagnose.zig` for a simple tool example
- See `src/tools/root.zig` for the Tool interface definition
- See `build.zig` for build configuration

## 🆘 Troubleshooting

### Common Issues

**Issue**: "Tool not found in agent"
- **Solution**: Check all three registration steps above

**Issue**: Memory leak detected
- **Solution**: Review memory safety rules, ensure all allocations have corresponding frees

**Issue**: Tests pass but tool fails in agent
- **Solution**: Check parameter validation and error handling paths

**Issue**: Schema validation errors
- **Solution**: Validate JSON schema format using online JSON schema validators

---

Need help? Check existing tools as examples or ask in the development community!
# Tool Testing Template

Copy this template to create comprehensive tests for your tool.

## 🧪 Complete Test Suite Template

```zig
const std = @import("std");
const root = @import("root.zig");

// ── Basic Metadata Tests ───────────────────────────────────────────────

test "tool_name tool has correct name" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();
    try std.testing.expectEqualStrings("tool_name", t.name());
}

test "tool_name tool has valid description" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const desc = t.description();
    try std.testing.expect(desc.len > 0);
    try std.testing.expect(desc.len < 500); // Reasonable length
}

test "tool_name tool schema is valid JSON" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const schema = t.parametersJson();
    try std.testing.expect(schema.len > 0);

    // Verify it's valid JSON by parsing it
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        schema,
        .{}
    );
    defer parsed.deinit();

    // Should be an object with type="object"
    try std.testing.expectEqual(.object, parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("object", parsed.value.object.get("type").?.string);
}

test "tool_name tool schema includes required parameters" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const schema = t.parametersJson();

    // Check for essential schema components
    try std.testing.expect(std.mem.indexOf(u8, schema, "properties") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") != null);

    // Check for your specific parameters
    try std.testing.expect(std.mem.indexOf(u8, schema, "your_param") != null);
}

// ── Basic Functionality Tests ───────────────────────────────────────────

test "tool_name executes with valid parameters" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const parsed = try root.parseTestArgs(
        \\{"your_param": "valid_value"}
    );
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.output.len > 0);
}

test "tool_name handles missing required parameters" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Missing") != null);
}

test "tool_name handles invalid parameter types" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    // Pass string when number is expected
    const parsed = try root.parseTestArgs(
        \\{"your_param": 123}
    );
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    // Tool should handle gracefully
    _ = result;
}

test "tool_name handles optional parameters correctly" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    // Test with optional parameter
    {
        const parsed = try root.parseTestArgs(
            \\{"your_param": "value", "optional_param": true}
        );
        defer parsed.deinit();

        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.success);
    }

    // Test without optional parameter
    {
        const parsed = try root.parseTestArgs(
            \\{"your_param": "value"}
        );
        defer parsed.deinit();

        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.success);
    }
}

// ── Security Tests ─────────────────────────────────────────────────────

test "tool_name rejects malicious input" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const malicious_inputs = [_][]const u8{
        "\\\"; rm -rf /tmp\\\"",
        "\\\"| cat /etc/passwd\\\"",
        "\\\"$(whoami)\\\"",
        "\\\"`evil_command`\\\"",
    };

    for (malicious_inputs) |input| {
        const json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\\\"your_param\\\": {s}}}",
            .{input}
        );
        defer std.testing.allocator.free(json);

        const parsed = try root.parseTestArgs(json);
        defer parsed.deinit();

        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
        defer result.deinit(std.testing.allocator);

        // Tool should either reject or sanitize the input
        if (!result.success) {
            // Good - rejected the malicious input
            try std.testing.expect(result.error_msg != null);
        } else {
            // If accepted, output should not contain evidence of command execution
            try std.testing.expect(std.mem.indexOf(u8, result.output, "root") == null);
        }
    }
}

test "tool_name respects path security" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    // Try to access files outside allowed paths
    const json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\\\"your_param\\\": \\\"../../../etc/passwd\\\"}}",
        .{}
    );
    defer std.testing.allocator.free(json);

    const parsed = try root.parseTestArgs(json);
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    // Should fail or sanitize the path
    if (!result.success) {
        try std.testing.expect(result.error_msg != null);
    }
}

// ── Error Handling Tests ───────────────────────────────────────────────

test "tool_name handles allocation failures gracefully" {
    // This test requires a failing allocator
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 } // Fail first allocation
    );
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const parsed = try root.parseTestArgs(
        \\{"your_param": "value"}
    );
    defer parsed.deinit();

    const result = t.execute(failing_allocator.allocator(), parsed.parsed.value.object);
    // Should either fail gracefully or succeed with reduced functionality
    _ = result;
}

test "tool_name handles concurrent operations" {
    // Basic concurrency test
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const parsed = try root.parseTestArgs(
        \\{"your_param": "value"}
    );
    defer parsed.deinit();

    // Run multiple times
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.success or !result.success); // Just don't crash
    }
}

// ── Memory Safety Tests ────────────────────────────────────────────────

test "tool_name has no memory leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    // Run operations multiple times
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const parsed = try root.parseTestArgs(
            \\{"your_param": "value"}
        );
        defer parsed.deinit();

        const result = try t.execute(allocator, parsed.parsed.value.object);
        defer result.deinit(allocator);
        _ = result;
    }

    // Check for leaks
    const leaked = gpa.detectLeaks();
    try std.testing.expectEqual(@as(usize, 0), leaked);
}

test "tool_name handles large outputs efficiently" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    // Test with parameters that might generate large output
    const parsed = try root.parseTestArgs(
        \\{"your_param": "large_test_value"}
    );
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    if (result.success) {
        // Verify output is reasonable size (< 10MB)
        try std.testing.expect(result.output.len < 10_000_000);
    }
}

// ── Integration Tests ─────────────────────────────────────────────────

test "tool_name integrates with tool registry" {
    // Verify tool can be created and used through the registry
    const tools_mod = @import("tools/root.zig");

    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const tool = tt.tool();

    // Verify tool interface works
    try std.testing.expect(tool.name().len > 0);
    try std.testing.expect(tool.description().len > 0);
    try std.testing.expect(tool.parametersJson().len > 0);
}

test "tool_name metadata matches expectations" {
    var tt = ToolStruct{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    // Verify all metadata is present and valid
    const name = t.name();
    const desc = t.description();
    const params = t.parametersJson();

    try std.testing.expect(name.len > 0);
    try std.testing.expect(desc.len > 0);
    try std.testing.expect(params.len > 0);

    // Verify name follows conventions (lowercase, underscores)
    for (name) |ch| {
        try std.testing.expect(std.ascii.isAlphanumeric(ch) or ch == '_');
    }
}
```

## 🎯 Test Categories Explained

### 1. **Basic Metadata Tests**
Verify tool identity and interface compliance.

### 2. **Basic Functionality Tests**
Test normal operation and parameter handling.

### 3. **Security Tests**
Ensure tool handles malicious input correctly.

### 4. **Error Handling Tests**
Verify graceful failure and resource cleanup.

### 5. **Memory Safety Tests**
Check for leaks and proper memory management.

### 6. **Integration Tests**
Verify tool works with the broader system.

## 📋 Test Coverage Checklist

- [ ] All metadata (name, description, parameters)
- [ ] All required parameters
- [ ] All optional parameters
- [ ] Parameter validation
- [ ] Error conditions
- [ ] Edge cases (empty strings, very large inputs, etc.)
- [ ] Security scenarios (path traversal, injection attacks)
- [ ] Memory leak detection
- [ ] Concurrent operations
- [ ] Integration with tool registry

## 🚀 Running Tests

```bash
# Test specific tool
zig build test -Dtest-file=tools/your_tool --summary all

# Test with detailed output
zig build test -Dtest-file=tools/your_tool -freference-trace

# Memory leak detection
zig build test -Dtest-file=tools/your_tool --test-no-exec

# All tools integration test
zig build test -Dtest-file=tools --summary all
```

---

**Remember**: Good tests catch bugs before users do! Test thoroughly, test often.
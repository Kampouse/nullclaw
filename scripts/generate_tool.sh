#!/usr/bin/env bash
# Tool Template Generator for NullClaw
# Usage: ./generate_tool.sh <tool_name> [description]

set -e

TOOL_NAME="${1:-my_tool}"
DESCRIPTION="${2:-A brief description of the tool}"
SAFE_NAME=$(echo "$TOOL_NAME" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g' | sed 's/^\([0-9]\)/_\1/')

echo "🔧 Generating tool template for: $TOOL_NAME"
echo "📝 Description: $DESCRIPTION"
echo ""

# Create the tool file
TOOL_FILE="src/tools/${TOOL_NAME}.zig"

cat > "$TOOL_FILE" << 'EOF'
const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const path_security = @import("path_security.zig");
const UNAVAILABLE_WORKSPACE_SENTINEL = "/__nullclaw_workspace_unavailable__";

/// TOOL_DESCRIPTION_PLACEHOLDER
pub const TOOL_STRUCT_PLACEHOLDER = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},

    pub const tool_name = "TOOL_NAME_PLACEHOLDER";
    pub const tool_description = "TOOL_DESCRIPTION_PLACEHOLDER";
    pub const tool_params =
        \\{"type":"object","properties":{"param1":{"type":"string","description":"First parameter"},"param2":{"type":"boolean","description":"Optional parameter"}},"required":["param1"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *TOOL_STRUCT_PLACEHOLDER) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *TOOL_STRUCT_PLACEHOLDER, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        // 1. Extract and validate required parameters
        const param1 = root.getString(args, "param1") orelse
            return ToolResult.fail("Missing 'param1' parameter");

        // 2. Extract optional parameters
        const param2 = root.getBool(args, "param2") orelse false;

        // 3. Perform the tool's main operation
        // TODO: Implement your tool logic here
        const result = try self.performOperation(allocator, param1, param2);

        // 4. Return result with proper memory management
        return result;
    }

    fn performOperation(self: *TOOL_STRUCT_PLACEHOLDER, allocator: std.mem.Allocator, param1: []const u8, param2: bool) !ToolResult {
        _ = self;
        _ = param2;

        // Example operation - replace with your actual logic
        const output = try std.fmt.allocPrint(allocator, "Processed: {s}", .{param1});

        // Transfer ownership to ToolResult
        return ToolResult{
            .success = true,
            .output = output,
            .owns_output = true,
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "tool_name tool name" {
    var tt = TOOL_STRUCT_PLACEHOLDER{ .workspace_dir = "/tmp" };
    const t = tt.tool();
    try std.testing.expectEqualStrings("TOOL_NAME_PLACEHOLDER", t.name());
}

test "tool_name tool schema has required params" {
    var tt = TOOL_STRUCT_PLACEHOLDER{ .workspace_dir = "/tmp" };
    const t = tt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "param1") != null);
}

test "tool_name executes successfully" {
    var tt = TOOL_STRUCT_PLACEHOLDER{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const parsed = try root.parseTestArgs("{\"param1\": \"test_value\"}");
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.output.len > 0);
}

test "tool_name handles missing parameters" {
    var tt = TOOL_STRUCT_PLACEHOLDER{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.parsed.value.object);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "tool_name tool metadata" {
    var tt = TOOL_STRUCT_PLACEHOLDER{ .workspace_dir = "/tmp" };
    const t = tt.tool();

    try std.testing.expectEqualStrings("TOOL_NAME_PLACEHOLDER", t.name());

    const desc = t.description();
    try std.testing.expect(desc.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, desc, "TOOL_DESCRIPTION_PLACEHOLDER") != null);
}
EOF

# Replace placeholders
sed -i '' "s/TOOL_NAME_PLACEHOLDER/$TOOL_NAME/g" "$TOOL_FILE"
sed -i '' "s/TOOL_DESCRIPTION_PLACEHOLDER/$DESCRIPTION/g" "$TOOL_FILE"
sed -i '' "s/TOOL_STRUCT_PLACEHOLDER/$SAFE_NAME/g" "$TOOL_FILE"

echo "✅ Created tool file: $TOOL_FILE"

# Create registration instructions
REGISTRATION_FILE="scripts/${TOOL_NAME}_registration.txt"

cat > "$REGISTRATION_FILE" << EOF
# Registration Instructions for $TOOL_NAME

## 1. Add import to src/tools/root.zig

Add this line to the imports section (around line 80):

pub const $TOOL_NAME = @import("$TOOL_NAME.zig");

## 2. Add to allTools() function in src/tools/root.zig

Add this code to the allTools() function (after the zig_build tool registration):

const ${TOOL_NAME}_tool = try allocator.create($TOOL_NAME.$SAFE_NAME);
${TOOL_NAME}_tool.* = .{ .workspace_dir = workspace_dir, .allowed_paths = opts.allowed_paths };
try list.append(allocator, ${TOOL_NAME}_tool.tool());

## 3. Add to capabilities in src/capabilities.zig

Add "$TOOL_NAME" to the core_tool_names array (around line 17):

const core_tool_names = [_][]const u8{
    // ... existing tools ...
    "$TOOL_NAME",
};

## 4. Test the tool

zig build test -Dtest-file=tools/$TOOL_NAME --summary all

## 5. Integration test

zig build test -Dtest-file=tools --summary all

---

## Tool Details

- **Name**: $TOOL_NAME
- **Description**: $DESCRIPTION
- **Struct**: $SAFE_NAME
- **File**: $TOOL_FILE

Happy tool building! 🎉
EOF

echo "📋 Created registration instructions: $REGISTRATION_FILE"
echo ""
echo "🚀 Tool template generated successfully!"
echo ""
echo "Next steps:"
echo "  1. Edit $TOOL_FILE to implement your tool logic"
echo "  2. Follow the registration instructions in $REGISTRATION_FILE"
echo "  3. Run: zig build test -Dtest-file=tools/$TOOL_NAME"
echo ""
echo "📚 See docs/TOOL_DEVELOPMENT_GUIDE.md for detailed guidance"
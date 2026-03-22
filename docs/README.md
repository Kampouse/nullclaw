# Tool Development Documentation

Welcome to the NullClaw tool development documentation! This resource hub provides everything you need to create, test, and integrate new tools with the agent system.

## 🚀 Quick Start

**New to tool development?** Start here:

1. 📖 Read the [Tool Development Guide](./TOOL_DEVELOPMENT_GUIDE.md) - comprehensive guide
2. 🔧 Use the [Tool Generator Script](../scripts/generate_tool.sh) to create a scaffold
3. 🧪 Copy tests from the [Testing Template](./TOOL_TESTING_TEMPLATE.md)
4. 📋 Keep the [Quick Reference](./TOOL_DEVELOPMENT_QUICKREF.md) handy

## 📚 Documentation

### Core Guides
- **[Tool Development Guide](./TOOL_DEVELOPMENT_GUIDE.md)** - Comprehensive guide covering everything from tool structure to security best practices
- **[Quick Reference](./TOOL_DEVELOPMENT_QUICKREF.md)** - Cheat sheet for common patterns and solutions
- **[Testing Template](./TOOL_TESTING_TEMPLATE.md)** - Complete test suite template with examples

### Tools & Automation
- **[Tool Generator Script](../scripts/generate_tool.sh)** - Automated tool scaffolding generator
  ```bash
  ./scripts/generate_tool.sh my_new_tool "Description of what it does"
  ```

## 🎯 What's Improved?

### Before: Manual, Error-Prone Process
- ❌ No documentation - had to reverse-engineer from existing tools
- ❌ Manual registration in 3+ places (easy to miss steps)
- ❌ Copy/paste from existing tools (inconsistent patterns)
- ❌ Unclear memory safety requirements
- ❌ Inconsistent testing approaches

### After: Streamlined, Well-Documented Experience
- ✅ Comprehensive documentation with examples
- ✅ Automated tool generation with registration instructions
- ✅ Consistent templates and patterns
- ✅ Clear memory safety guidelines
- ✅ Standard testing patterns and templates
- ✅ Security best practices built-in

## 🔧 Tool Development Workflow

### 1. **Generate Tool Scaffold**
```bash
./scripts/generate_tool.sh my_tool "Does something useful"
```

This creates:
- `src/tools/my_tool.zig` - Complete tool template
- `scripts/my_tool_registration.txt` - Step-by-step registration guide

### 2. **Implement Tool Logic**
Edit the generated tool file to add your functionality:
- Implement the `execute()` function
- Add proper parameter validation
- Include security checks
- Handle errors gracefully

### 3. **Register Tool**
Follow the registration instructions:
- Add import to `src/tools/root.zig`
- Add instance in `allTools()` function
- Add to `src/capabilities.zig`

### 4. **Test Your Tool**
```bash
# Run your tool's tests
zig build test -Dtest-file=tools/my_tool --summary all

# Run integration tests
zig build test -Dtest-file=tools --summary all
```

### 5. **Verify Integration**
- Test with the agent
- Check memory safety
- Verify security measures
- Document any special requirements

## 🏗️ Tool Architecture

### Required Components

Every tool must implement:

```zig
pub const MyTool = struct {
    // Configuration
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},

    // Metadata
    pub const tool_name = "my_tool";
    pub const tool_description = "Description";
    pub const tool_params = "{...JSON schema...}";

    // Interface
    const vtable = root.ToolVTable(@This());
    pub fn tool(self: *MyTool) Tool { /* ... */ }
    pub fn execute(self: *MyTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult { /* ... */ }
};
```

### Memory Safety Patterns

✅ **Safe Patterns**
- Transfer ownership with `owns_output = true`
- Use `defer` for cleanup
- Duplicate data with `allocator.dupe()`
- Clean up in error paths

❌ **Unsafe Patterns**
- Returning stack buffers
- Forgetting to clean up allocations
- Use-after-free scenarios
- Buffer overflows

See the [Development Guide](./TOOL_DEVELOPMENT_GUIDE.md) for detailed memory safety rules.

## 🔒 Security Considerations

### Input Validation
- Sanitize all user input
- Check for command injection patterns
- Validate file paths
- Handle malformed input gracefully

### Path Security
- Use `path_security.resolvePathAlloc()`
- Validate paths are within allowed areas
- Prevent directory traversal attacks

### Parameter Sanitization
```zig
fn sanitizeInput(input: []const u8) bool {
    const dangerous = [_][]const u8{"|", ";", "$(", "`", "&"};
    for (dangerous) |pattern| {
        if (std.mem.indexOf(u8, input, pattern) != null)
            return false;
    }
    return true;
}
```

## 🧪 Testing Strategy

### Test Coverage
- **Metadata tests** - Tool identity and schema
- **Functionality tests** - Normal operation
- **Error tests** - Failure modes
- **Security tests** - Malicious input handling
- **Memory tests** - Leak detection
- **Integration tests** - System compatibility

### Test Commands
```bash
# Single tool
zig build test -Dtest-file=tools/my_tool --summary all

# All tools
zig build test -Dtest-file=tools --summary all

# With detailed output
zig build test -Dtest-file=tools/my_tool -freference-trace
```

## 📖 Examples & Reference Implementations

### Well-Documented Tools
- **[`src/tools/cargo.zig`](../src/tools/cargo.zig)** - Complete example with:
  - Command execution with argument tokenization
  - Security sanitization
  - Comprehensive tests
  - Memory-safe patterns

- **[`src/tools/self_diagnose.zig`](../src/tools/self_diagnose.zig)** - Simple example showing:
  - Basic tool structure
  - Buffer-based operations
  - Multiple check types
  - Clean error handling

### Key Patterns to Study
1. **Argument tokenization** - See `cargo.zig` Tokenizer implementation
2. **Memory management** - Review `runCargoOp()` patterns
3. **Error handling** - Check how tools handle failures
4. **Security** - Study `sanitizeCargoArgs()` approach

## 🆘 Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Tool not found | Check all 3 registration locations |
| Memory leaks | Review `defer` statements and ownership transfers |
| Tests pass, tool fails | Check parameter validation and error paths |
| Schema errors | Validate JSON schema format |
| Path traversal vuln | Use `path_security.resolvePathAlloc()` |

### Getting Help
1. Check this documentation
2. Review existing tools as examples
3. Search issues in the repository
4. Ask in development community

## 🎓 Learning Path

### Beginner
1. Read the Quick Reference
2. Generate a simple tool
3. Implement basic functionality
4. Write basic tests
5. Register and test integration

### Intermediate
1. Study the Development Guide
2. Implement complex operations
3. Add security measures
4. Write comprehensive tests
5. Handle edge cases

### Advanced
1. Optimize performance
2. Advanced security features
3. Memory leak detection
4. Concurrent operations
5. Integration testing

## 🚀 Next Steps

Ready to build your first tool?

```bash
# Generate your tool scaffold
./scripts/generate_tool.sh my_awesome_tool "Does something amazing"

# Follow the registration guide
cat scripts/my_awesome_tool_registration.txt

# Edit the tool implementation
vim src/tools/my_awesome_tool.zig

# Test your tool
zig build test -Dtest-file=tools/my_awesome_tool --summary all
```

## 📊 Tool Development Metrics

Track your progress:
- [ ] Tool scaffold generated
- [ ] Implementation complete
- [ ] Tests written and passing
- [ ] Registration complete
- [ ] Integration tested
- [ ] Security reviewed
- [ ] Documentation updated
- [ ] Memory verified (no leaks)

---

**Happy tool building!** 🎉

Remember: Good tools are safe, tested, and well-documented. This resource is here to help you achieve all three.
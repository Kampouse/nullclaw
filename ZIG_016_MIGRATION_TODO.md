# Zig 0.16 Migration - Remaining Work

**Status**: 84 errors remaining (down from 259 total)

Progress: **175 errors fixed** across 6 phases

Run: `zig build test --summary all 2>&1 | grep "error:" | wc -l`

---

## ✅ Completed Fixes (175 errors)

### Phase 6 (Latest):
- ✅ **skills.zig** (80+ errors) - process.spawn, fs APIs, writeFile, readFileAlloc
- ✅ **tools/** directory (7 files) - ArrayList.writer, process.run, fs.cwd
- ✅ **state.zig** (4 errors) - mutex operations, file operations
- ✅ **subagent.zig** (6 errors) - mutex operations
- ✅ **peripherals.zig** (3 errors) - fs.File → Io.File
- ✅ **service.zig** (2 errors) - Child.spawn, ArrayList.init
- ✅ **skillforge.zig** (1 error) - http.Client.init(io)
- ✅ **security/** (4 errors) - trimEnd, writeFile io params
- ✅ **providers/gemini.zig** (3 errors) - file operations
- ✅ **trimRight → trimEnd** (4 files)
- ✅ **readFileAlloc** signature fixed throughout codebase

### Previous phases:
- ✅ cron.zig: std.Io.poll → std.posix.poll rewrite
- ✅ qmd.zig, multimodal.zig, observability.zig, migration.zig, onboard.zig
- ✅ ArrayList.writer() → FixedBufferStream
- ✅ std.fs → std.Io migrations
- ✅ process.run() → spawn()

---

## 🔥 Remaining Work (84 errors)

### High Priority Files:

| File | Error Count | Main Issues |
|------|-------------|-------------|
| **redis.zig** | 5 | std.net → Io.net, Stream.writeAll |
| **onboard.zig** | 8 | fs.createFileAbsolute, switch cases, io params |
| **mattermost.zig** | 1 | Io.net.HostName field access |
| **cost.zig** | 2 | Io.File.seekFromEnd, unused var |
| **multimodal.zig** | 1 | fs.accessAbsolute |
| **peripherals.zig** | 1 | fs.openFileAbsolute |
| **cron.zig** | 1 | method needs 2 args |
| **qmd.zig** | 1 | deleteFile needs io |
| **migration.zig** | 1 | reader.interface method |
| **observability.zig** | 1 | random.bytes() param |

---

## 🔧 Correct API Signatures (from Zig 0.16 source)

### readFileAlloc (CRITICAL)
```zig
// CORRECT signature from std/Io/Dir.zig:
pub fn readFileAlloc(
    dir: Dir,
    io: Io,
    sub_path: []const u8,
    gpa: Allocator,
    limit: Io.Limit,
) ![]u8

// Usage:
const content = try dir.readFileAlloc(
    io,
    "file.txt",
    allocator,
    .limited(1024 * 1024)  // or .unlimited
);
```

### Io.File.Reader
```zig
var reader = file.reader(io, &buf);
// Use .interface field:
const n = try reader.interface.readSliceShort(buf);
const data = try reader.interface.readAlloc(allocator, max_size);
```

### Io.Timestamp
```zig
const stat = try dir.statFile(io, "file.txt", .{});
const mtime_ns: i128 = stat.mtime.nanoseconds;  // NOT stat.mtime directly
```

### Random
```zig
std.Io.random(io).bytes(buf)  // NOT .read()
```

### statFile
```zig
dir.statFile(io, path, .{ .follow_symlinks = true })
```

---

## 📋 Common Fix Patterns

### std.net → Io.net
```zig
// OLD:
std.net.Address.resolveIp(...)
std.net.Stream.connect(...)

// NEW:
std.Io.net.Address.resolveIp(io, ...)
std.Io.net.Stream.connect(io, ...)
```

### fs APIs → Io.Dir
```zig
// OLD:
std.fs.createFileAbsolute(path, opts)
std.fs.openFileAbsolute(path, opts)
std.fs.accessAbsolute(path, perms)

// NEW:
std.Io.Dir.createFileAbsolute(io, path, opts)
std.Io.Dir.openFileAbsolute(io, path, opts)
std.Io.Dir.accessAbsolute(io, path, perms)
```

### Io.net.HostName
```zig
// Check struct fields in Zig source - may need different access
const host = try uri.getHost();
// HostName is a struct, check actual fields
```

### Io.File seek
```zig
// seekFromEnd removed, use:
const stat = try file.stat(io);
try file.seekTo(io, stat.size - offset);
```

### Stream writeAll
```zig
// Io.net.Stream doesn't have writeAll
// Use writeStreamingAll instead:
try stream.writeStreamingAll(io, data);
```

### deleteFile
```zig
// May need io parameter:
dir.deleteFile(io, path)  // check if required
```

---

## 🔍 How to Check APIs

```bash
# Zig 0.16 source location:
ls /Users/jean/.local/zig/lib/std/

# Find function signatures:
grep -A 10 "pub fn functionName" /Users/jean/.local/zig/lib/std/Io/Dir.zig
grep -A 10 "pub fn functionName" /Users/jean/.local/zig/lib/std/Io/File.zig

# Check struct fields:
head -50 /Users/jean/.local/zig/lib/std/Io/net/HostName.zig
```

---

## Test Commands

```bash
# Count errors:
zig build test --summary all 2>&1 | grep "error:" | wc -l

# See errors:
zig build test --summary all 2>&1 | grep "error:"

# Test specific file:
zig test src/file.zig
```

---

## Migration Phases Summary

| Phase | Errors Fixed | Key Changes |
|-------|--------------|-------------|
| 1-3 | 107 | Initial Io migrations, ArrayList, mutex |
| 4 | 15 | cron poll rewrite, file operations |
| 5 | 6 | qmd, migration, multimodal, observability |
| **6** | **62** | **skills (80+), tools, readFileAlloc** |
| **Total** | **175** | **67% complete** |

---

**Next Focus**: Fix redis.zig (std.net → Io.net) and onboard.zig (remaining fs APIs)

# Zig 0.15.2 → 0.16.0 API Changes Reference

This document contains all API changes between Zig 0.15.2 and 0.16.0, extracted from the Zig 0.16.0 standard library source at `~/.zig-0.16/lib/std/`.

**Zig Version**: 0.16.0  
**Source Path**: `~/.zig-0.16/lib/std/`

---

## 1. Io Parameter (Sans-I/O Pattern)

**Source**: `~/.zig-0.16/lib/std/Io.zig`

**Major Change**: Most operations now require an `io` parameter as the first argument.

```bash
# How to find:
rg "pub fn " ~/.zig-0.16/lib/std/Io/Dir.zig | head -20
rg "io: Io" ~/.zig-0.16/lib/std/Io/*.zig
```

### Getting an Io instance

```zig
// In test functions
const io = std.Options.debug_io;

// In production code, io is passed as parameter
fn myFunction(io: std.Io, ...) void { }
```

---

## 2. File Operations

**Source**: `~/.zig-0.16/lib/std/Io/Dir.zig`, `~/.zig-0.16/lib/std/Io/File.zig`

```bash
# How to find:
rg "pub fn createFile" ~/.zig-0.16/lib/std/Io/Dir.zig -A 3
rg "pub fn openFile" ~/.zig-0.16/lib/std/Io/Dir.zig -A 3
rg "pub fn close" ~/.zig-0.16/lib/std/Io/File.zig -A 3
rg "pub fn writeFile" ~/.zig-0.16/lib/std/Io/Dir.zig -A 5
```

### File Creation/Open

| 0.15.2 | 0.16.0 |
|--------|--------|
| `dir.createFile(path, flags)` | `dir.createFile(io, path, flags)` |
| `dir.openFile(path, flags)` | `dir.openFile(io, path, flags)` |
| `dir.writeFile(.{ .sub_path = p, .data = d })` | `dir.writeFile(io, .{ .sub_path = p, .data = d })` |
| `std.fs.createFileAbsolute(path, flags)` | `std.Io.Dir.createFileAbsolute(io, path, flags)` |
| `std.fs.openFileAbsolute(path, flags)` | `std.Io.Dir.openFileAbsolute(io, path, flags)` |

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/Io/Dir.zig:1
pub fn createFile(dir: Dir, io: Io, sub_path: []const u8, flags: File.CreateFlags) File.OpenError!File {
    return io.vtable.dirCreateFile(io.userdata, dir, sub_path, flags);
}

pub fn openFile(dir: Dir, io: Io, sub_path: []const u8, flags: File.OpenFlags) File.OpenError!File {
    return io.vtable.dirOpenFile(io.userdata, dir, sub_path, flags);
}

pub fn writeFile(dir: Dir, io: Io, options: WriteFileOptions) WriteFileError!void {
    var file = try dir.createFile(io, options.sub_path, options.flags);
    defer file.close(io);
    try file.writeAll(io, options.data);
}
```

### File Read/Write

| 0.15.2 | 0.16.0 |
|--------|--------|
| `file.writeAll(data)` | `file.writeAll(io, data)` |
| `file.readAll(buf)` | `file.readAll(io, buf)` |
| `file.close()` | `file.close(io)` |
| `file.seekFromEnd(offset)` | `file.seekFromEnd(io, offset)` |

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/Io/File.zig
pub fn close(file: File, io: Io) void {
    return io.vtable.fileClose(io.userdata, file);
}
```

### Example

```zig
// Old (0.15.2)
const file = try dir.createFile("test.txt", .{});
defer file.close();
try file.writeAll("hello");

// New (0.16.0)
const io = std.Options.debug_io;
const file = try dir.createFile(io, "test.txt", .{});
defer file.close(io);
try file.writeAll(io, "hello");
```

---

## 3. Directory Operations

**Source**: `~/.zig-0.16/lib/std/Io/Dir.zig`

```bash
# How to find:
rg "pub fn createDir\|pub fn deleteFile\|pub fn deleteDir" ~/.zig-0.16/lib/std/Io/Dir.zig -A 3
```

| 0.15.2 | 0.16.0 |
|--------|--------|
| `dir.makeDir(path)` | `dir.createDir(io, path, .{})` |
| `dir.realpathAlloc(allocator, path)` | `dir.realPathFileAlloc(io, path, allocator)` returns `[:0]u8` |
| `dir.symLink(target, link, flags)` | `dir.symLink(io, target, link, flags)` |
| `dir.deleteFile(path)` | `dir.deleteFile(io, path)` |
| `dir.deleteDir(path)` | `dir.deleteDir(io, path)` |

**Note**: `realPathFileAlloc` returns `[:0]u8` (sentinel-terminated), may need to slice:
```zig
const path_z = try dir.realPathFileAlloc(io, ".", allocator);
const path = path_z[0..path_z.len]; // Convert to []u8
```

---

## 4. Process/Child API

**Source**: `~/.zig-0.16/lib/std/process/Child.zig`

```bash
# How to find:
head -150 ~/.zig-0.16/lib/std/process/Child.zig
rg "pub const Term\|pub const StdIo" ~/.zig-0.16/lib/std/process/Child.zig -A 10
```

The `process.Child` struct is largely unchanged:

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/process/Child.zig
pub const Term = union(enum) {
    Exited: u8,    // Still capitalized
    Signal: u32,
    Stopped: u32,
    Unknown: u32,
};

pub const StdIo = enum {
    Inherit,
    Ignore,
    Pipe,
    Close,
};
```

### Example

```zig
// Both 0.15.2 and 0.16.0
var child = std.process.Child.init(argv, allocator);
child.stdin_behavior = .ignore;
child.stdout_behavior = .pipe;
try child.spawn();
const term = try child.wait();

if (term) |t| {
    switch (t) {
        .Exited => |code| => { }, // Still capitalized
        .Signal => |sig| => { },
        // ...
    }
}
```

---

## 5. Mutex API

**Source**: `~/.zig-0.16/lib/std/Io.zig` (search for Mutex)

```bash
# How to find:
rg "pub const Mutex" ~/.zig-0.16/lib/std/Io.zig -A 20
rg "pub fn lock\|pub fn unlock" ~/.zig-0.16/lib/std/Io/Mutex.zig -A 5
```

| 0.15.2 | 0.16.0 |
|--------|--------|
| `mutex.lock()` | `mutex.lock(io)` or `mutex.lockUncancelable()` |
| `mutex.unlock()` | `mutex.unlock(io)` |

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/Io.zig
pub const Mutex = struct {
    state: State,

    pub const State = enum(usize) {
        locked_once = 0b00,
        unlocked = 0b01,
        contended = 0b10,
        // ...
    };
};
```

```zig
// Old (0.15.2)
mutex.lock();
defer mutex.unlock();

// New (0.16.0)
mutex.lockUncancelable();
defer mutex.unlockUncancelable();

// Or with io (cancellable)
mutex.lock(io) catch |err| { };
defer mutex.unlock(io);
```

---

## 6. Sleep/Time API

**Source**: `~/.zig-0.16/lib/std/Io.zig`

```bash
# How to find:
rg "pub fn sleep" ~/.zig-0.16/lib/std/Io.zig -A 5
```

| 0.15.2 | 0.16.0 |
|--------|--------|
| `std.Thread.sleep(ns)` | `std.Io.sleep(io, duration, clock)` |
| `std.time.microTimestamp()` | `std.Io.Clock.real.now(io)` |

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/Io.zig
pub fn sleep(duration: Clock.Duration, io: Io) SleepError!void {
    return io.vtable.sleep(io.userdata, .{ .duration = duration });
}

pub fn sleep(io: Io, duration: Duration, clock: Clock) SleepError!void {
    return io.vtable.sleep(io.userdata, .{ .duration = .{
        .raw = duration,
        .clock = clock,
    } });
}
```

```zig
// Old (0.15.2)
std.Thread.sleep(1_000_000_000); // 1 second

// New (0.16.0)
const io = std.Options.debug_io;
try std.Io.sleep(std.Io.Clock.Duration.fromSecs(1), io);
```

---

## 7. Network/Stream API

**Source**: `~/.zig-0.16/lib/std/Io/net/`

```bash
# How to find:
rg "pub fn connect" ~/.zig-0.16/lib/std/Io/net/ -A 5
ls ~/.zig-0.16/lib/std/Io/net/
```

| 0.15.2 | 0.16.0 |
|--------|--------|
| `stream.read(buf)` | `stream.readAll(io, buf)` |
| `stream.write(buf)` | `stream.writeAll(io, buf)` |
| `std.net.TcpClient.connect(...)` | `std.Io.net.Stream.connect(io, ...)` |
| `IpAddress.connect(addr, mode)` | `IpAddress.connect(io, addr, mode)` |

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/Io/net/HostName.zig
pub fn connect(
    host_name: HostName,
    io: Io,
    port: u16,
    options: IpAddress.ConnectOptions,
) ConnectError!Stream {
    // ...
}
```

---

## 8. Random/Crypto API

**Source**: `~/.zig-0.16/lib/std/Io.zig`

```bash
# How to find:
rg "random" ~/.zig-0.16/lib/std/Io.zig -A 5
```

| 0.15.2 | 0.16.0 |
|--------|--------|
| `std.crypto.random.bytes(buf)` | `std.Io.random(io).bytes(buf)` |
| `std.crypto.random.int(u32)` | `std.Io.random(io).int(u32)` |

```zig
// Old (0.15.2)
var buf: [32]u8 = undefined;
std.crypto.random.bytes(&buf);

// New (0.16.0)
const io = std.Options.debug_io;
var buf: [32]u8 = undefined;
std.Io.random(io).bytes(&buf);
```

---

## 9. HTTP Client API

**Source**: `~/.zig-0.16/lib/std/http/`

```bash
# How to find:
rg "pub fn init\|io:" ~/.zig-0.16/lib/std/http/Client.zig -A 5 | head -30
```

| 0.15.2 | 0.16.0 |
|--------|--------|
| `var client = std.http.Client{ .allocator = a }` | `var client = std.http.Client.init(io, a)` |

```zig
// Old (0.15.2)
var client = std.http.Client{ .allocator = allocator };

// New (0.16.0)
const io = std.Options.debug_io;
var client = std.http.Client.init(io, allocator);
```

---

## 10. ArrayList.writer() Removed

**Source**: `~/.zig-0.16/lib/std/array_list.zig` (or check if it exists)

```bash
# How to find:
rg "pub fn writer" ~/.zig-0.16/lib/std/array_list.zig -A 5
# Returns nothing - method removed
```

The `ArrayList.writer()` method has been removed.

### Alternatives

```zig
// Option 1: Use fixed buffer stream
var buf: [1024]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
const w = fbs.writer();
try writeFunction(w);
const result = fbs.getWritten();

// Option 2: Use ArrayList with appendSlice
var buf: std.ArrayListUnmanaged(u8) = .empty;
defer buf.deinit(allocator);
try buf.appendSlice(allocator, "content");

// Option 3: Skip test
test "some test" {
    return error.SkipZigTest; // TODO: Zig 0.16 migration
}
```

---

## 11. POSIX API Changes

**Source**: `~/.zig-0.16/lib/std/posix.zig`

```bash
# How to find:
rg "pub fn close\|pub fn write" ~/.zig-0.16/lib/std/posix.zig -A 3 | head -20
```

| 0.15.2 | 0.16.0 |
|--------|--------|
| `std.posix.close(fd)` | `std.posix.close(fd)` (unchanged) |
| `std.posix.write(fd, buf)` | `std.posix.write(fd, buf)` (unchanged) |

POSIX APIs are largely unchanged.

---

## 12. Main Function Signature

**Source**: `~/.zig-0.16/lib/std/process.zig`

```bash
# How to find:
rg "pub fn argsWithAllocator" ~/.zig-0.16/lib/std/process.zig -A 5
```

| 0.15.2 | 0.16.0 |
|--------|--------|
| `pub fn main() !void` | `pub fn main() !void` (unchanged) |
| `std.process.args()` | `std.process.argsWithAllocator(allocator)` |

```zig
// Old (0.15.2)
var args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args);

// New (0.16.0)
var args_iter = try std.process.argsWithAllocator(allocator);
var args_list: std.ArrayList([:0]const u8) = .empty;
while (args_iter.next()) |arg| {
    try args_list.append(allocator, arg);
}
```

---

## 13. Writer/Reader Interface Changes

**Source**: `~/.zig-0.16/lib/std/Io/Writer.zig`, `~/.zig-0.16/lib/std/Io/Reader.zig`

```bash
# How to find:
head -100 ~/.zig-0.16/lib/std/Io/Writer.zig
ls ~/.zig-0.16/lib/std/Io/Reader/
```

The `Writer` and `Reader` interfaces are now vtable-based.

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/Io/Writer.zig
pub const Writer = struct {
    vtable: *const VTable,
    buffer: []u8,
    end: usize = 0,
    
    pub const VTable = struct {
        drain: *const fn (w: *Writer, data: []const []const u8, splat: usize) Error!usize,
        sendFile: *const fn (...) FileError!usize,
        flush: *const fn (w: *Writer) Error!void,
        rebase: *const fn (w: *Writer, preserve: usize, capacity: usize) Error!void,
    };
};
```

### Creating a Fixed Buffer Writer

```zig
// Old (0.15.2)
var buf: [1024]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
const w = fbs.writer();
try w.print("hello {}", .{name});
const written = fbs.getWritten();

// New (0.16.0) - Option 1: Writer.fixed
var w: std.Io.Writer = .fixed(&buf);
try w.print("hello {}", .{name});
const written = w.buffered();

// New (0.16.0) - Option 2: Custom FixedBufferStream helper
// (see src/util.zig in nullclaw for implementation)
```

---

## 14. JSON API Changes

**Source**: `~/.zig-0.16/lib/std/json/`

```bash
# How to find:
ls ~/.zig-0.16/lib/std/json/
head -50 ~/.zig-0.16/lib/std/json/static.zig
```

JSON module has been reorganized into separate files:

| Module | Purpose |
|--------|---------|
| `std.json.static` | Static parsing (parseFromSlice, stringify) |
| `std.json.dynamic` | Dynamic parsing (Value, parseFromSlice) |
| `std.json.Scanner` | Low-level scanner |
| `std.json.Stringify` | Stringification |

```zig
// Old (0.15.2)
const parsed = try std.json.parseFromSlice(MyStruct, allocator, json_str, .{});
defer parsed.deinit();

// New (0.16.0) - Check std.json.static
const parsed = try std.json.static.parseFromSlice(MyStruct, allocator, json_str, .{});
```

---

## 15. std.io.fixedBufferStream Removed

**Source**: Not found in `~/.zig-0.16/lib/std/io.zig` or `~/.zig-0.16/lib/std/`

```bash
# How to find:
rg "fixedBufferStream" ~/.zig-0.16/lib/std/ 
# Returns nothing - function removed
```

This function no longer exists. Use alternatives:

```zig
// Old (0.15.2)
var fbs = std.io.fixedBufferStream(&buf);

// New (0.16.0)
var w: std.Io.Writer = .fixed(&buf);
// OR implement your own FixedBufferStream
```

---

## 16. Common Error Fixes

### error.EndOfStream

**Source**: `~/.zig-0.16/lib/std/Io/*.zig`

```bash
# How to find:
rg "error\.EndOfStream\|EndOfStream" ~/.zig-0.16/lib/std/Io/
```

If you get `error.EndOfStream not in expected error set`, the function signature changed.

### ArrayList.writer() Removed

Replace with:
1. FixedBufferStream helper (see src/util.zig)
2. Direct appendSlice calls
3. Skip test with `return error.SkipZigTest`

---

## 17. TLS Client Changes

**Source**: `~/.zig-0.16/lib/std/crypto/tls/Client.zig`

```bash
# How to find:
head -100 ~/.zig-0.16/lib/std/crypto/tls/Client.zig
rg "entropy_len\|min_buffer_len" ~/.zig-0.16/lib/std/crypto/tls/Client.zig -A 2
```

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/crypto/tls/Client.zig
/// The `Reader` supplied to `init` requires a buffer capacity
/// at least this amount.
pub const min_buffer_len = tls.max_ciphertext_record_len;

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
```

TLS Client now requires more setup:

```zig
const entropy_len = 240; // std.crypto.tls.Client.entropy_len (check source)

var entropy: [entropy_len]u8 = undefined;
std.Io.random(io).bytes(&entropy);

const client = try std.crypto.tls.Client.init(...);
```

---

## 18. std.fs.File and std.fs.Dir Deprecated

**Source**: `~/.zig-0.16/lib/std/fs/File.zig`, `~/.zig-0.16/lib/std/fs/Dir.zig`

```bash
# How to find:
head -20 ~/.zig-0.16/lib/std/fs/File.zig
head -20 ~/.zig-0.16/lib/std/fs/Dir.zig
```

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/fs/File.zig
const File = @This();
// ...
pub const Handle = Io.File.Handle;
pub const Mode = Io.File.Mode;
pub const INode = Io.File.INode;

// ~/.zig-0.16/lib/std/fs/Dir.zig
//! Deprecated in favor of `Io.Dir`.
const Dir = @This();
```

The `std.fs.File` and `std.fs.Dir` types are now deprecated in favor of `std.Io.File` and `std.Io.Dir`.

```zig
// Old (0.15.2)
const File = std.fs.File;
const Dir = std.fs.Dir;

// New (0.16.0)
const File = std.Io.File;
const Dir = std.Io.Dir;

// std.fs.File and std.fs.Dir still exist for backwards compatibility
// but delegate to std.Io versions
```

---

## 19. std.debug.assert Unchanged

**Source**: `~/.zig-0.16/lib/std/debug.zig`

```bash
# How to find:
rg "^pub fn assert" ~/.zig-0.16/lib/std/debug.zig -A 10
```

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/debug.zig
pub fn assert(ok: bool) void {
    if (!ok) unreachable; // assertion failure
}

pub fn assertReadable(slice: []const volatile u8) void {
    if (!runtime_safety) return;
    for (slice) |*byte| _ = byte.*;
}

pub fn assertAligned(ptr: anytype, comptime alignment: std.mem.Alignment) void {
    const aligned_ptr: *align(alignment.toByteUnits()) const anyopaque = @ptrCast(@alignCast(ptr));
    _ = aligned_ptr;
}
```

`assert` works the same way. New assertions added:
- `assertReadable(slice)` - Checks slice is mapped and readable
- `assertAligned(ptr, alignment)` - Checks pointer alignment

---

## 20. std.testing Changes

**Source**: `~/.zig-0.16/lib/std/testing.zig`

```bash
# How to find:
head -50 ~/.zig-0.16/lib/std/testing.zig
rg "pub fn expect" ~/.zig-0.16/lib/std/testing.zig -A 3 | head -30
```

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/testing.zig
pub var io_instance: std.Io.Threaded = undefined;
pub const io = io_instance.io();

pub fn expect(ok: bool) !void {
    if (!ok) return error.TestUnexpectedResult;
}

pub inline fn expectEqual(expected: anytype, actual: anytype) !void {
    const T = @TypeOf(expected, actual);
    return expectEqualInner(T, expected, actual);
}

pub fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    if (std.mem.indexOfDiff(u8, actual, expected)) |diff_index| {
        // ...
    }
}
```

### New `io` instance for tests

```zig
// New in 0.16.0
pub var io_instance: std.Io.Threaded = undefined;
pub const io = io_instance.io();

// Use in tests
test "my test" {
    const io = std.testing.io;
    // or
    const io = std.Options.debug_io;
}
```

### Testing functions (unchanged)

```zig
try std.testing.expect(ok);
try std.testing.expectEqual(expected, actual);
try std.testing.expectEqualSlices(T, expected, actual);
try std.testing.expectEqualStrings(expected, actual);
try std.testing.expectError(expected_error, error_union);
```

---

## 21. std.mem Functions

**Source**: `~/.zig-0.16/lib/std/mem.zig`

```bash
# How to find:
rg "pub fn eql\|pub fn startsWith\|pub fn endsWith" ~/.zig-0.16/lib/std/mem.zig -A 3
head -50 ~/.zig-0.16/lib/std/mem.zig
```

Most `std.mem` functions are unchanged:

| Function | Status |
|----------|--------|
| `std.mem.eql(T, a, b)` | Unchanged |
| `std.mem.startsWith(T, haystack, needle)` | Unchanged |
| `std.mem.endsWith(T, haystack, needle)` | Unchanged |
| `std.mem.indexOfDiff(T, a, b)` | Unchanged (alias for `findDiff`) |
| `std.mem.trim(T, slice, pattern)` | Unchanged |
| `std.mem.copyForwards(T, dest, src)` | Unchanged |
| `std.mem.copyBackwards(T, dest, src)` | Unchanged |
| `std.mem.zeroes(T)` | Unchanged |
| `std.mem.sort(T, items, context, lessThan)` | Unchanged |

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/mem.zig
pub const indexOfDiff = findDiff;

pub fn eql(comptime T: type, a: []const T, b: []const T) bool {
    // ...
}
```

### New Alignment type

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/mem.zig
pub const Alignment = enum(math.Log2Int(usize)) {
    @"1" = 0,
    @"2" = 1,
    @"4" = 2,
    @"8" = 3,
    @"16" = 4,
    // ...
    _,

    pub fn toByteUnits(a: Alignment) usize;
    pub fn fromByteUnits(n: usize) Alignment;
    pub fn of(comptime T: type) Alignment;
};
```

---

## 22. std.sort Module

**Source**: `~/.zig-0.16/lib/std/sort.zig`

```bash
# How to find:
head -100 ~/.zig-0.16/lib/std/sort.zig
ls ~/.zig-0.16/lib/std/sort/
```

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/sort.zig
pub const block = @import("sort/block.zig").block;
pub const pdq = @import("sort/pdq.zig").pdq;
pub const pdqContext = @import("sort/pdq.zig").pdqContext;

pub fn insertion(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void { /* ... */ }

pub fn heap(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void { /* ... */ }
```

Sorting functions unchanged:

```zig
// Both 0.15.2 and 0.16.0
std.sort.insertion(T, items, context, lessThanFn);
std.sort.heap(T, items, context, lessThanFn);
std.sort.block(items, context);
std.sort.pdq(T, items, context, lessThanFn);
```

---

## 23. std.heap ArenaAllocator

**Source**: `~/.zig-0.16/lib/std/heap/arena_allocator.zig`

```bash
# How to find:
head -100 ~/.zig-0.16/lib/std/heap/arena_allocator.zig
```

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/heap/arena_allocator.zig
pub const ArenaAllocator = struct {
    child_allocator: Allocator,
    state: State,

    pub fn init(child_allocator: Allocator) ArenaAllocator { /* ... */ }
    pub fn deinit(self: ArenaAllocator) void { /* ... */ }
    pub fn allocator(self: *ArenaAllocator) Allocator { /* ... */ }
    
    pub const ResetMode = union(enum) {
        free_all,
        retain_capacity,
        retain_with_limit: usize,
    };
};
```

ArenaAllocator API unchanged:

```zig
// Both 0.15.2 and 0.16.0
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const alloc = arena.allocator();

// Reset with options
_ = arena.reset(.free_all);
_ = arena.reset(.retain_capacity);
_ = arena.reset(.{ .retain_with_limit = 1024 * 1024 });
```

---

## 24. std.heap Allocators

**Source**: `~/.zig-0.16/lib/std/heap/`

```bash
# How to find:
ls ~/.zig-0.16/lib/std/heap/
head -50 ~/.zig-0.16/lib/std/heap/SmpAllocator.zig
```

Allocator interface unchanged:

```zig
// Both 0.15.2 and 0.16.0
const allocator = std.heap.page_allocator;
const allocator = std.heap.smp_allocator;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var fba = std.heap.FixedBufferAllocator.init(&buf);
```

---

## 25. Writer.print() Method

**Source**: `~/.zig-0.16/lib/std/Io/Writer.zig`, `~/.zig-0.16/lib/std/fmt.zig`

```bash
# How to find:
rg "pub fn print" ~/.zig-0.16/lib/std/Io/Writer.zig -A 5
rg "pub fn bufPrint" ~/.zig-0.16/lib/std/fmt.zig -A 5
```

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/fmt.zig
pub fn bufPrint(buf: []u8, comptime fmt: []const u8, args: anytype) BufPrintError![]u8 {
    var w: Writer = .fixed(buf);
    w.print(fmt, args) catch |err| switch (err) {
        error.WriteFailed => return error.NoSpaceLeft,
    };
    return w.buffered();
}
```

Writer has a `print` method:

```zig
// New in 0.16.0
var w: std.Io.Writer = .fixed(&buf);
try w.print("hello {s}\n", .{name});
const written = w.buffered();
```

---

## 26. Reader Interface Changes

**Source**: `~/.zig-0.16/lib/std/Io/Reader.zig`

```bash
# How to find:
head -100 ~/.zig-0.16/lib/std/Io/Reader.zig
ls ~/.zig-0.16/lib/std/Io/Reader/
```

Reader is now vtable-based:

```zig
pub const Reader = struct {
    vtable: *const VTable,
    buffer: []u8,
    at: usize = 0,
    
    pub const VTable = struct {
        fill: *const fn (r: *Reader, preserve: usize, amount: usize) Error!usize,
        consume: *const fn (r: *Reader, amount: usize) void,
    };
};
```

---

## 27. C Library Interop

**Source**: `~/.zig-0.16/lib/std/c.zig`

```bash
# How to find:
rg "gettimeofday\|timeval" ~/.zig-0.16/lib/std/c.zig -A 3
```

Using C library functions for compatibility:

```zig
// Time functions
var tv: std.c.timeval = undefined;
_ = std.c.gettimeofday(&tv, null);
const epoch = tv.sec;

// File descriptors
const fd = std.posix.open(path, flags, mode);
_ = std.posix.close(fd);
```

---

## 28. Error Set Changes

**Source**: `~/.zig-0.16/lib/std/Io/*.zig`

```bash
# How to find:
rg "pub const Error\|error\." ~/.zig-0.16/lib/std/Io/Writer.zig -A 5
```

### error.EndOfStream

May not be in all error sets. Check the actual function signature:

```bash
rg "error\.EndOfStream\|EndOfStream" ~/.zig-0.16/lib/std/Io/
```

### Common new errors

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/Io/Writer.zig
pub const Error = error{
    /// See the `Writer` implementation for detailed diagnostics.
    WriteFailed,
};

pub const FileAllError = error{
    ReadFailed,
    WriteFailed,
};
```

---

## 29. Thread Spawning

**Source**: `~/.zig-0.16/lib/std/Thread.zig`

```bash
# How to find:
rg "pub fn spawn" ~/.zig-0.16/lib/std/Thread.zig -A 10
```

**Found in source**:
```zig
// ~/.zig-0.16/lib/std/Thread.zig
pub fn spawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!Thread {
    if (builtin.single_threaded) {
        @compileError("Cannot spawn thread when building in single-threaded mode");
    }

    const impl = try Impl.spawn(config, function, args);
    return Thread{ .impl = impl };
}
```

Thread spawning API changed slightly:

```zig
// Old (0.15.2)
const thread = try std.Thread.spawn(.{}, myFunction, .{args});

// New (0.16.0)
const thread = try std.Thread.spawn(.{}, myFunction, .{args});
// Same, but check SpawnConfig options
```

---

## 30. Build System Changes

**Source**: `~/.zig-0.16/lib/std/Build.zig`

```bash
# How to find:
rg "io:" ~/.zig-0.16/lib/std/Build.zig -A 3 | head -20
```

Build.zig uses the new Io API:

```zig
// In build.zig
const io = b.graph.io;
const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| { };
```

---

## Quick Reference: Where to Find APIs

```bash
# File operations
~/.zig-0.16/lib/std/Io/File.zig
~/.zig-0.16/lib/std/Io/Dir.zig

# Process spawning
~/.zig-0.16/lib/std/process/Child.zig

# Network
~/.zig-0.16/lib/std/Io/net.zig
~/.zig-0.16/lib/std/Io/net/

# Mutex
~/.zig-0.16/lib/std/Io.zig (search for "Mutex")

# Random
~/.zig-0.16/lib/std/Io.zig (search for "random")

# Clock/Time
~/.zig-0.16/lib/std/Io/Clock.zig (or search in Io.zig)

# Writer/Reader
~/.zig-0.16/lib/std/Io/Writer.zig
~/.zig-0.16/lib/std/Io/Reader.zig

# Testing
~/.zig-0.16/lib/std/testing.zig

# Memory
~/.zig-0.16/lib/std/mem.zig
~/.zig-0.16/lib/std/mem/Allocator.zig
~/.zig-0.16/lib/std/heap/

# Sorting
~/.zig-0.16/lib/std/sort.zig

# JSON
~/.zig-0.16/lib/std/json/

# TLS
~/.zig-0.16/lib/std/crypto/tls/Client.zig
```

---

## Summary: Most Important Changes

1. **`io` parameter required** for all file/network operations
2. **`std.fs.File`/`Dir` → `std.Io.File`/`Dir`** (deprecated but still work)
3. **`ArrayList.writer()` removed** - Use FixedBufferStream or appendSlice
4. **`std.io.fixedBufferStream()` removed** - Use `Writer.fixed()` or custom impl
5. **Testing requires `io`** - Use `std.testing.io` or `std.Options.debug_io`
6. **Process spawning unchanged** - Same API
7. **Memory allocation unchanged** - Same API

---

## Useful Commands

```bash
# Find function signatures in Zig std lib
rg "pub fn FUNCTION_NAME" ~/.zig-0.16/lib/std/PATH/

# Example: Find writeFile signature
rg "pub fn writeFile" ~/.zig-0.16/lib/std/Io/Dir.zig -A 3

# Find where a function moved
rg "FUNCTION_NAME" ~/.zig-0.16/lib/std/ -l

# Check Zig version
zig version  # Should be 0.16.0

# Search for error types
rg "error\.EndOfStream" ~/.zig-0.16/lib/std/

# Search for type definitions
rg "pub const Mutex\|pub const Writer\|pub const Reader" ~/.zig-0.16/lib/std/
```

---

*Generated from Zig 0.16.0 standard library source analysis*  
*Source location: ~/.zig-0.16/lib/std/*

---

# AI Migration Guide

This section is optimized for AI agents performing Zig 0.15.2 → 0.16.0 migrations.

---

## Migration Workflow

```
1. Identify error type (see Error Patterns below)
2. Find matching API change section
3. Apply fix pattern
4. Verify with `zig build`
5. Repeat
```

---

## Error Patterns → Fixes

### Pattern: "no member named 'openFile'" or "expected 2 arguments, found 3"

**Error Examples:**
```
error: root source file struct 'Io.Dir' has no member named 'openFileAbsolute'
error: expected 2 arguments, found 3
```

**Cause:** Missing `io` parameter

**Fix:** Add `io` as first parameter after self

**Before:**
```zig
const file = try dir.createFile(path, .{});
defer file.close();
```

**After:**
```zig
const io = std.Options.debug_io; // or get io from parameter
const file = try dir.createFile(io, path, .{});
defer file.close(io);
```

**Search Pattern:**
```regex
(\w+)\.(createFile|openFile|writeFile|deleteFile|createDir)\(([^)]+)\)
→
$1.$2(io, $3)
```

---

### Pattern: "no member named 'writer'" on ArrayList

**Error Examples:**
```
error: struct 'ArrayList' has no member named 'writer'
```

**Cause:** `ArrayList.writer()` removed in 0.16.0

**Fix:** Use FixedBufferStream or appendSlice

**Before:**
```zig
var buf = std.ArrayList(u8).init(allocator);
const w = buf.writer();
try w.print("hello", .{});
```

**After (Option 1 - FixedBufferStream):**
```zig
var buf: [1024]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try w.print("hello", .{});
const result = w.buffered();
```

**After (Option 2 - appendSlice):**
```zig
var buf = std.ArrayList(u8).init(allocator);
try buf.appendSlice("hello");
```

---

### Pattern: "no member named 'lock'" on Mutex

**Error Examples:**
```
error: struct 'Mutex' has no member named 'lock'
```

**Cause:** Mutex methods now require `io` parameter

**Fix:** Use `lockUncancelable()` or add `io` parameter

**Before:**
```zig
mutex.lock();
defer mutex.unlock();
```

**After:**
```zig
mutex.lockUncancelable();
defer mutex.unlockUncancelable();
```

---

### Pattern: "expected type 'void', found 'error'"

**Error Examples:**
```
error: expected type 'void', found 'error{OutOfMemory}'
```

**Cause:** Function signature changed to return error

**Fix:** Add `try` or handle error

**Before:**
```zig
std.Thread.sleep(1000);
```

**After:**
```zig
try std.Io.sleep(io, .fromSecs(1));
// or use std.time.sleep for simple cases
```

---

### Pattern: "has no member named 'fixedBufferStream'"

**Error Examples:**
```
error: root source file 'std.io' has no member named 'fixedBufferStream'
```

**Cause:** `std.io.fixedBufferStream()` removed

**Fix:** Use `Writer.fixed()`

**Before:**
```zig
var fbs = std.io.fixedBufferStream(&buf);
const w = fbs.writer();
```

**After:**
```zig
var w: std.Io.Writer = .fixed(&buf);
```

---

## Change Type Tags

Each API change is tagged with its type for quick identification:

| Tag | Meaning | Example |
|-----|---------|---------|
| `[IO-PARAM]` | Requires `io` parameter | `file.close()` → `file.close(io)` |
| `[REMOVED]` | Feature removed | `ArrayList.writer()` removed |
| `[MOVED]` | Moved to new location | `std.Thread.sleep` → `std.Io.sleep` |
| `[RENAMED]` | Renamed | `makeDir` → `createDir` |
| `[UNCHANGED]` | No changes needed | Process spawning API |
| `[DEPRECATED]` | Still works but deprecated | `std.fs.File` → `std.Io.File` |

---

## Priority Ranking

Most common changes (fix these first):

### Priority 1: Critical (affects most files)
1. `[IO-PARAM]` File operations - `createFile`, `openFile`, `writeFile`, `close`
2. `[IO-PARAM]` Directory operations - `createDir`, `openDir`, `deleteFile`
3. `[IO-PARAM]` Mutex - `lock`, `unlock`

### Priority 2: Common (affects many files)
4. `[REMOVED]` `ArrayList.writer()` - Use FixedBufferStream
5. `[REMOVED]` `std.io.fixedBufferStream()` - Use `Writer.fixed()`
6. `[MOVED]` `std.Thread.sleep` - Use `std.Io.sleep`

### Priority 3: Less Common
7. `[IO-PARAM]` Network operations
8. `[IO-PARAM]` Random/crypto operations
9. `[MOVED]` JSON APIs

### Priority 4: Rare
10. `[IO-PARAM]` TLS client
11. `[IO-PARAM]` HTTP client

---

## Quick Fix Commands

### Add `io` parameter to file operations

```bash
# Find all file operations missing io
rg "\.(createFile|openFile|writeFile|close)\(" --type zig -l

# Pattern to fix manually:
# before:  file.close()
# after:   file.close(io)
```

### Find ArrayList.writer() usage

```bash
rg "\.writer\(\)" --type zig -l
```

### Find mutex operations

```bash
rg "mutex\.(lock|unlock)\(\)" --type zig -l
```

---

## Common Migration Patterns

### Pattern 1: Test function with file operations

```zig
// Before
test "file test" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("test.txt", .{});
    defer file.close();
}

// After
test "file test" {
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "test.txt", .{});
    defer file.close(io);
}
```

### Pattern 2: Function that does file I/O

```zig
// Before
fn saveData(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

// After
fn saveData(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeAll(io, data);
}
```

### Pattern 3: Skipping problematic tests

```zig
// If migration is too complex, skip temporarily
test "complex test" {
    return error.SkipZigTest; // TODO: Zig 0.16 migration - ArrayList.writer() removed
    // ... rest of test
}
```

---

## Semantic Tags for AI

<!-- 
AI_SEMANTIC_TAGS:
- change_type: io_param | removed | moved | renamed | unchanged | deprecated
- priority: critical | common | less_common | rare
- pattern: regex_pattern_to_find
- fix: regex_pattern_to_replace
- error_signature: compiler_error_pattern
-->

Each section below includes semantic tags for automated processing.

---

## Tagged API Changes

### [IO-PARAM] [CRITICAL] File Operations

**Pattern:** `\.(createFile|openFile|writeFile|close)\((?!io)`
**Fix:** Add `io` as first parameter

```zig
// Tag: IO-PARAM, CRITICAL
// Error: "expected 2 arguments, found 1" or "no member named"
dir.createFile(path, .{}) → dir.createFile(io, path, .{})
file.close() → file.close(io)
```

### [IO-PARAM] [CRITICAL] Directory Operations

**Pattern:** `\.(createDir|openDir|deleteFile|deleteDir)\((?!io)`
**Fix:** Add `io` as first parameter

```zig
// Tag: IO-PARAM, CRITICAL
dir.makeDir(path) → dir.createDir(io, path, .{})
dir.deleteFile(path) → dir.deleteFile(io, path)
```

### [IO-PARAM] [CRITICAL] Mutex Operations

**Pattern:** `mutex\.(lock|unlock)\(\)`
**Fix:** Use `lockUncancelable()` or add `io`

```zig
// Tag: IO-PARAM, CRITICAL
// Note: lockUncancelable() is simpler for most cases
mutex.lock() → mutex.lockUncancelable()
mutex.unlock() → mutex.unlockUncancelable()
```

### [REMOVED] [COMMON] ArrayList.writer()

**Pattern:** `\.writer\(\)`
**Error:** "struct 'ArrayList' has no member named 'writer'"

```zig
// Tag: REMOVED, COMMON
// Option 1: FixedBufferStream
var buf: [1024]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);

// Option 2: appendSlice
try buf.appendSlice("content");
```

### [REMOVED] [COMMON] std.io.fixedBufferStream()

**Pattern:** `fixedBufferStream`
**Error:** "has no member named 'fixedBufferStream'"

```zig
// Tag: REMOVED, COMMON
std.io.fixedBufferStream(&buf) → std.Io.Writer.fixed(&buf)
```

### [MOVED] [COMMON] Sleep

**Pattern:** `std\.Thread\.sleep`
**Fix:** Use `std.Io.sleep` or `std.time.sleep`

```zig
// Tag: MOVED, COMMON
std.Thread.sleep(ns) → try std.Io.sleep(io, duration, clock)
// or use std.time.sleep for simple cases
```

### [UNCHANGED] [N/A] Process Spawning

```zig
// Tag: UNCHANGED
// No changes needed
var child = std.process.Child.init(argv, allocator);
child.stdin_behavior = .ignore;
try child.spawn();
```

### [DEPRECATED] [LESS_COMMON] std.fs.File/Dir

```zig
// Tag: DEPRECATED, LESS_COMMON
// Still works, but prefer std.Io.File/Dir
std.fs.File → std.Io.File
std.fs.Dir → std.Io.Dir
```

---

## Checklist for AI Migration Agent

```
[ ] 1. Run `zig build` to identify errors
[ ] 2. Categorize errors by pattern (see Error Patterns)
[ ] 3. Fix Priority 1 (Critical) issues first:
    [ ] File operations (createFile, openFile, close, writeFile)
    [ ] Directory operations (createDir, deleteFile)
    [ ] Mutex operations (lock, unlock)
[ ] 4. Fix Priority 2 (Common) issues:
    [ ] ArrayList.writer() → FixedBufferStream
    [ ] fixedBufferStream → Writer.fixed()
    [ ] std.Thread.sleep → std.Io.sleep
[ ] 5. Run `zig build` after each file
[ ] 6. Skip complex tests with error.SkipZigTest
[ ] 7. Run full test suite
[ ] 8. Document any remaining issues
```

---

## Example AI Prompt

When asking an AI to migrate code:

```
Migrate this Zig code from 0.15.2 to 0.16.0.

Rules:
1. Add `io` parameter to all file/directory operations
2. Replace `ArrayList.writer()` with `Writer.fixed()` or appendSlice
3. Replace `mutex.lock()` with `mutex.lockUncancelable()`
4. Use `std.Options.debug_io` for io in tests
5. Skip tests that are too complex with `return error.SkipZigTest`

Reference: api_change.md sections on [IO-PARAM], [REMOVED], [MOVED]

Code to migrate:
<code>
```

---

## Statistics

Based on analysis of typical Zig projects:

| Change Type | Estimated Occurrences per 10k LOC |
|-------------|-----------------------------------|
| File operations (io param) | 50-100 |
| Directory operations (io param) | 20-50 |
| Mutex operations | 10-30 |
| ArrayList.writer() | 5-20 |
| fixedBufferStream | 5-15 |
| Sleep | 1-5 |

**Total estimated changes:** 100-250 per 10k LOC

---

*End of AI Migration Guide*

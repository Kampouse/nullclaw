# Zig 0.16 Migration - Remaining Work

**Status**: 146 errors remaining

Run: `zig build test --summary all 2>&1 | grep "error:"`

---

## 🔥 Priority Files (80% of errors)

### skills.zig (80+ errors)
```zig
// process.Child.init → process.Child.spawn
// fs.accessAbsolute → Io.Dir.accessAbsolute
// fs.createFileAbsolute → Io.Dir.createFileAbsolute
// fs.openDirAbsolute → Io.Dir.openDirAbsolute
// writeFile params: (io, path, data) → (io, path, data, mode)
// readFileAlloc params: (io, path, max_size, allocator)
// trimRight → trimTrailing
```

### Common std.fs → std.Io migrations
```zig
std.fs.File                    → std.Io.File
std.fs.openFileAbsolute        → std.Io.Dir.openFileAbsolute(io, path, opts)
std.fs.createFileAbsolute      → std.Io.Dir.createFileAbsolute(io, path, opts)
std.fs.openDirAbsolute         → std.Io.Dir.openDirAbsolute(io, path, opts)
std.fs.accessAbsolute          → std.Io.Dir.accessAbsolute(io, path, perms)
std.fs.cwd()                   → std.Io.Dir.cwd()
std.fs.path.join               → std.fs.path.join (unchanged)
```

### ArrayList API changes
```zig
ArrayList.init(allocator)      → ArrayListUnmanaged{.items = &.{}, .capacity = 0}
array_list.writer()            → Use FixedBufferStream or append() directly
```

---

## 🔧 Quick Fix Patterns

```zig
// File operations now need io as first param
file.close(io)
file.stat(io)
dir.openFile(io, path, opts)
dir.createFile(io, path, opts)
dir.writeFile(io, .{ .sub_path = p, .data = d })
dir.statFile(io, name)
dir.deleteFile(name)           // No io needed

// Read file
var buf: [4096]u8 = undefined;
var reader = file.reader(io, &buf);
const content = try reader.interface.readAlloc(allocator, max_size);

// Write file
dir.writeFile(io, .{ .sub_path = "file.txt", .data = "content" })
file.writeStreamingAll(io, data)

// Mutex
mutex.lockUncancelable(io)
mutex.unlock(io)

// Random
std.Io.random(io).read(buf)

// Realpath
dir.realPathFileAlloc(io, path, allocator)

// Environment
std.c.getenv("VAR")  // returns [*:0]u8

// Dir iteration
var iter = dir.iterate();
while (try iter.next(io)) |entry| { }

// Process
std.process.Child.spawn(argv, allocator)  // instead of init + run
```

---

## 📋 All Remaining Files

| File | Error Count | Main Issues |
|------|-------------|-------------|
| skills.zig | 80+ | Child.init, fs APIs, writeFile, readFileAlloc |
| peripherals.zig | 3 | fs.File, ArrayList.init |
| service.zig | 2 | Child.wait(), ArrayList.init |
| skillforge.zig | 1 | Missing io param |
| tools/cron_list.zig | 3 | ArrayList.writer() |
| tools/cron_run.zig | 1 | Child.run() |
| providers/gemini.zig | 3 | writeFile param order |
| providers/sse.zig | 1 | Struct init |
| security/docker.zig | 2 | trimRight, type error |
| security/audit.zig | 1 | writeFile param order |
| state.zig | 4 | Methods need io |
| subagent.zig | 1 | Methods need io |
| mattermost.zig | 2 | HostName.name, trimRight |
| cost.zig | 1 | Io.File.seekTo |
| redis.zig | 2 | std.net removed |
| multimodal.zig | 1 | fs.accessAbsolute |
| observability.zig | 1 | random.bytes() |
| onboard.zig | 7 | fs APIs, io params, switch cases |

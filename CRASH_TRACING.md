# Crash Tracing Guide for NullClaw

## Enhanced Panic Handler

NullClaw now has an enhanced panic handler that captures crash information.

### What Gets Captured

When NullClaw crashes, you'll see:
- 💥 Panic message
- Return address (where the crash happened)
- Stack trace availability indicator

### Example Output

```
💥 PANIC 💥
Message: index out of bounds
Return address: 0x10a3b4c20

Stack trace available
```

---

## Crash Investigation Methods

### 1. Debug Build with Symbols

Build with debug symbols for better crash info:
```bash
zig build -Doptimize=Debug
./zig-out/bin/nullclaw gateway
```

**Benefits:**
- Line numbers in stack traces
- Function names
- Better variable inspection

---

### 2. Tracy Profiler Crash Capture

Tracy can capture crash information in real-time:

```bash
# Start Tracy
tracy &

# Build with Tracy enabled
zig build -Dtracy=true -Doptimize=Debug

# Run nullclaw
./zig-out/bin/nullclaw gateway
```

**When crash happens:**
- Tracy captures last few frames
- Shows memory state before crash
- Displays zone execution history
- Real-time crash timeline

---

### 3. System Crash Logs

**macOS:**
```bash
# Check for crash reports
ls ~/Library/Logs/DiagnosticReports/nullclaw*

# View crash report
cat ~/Library/Logs/DiagnosticReports/nullclaw_*.crash
```

**Linux:**
```bash
# Check system logs
journalctl -xe | grep nullclaw

# Core dumps
ulimit -c unlimited
./zig-out/bin/nullclaw gateway
# After crash:
gdb ./zig-out/bin/nullclaw core
```

---

### 4. Running with GDB/LLDB

**GDB (Linux):**
```bash
gdb ./zig-out/bin/nullclaw
(gdb) run gateway
# When crash happens:
(gdb) bt full
(gdb) info registers
(gdb) x/20i $pc
```

**LLDB (macOS):**
```bash
lldb ./zig-out/bin/nullclaw
(lldb) run gateway
# When crash happens:
(lldb) bt
(lldb) register read
(lldb) disassemble --frame
```

---

### 5. Sanitizers

Build with sanitizers to catch memory issues:

**AddressSanitizer (ASAN):**
```bash
zig build -Dsanitize=address
./zig-out/bin/nullclaw gateway
```

Detects:
- Buffer overflows
- Use-after-free
- Memory leaks
- Stack buffer overflows

**ThreadSanitizer (TSAN):**
```bash
zig build -Dsanitize=thread
./zig-out/bin/nullclaw gateway
```

Detects:
- Data races
- Deadlocks
- Thread issues

---

### 6. Valgrind (Linux)

```bash
valgrind --leak-check=full \
         --show-leak-kinds=all \
         --track-origins=yes \
         ./zig-out/bin/nullclaw gateway
```

Detects:
- Memory leaks
- Invalid reads/writes
- Uninitialized values

---

## Crash Scenarios & Solutions

### Scenario 1: Segfault

**Symptoms:** Immediate crash, no output

**Debug:**
```bash
lldb ./zig-out/bin/nullclaw
(lldb) run gateway
# Crash happens
(lldb) bt
```

**Common causes:**
- Null pointer dereference
- Array out of bounds
- Invalid memory access

---

### Scenario 2: Hang/Deadlock

**Symptoms:** App freezes, no crash

**Debug:**
```bash
# Find PID
ps aux | grep nullclaw

# Attach debugger
lldb -p <PID>
(lldb) bt all

# Or send signal
kill -ABRT <PID>
# Check crash log
```

**Common causes:**
- Lock contention
- Infinite loop
- Channel blocking

---

### Scenario 3: Memory Corruption

**Symptoms:** Random crashes, weird behavior

**Debug:**
```bash
# Build with ASAN
zig build -Dsanitize=address -Doptimize=Debug
./zig-out/bin/nullclaw gateway
```

ASAN will report:
- Where corruption happened
- What was accessed
- Stack trace

---

### Scenario 4: Out of Memory

**Symptoms:** Crash on allocation

**Debug:**
```bash
# Monitor memory
top -pid $(pgrep nullclaw)

# Or with Tracy
tracy &
# Check memory plot in Tracy
```

**Common causes:**
- Memory leak
- Unbounded allocation
- Circular references

---

## Proactive Crash Prevention

### 1. Use Error Handling

```zig
// Instead of:
const value = array[index]; // Can crash

// Use:
if (index < array.len) {
    const value = array[index];
} else {
    return error.IndexOutOfBounds;
}
```

### 2. Add Assertions

```zig
const std = @import("std");

fn process(data: []const u8) void {
    std.debug.assert(data.len > 0);
    // ... process data
}
```

### 3. Use Tracy Zones

```zig
const zone = profiling.zoneNamed(@src(), "critical_section");
// Crash here will show up in Tracy
```

### 4. Log Critical Paths

```zig
log.debug("Processing item {d} of {d}", .{ i, total });
```

---

## Crash Reporting

When reporting crashes, include:

1. **Panic message** (from enhanced handler)
2. **Stack trace** (from debugger or crash log)
3. **Steps to reproduce**
4. **NullClaw version**: `nullclaw version`
5. **OS/Platform**: macOS/Linux/Windows
6. **Build type**: Debug/Release
7. **Tracy capture** (if available)

---

## Future Improvements

### TODO: Add to NullClaw

1. **Crash dump writer**
   - Write crash info to file
   - Include stack trace
   - Include recent logs

2. **Signal handlers**
   - Catch SIGSEGV, SIGABRT
   - Print diagnostic info
   - Graceful shutdown

3. **Crash telemetry**
   - Optional crash reporting
   - Aggregate crash stats
   - Common crash patterns

4. **Watchdog timer**
   - Detect hangs
   - Auto-restart
   - Alert on repeated crashes

---

## Quick Reference

```bash
# Debug build
zig build -Doptimize=Debug

# With Tracy
zig build -Dtracy=true -Doptimize=Debug

# With ASAN
zig build -Dsanitize=address

# Run under debugger
lldb ./zig-out/bin/nullclaw
(lldb) run gateway

# Check crash logs (macOS)
ls ~/Library/Logs/DiagnosticReports/nullclaw*

# View crash report
cat ~/Library/Logs/DiagnosticReports/nullclaw_*.crash
```

---

**Enhanced panic handler active ✅**  
**Version:** Added March 13, 2026  
**Commit:** `current`

//! vm_manager.zig — Virtual machine manager for NullClaw.
//!
//! Provides a pooled VM manager backed onto Apple Virtualization Framework.
//! VMs are used for sandboxed code execution (vm_exec), not for RLM recursion.
//!
//! Boot strategy (macOS VZ):
//!   EFI boot with Alpine virt kernel + initramfs on a FAT32 ESP.
//!   Initramfs drops to emergency recovery shell (~ # prompt).
//!   Rootfs (ext4) mounted at /mnt/root. Python 3.12 available.
//!
//! Serial exec protocol:
//!   Commands are octal-encoded to avoid serial line discipline mangling.
//!   Written to /tmp/c.sh in the VM, sourced (not spawned) so env persists.
//!   LD_LIBRARY_PATH and PATH are prepended to every command.
//!
//! Performance (measured):
//!   Boot: ~5.6s (one-time)
//!   Exec: ~40-60ms per command (echo, python, etc.)

const std = @import("std");
const log = std.log.scoped(.vm);

// ---- C declarations for VZ wrapper (ObjC compiled separately) ----

extern fn vz_available() c_int;

/// Direct kernel boot (LinuxBootLoader, raw ARM64 Image).
extern fn vz_create(
    ram: u64,
    cpus: c_uint,
    kernel: [*:0]const u8,
    initrd: [*:0]const u8,
    cmdline: [*:0]const u8,
    disk: [*:0]const u8,
    to_vm: *c_int,
    from_vm: *c_int,
) ?*anyopaque;

/// EFI boot (VZEFIBootLoader, FAT32 ESP disk + optional rootfs disk).
extern fn vz_create_efi(
    ram: u64,
    cpus: c_uint,
    esp_disk: [*:0]const u8,
    boot_args: [*:0]const u8,
    rootfs_disk: [*:0]const u8,
    to_vm: *c_int,
    from_vm: *c_int,
) ?*anyopaque;

extern fn vz_start(vm: *anyopaque) c_int;
extern fn vz_stop(vm: *anyopaque) c_int;
extern fn vz_read(vm: *anyopaque, buf: [*]u8, len: usize, timeout_ms: c_int) isize;
extern fn vz_write(vm: *anyopaque, buf: [*]const u8, len: usize) isize;
extern fn vz_destroy(vm: *anyopaque) void;

// ---- Backend enum ----

pub const Backend = enum {
    vz, // Apple Virtualization Framework (macOS)
};

// ---- Boot mode ----

pub const BootMode = enum {
    /// Direct kernel boot: VZLinuxBootLoader with raw ARM64 Image + initrd + cmdline.
    direct,
    /// EFI boot: VZEFIBootLoader with FAT32 ESP disk containing kernel + initramfs.
    /// Rootfs is a separate disk mounted at runtime.
    efi,
};

// ---- VM config ----

pub const VmConfig = struct {
    ram_bytes: u64 = 512 * 1024 * 1024, // 512 MB default
    cpu_count: u32 = 2,
    boot_mode: BootMode = .efi,

    // Direct boot fields
    kernel_path: []const u8 = "",
    initrd_path: []const u8 = "",
    cmdline: []const u8 = "console=ttyS0 panic=1 quiet",

    // EFI boot fields
    esp_path: []const u8 = "",
    rootfs_path: []const u8 = "",

    // Shared
    disk_path: []const u8 = "", // alias for rootfs_path in direct mode
    exec_timeout_ms: u32 = 30_000, // 30s max execution
    boot_timeout_ms: u32 = 30_000, // 30s max boot
    serial_read_timeout_ms: u32 = 100, // 100ms poll interval

    /// Shell prompt pattern to detect in serial output.
    shell_prompt: []const u8 = "~ #",
};

// ---- VM state ----

pub const VmState = enum {
    stopped,
    running,
    paused,
    failed,
};

// ---- VM handle ----

pub const Vm = struct {
    handle: *anyopaque,
    config: VmConfig,
    state: VmState = .stopped,
    backend: Backend = .vz,
    /// True after the VM has booted and the environment is set up.
    shell_ready: bool = false,

    pub fn start(self: *Vm) !void {
        const rc = vz_start(self.handle);
        if (rc != 0) return error.VmStartFailed;
        self.state = .running;
    }

    pub fn stop(self: *Vm) void {
        _ = vz_stop(self.handle);
        self.state = .stopped;
        self.shell_ready = false;
    }

    pub fn destroy(self: *Vm) void {
        if (self.state == .running) self.stop();
        vz_destroy(self.handle);
        self.handle = undefined;
    }

    /// Read from serial until a marker string is found or timeout.
    /// Returns the total bytes read (including the marker).
    pub fn readUntil(self: *Vm, allocator: std.mem.Allocator, marker: []const u8, timeout_ms: u64) ![]u8 {
        var output: std.ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(allocator);

        var buf: [4096]u8 = undefined;
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const deadline_ms = @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, @intCast(tv.usec)), 1000) + @as(i64, @intCast(timeout_ms));

        while (true) {
            _ = std.c.gettimeofday(&tv, null);
            const now_ms = @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, @intCast(tv.usec)), 1000);
            if (now_ms >= deadline_ms) break;
            const remaining = @max(0, @as(u64, @intCast(deadline_ms - now_ms)));
            const poll_timeout = @min(remaining, self.config.serial_read_timeout_ms);

            const n = vz_read(self.handle, &buf, buf.len, @intCast(poll_timeout));
            if (n < 0) continue; // Read timeout or error — just retry
            if (n > 0) {
                try output.appendSlice(allocator, buf[0..@intCast(n)]);
                if (marker.len > 0) {
                    if (std.mem.indexOf(u8, output.items, marker) != null) {
                        return output.toOwnedSlice(allocator);
                    }
                }
            }
        }

        return output.toOwnedSlice(allocator);
    }

    /// Write bytes to the VM's serial port.
    pub fn writeAll(self: *Vm, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            const n = vz_write(self.handle, remaining.ptr, remaining.len);
            if (n <= 0) return error.WriteFailed;
            remaining = remaining[@intCast(n)..];
        }
    }

    /// Write a line (data + \n) to the VM's serial port.
    pub fn writeLine(self: *Vm, line: []const u8) !void {
        try self.writeAll(line);
        try self.writeAll("\n");
    }

    /// Execute a shell command in the VM and return its stdout/stderr output.
    ///
    /// Protocol:
    ///   1. Prepend LD_LIBRARY_PATH and PATH exports to the command
    ///   2. Octal-encode the full command (avoids serial line discipline mangling)
    ///   3. Write via printf to /tmp/c.sh, then SOURCE it (. /tmp/c.sh)
    ///      — sourcing preserves exports across calls
    ///   4. Read until shell prompt, parse output between echo and prompt
    pub fn exec(self: *Vm, allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
        if (!self.shell_ready) return error.ShellNotReady;

        // Environment prefix — prepend to every command so it persists
        // even though each call sources a new shell invocation
        const env_prefix =
            "export LD_LIBRARY_PATH=/mnt/root/usr/lib:/mnt/root/lib; " ++
            "export PATH=/mnt/root/usr/bin:/mnt/root/sbin:/usr/sbin:/sbin:/bin:/usr/bin; ";

        // Build the full command with env prefix
        const full_command = try std.mem.concat(allocator, u8, &.{ env_prefix, command });
        defer allocator.free(full_command);

        // Octal-encode: each byte becomes \NNN
        var encoded: std.ArrayListUnmanaged(u8) = .empty;
        defer encoded.deinit(allocator);
        try encoded.ensureTotalCapacity(allocator, full_command.len * 4);
        for (full_command) |ch| {
            var octal_buf: [4]u8 = undefined;
            const octal = std.fmt.bufPrint(&octal_buf, "\\{o:03}", .{ch}) catch unreachable;
            try encoded.appendSlice(allocator, octal);
        }

        // Build: printf '<encoded>' > /tmp/c.sh; . /tmp/c.sh
        // Note: we SOURCE the script (. /tmp/c.sh) not spawn (sh /tmp/c.sh)
        // so that export statements affect the shell that echoes output
        var cmd_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer cmd_buf.deinit(allocator);
        try cmd_buf.ensureTotalCapacity(allocator, encoded.items.len + 50);
        try cmd_buf.appendSlice(allocator, "printf '");
        try cmd_buf.appendSlice(allocator, encoded.items);
        try cmd_buf.appendSlice(allocator, "' > /tmp/c.sh; . /tmp/c.sh");

        // Send the command
        try self.writeLine(cmd_buf.items);

        // Read until prompt appears
        const raw = try self.readUntil(allocator, self.config.shell_prompt, self.config.exec_timeout_ms);
        defer allocator.free(raw);

        // Strip CR characters
        var cleaned: std.ArrayListUnmanaged(u8) = .empty;
        defer cleaned.deinit(allocator);
        try cleaned.ensureTotalCapacity(allocator, raw.len);
        for (raw) |ch| {
            if (ch != '\r') try cleaned.append(allocator, ch);
        }
        const text = cleaned.items;

        // Find ". /tmp/c.sh" in the output (command echo), skip past it
        const sh_marker = ". /tmp/c.sh";
        var output_start: usize = 0;
        if (std.mem.indexOf(u8, text, sh_marker)) |idx| {
            if (std.mem.indexOfScalar(u8, text[idx..], '\n')) |nl| {
                output_start = idx + nl + 1;
            }
        }

        // Find the last prompt occurrence
        const prompt = self.config.shell_prompt;
        var prompt_end: usize = text.len;
        var search_from: usize = output_start;
        while (std.mem.indexOf(u8, text[search_from..], prompt)) |idx| {
            prompt_end = search_from + idx;
            search_from = prompt_end + 1;
        }

        // Extract output between echo and prompt
        var output = text[output_start..prompt_end];

        // Trim leading/trailing whitespace
        while (output.len > 0 and (output[0] == '\n' or output[0] == ' ')) output = output[1..];
        while (output.len > 0 and (output[output.len - 1] == '\n' or output[output.len - 1] == ' '))
            output = output[0 .. output.len - 1];

        return allocator.dupe(u8, output);
    }
};

// ---- VmManager (pooled) ----

/// Global state for the singleton VM pool.
/// Uses a spinlock for thread safety (gateway handles requests on multiple threads).
var global_vm_manager: ?PooledVmManager = null;
var global_vm_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub const PooledVmManager = struct {
    allocator: std.mem.Allocator,
    vm: ?Vm = null,
    config: VmConfig,

    pub fn init(allocator: std.mem.Allocator, config: VmConfig) !@This() {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.vm) |*v| {
            v.destroy();
            self.vm = null;
        }
    }

    pub fn isAvailable() bool {
        return vz_available() == 1;
    }

    /// Ensure the VM is booted and environment is ready.
    /// Idempotent — safe to call multiple times.
    pub fn ensureReady(self: *@This()) !void {
        if (self.vm != null and self.vm.?.shell_ready) return;

        // Create VM
        var to_fd: c_int = -1;
        var from_fd: c_int = -1;

        const handle = switch (self.config.boot_mode) {
            .direct => blk: {
                const kernel_z = try self.allocator.dupeZ(u8, self.config.kernel_path);
                defer self.allocator.free(kernel_z);
                const initrd_z = if (self.config.initrd_path.len > 0)
                    try self.allocator.dupeZ(u8, self.config.initrd_path)
                else
                    @as([:0]u8, @constCast(&[_:0]u8{0}));
                defer if (self.config.initrd_path.len > 0) self.allocator.free(initrd_z);
                const cmdline_z = try self.allocator.dupeZ(u8, self.config.cmdline);
                defer self.allocator.free(cmdline_z);
                const disk_z = if (self.config.disk_path.len > 0)
                    try self.allocator.dupeZ(u8, self.config.disk_path)
                else
                    @as([:0]u8, @constCast(&[_:0]u8{0}));
                defer if (self.config.disk_path.len > 0) self.allocator.free(disk_z);

                break :blk vz_create(
                    self.config.ram_bytes,
                    self.config.cpu_count,
                    kernel_z.ptr,
                    initrd_z.ptr,
                    cmdline_z.ptr,
                    disk_z.ptr,
                    &to_fd,
                    &from_fd,
                ) orelse return error.VmCreateFailed;
            },
            .efi => blk: {
                // Allocate all C strings upfront — defer frees them after vz_create_efi returns
                const esp_z = try self.allocator.dupeZ(u8, self.config.esp_path);
                defer self.allocator.free(esp_z);
                const args_z = if (self.config.cmdline.len > 0)
                    try self.allocator.dupeZ(u8, self.config.cmdline)
                else
                    @as([:0]u8, @constCast(&[_:0]u8{0}));
                defer if (self.config.cmdline.len > 0) self.allocator.free(args_z);
                const rootfs_z = if (self.config.rootfs_path.len > 0)
                    try self.allocator.dupeZ(u8, self.config.rootfs_path)
                else
                    @as([:0]u8, @constCast(&[_:0]u8{0}));
                defer if (self.config.rootfs_path.len > 0) self.allocator.free(rootfs_z);

                break :blk vz_create_efi(
                    self.config.ram_bytes,
                    self.config.cpu_count,
                    esp_z.ptr,
                    args_z.ptr,
                    rootfs_z.ptr,
                    &to_fd,
                    &from_fd,
                ) orelse return error.VmCreateFailed;
            },
        };

        var vm = Vm{
            .handle = handle,
            .config = self.config,
            .state = .stopped,
        };

        try vm.start();
        log.info("VM started (boot_mode={s}, ram={d}MB, cpus={d})", .{
            @tagName(self.config.boot_mode),
            self.config.ram_bytes / (1024 * 1024),
            self.config.cpu_count,
        });

        // Wait for shell prompt
        const output = try vm.readUntil(self.allocator, self.config.shell_prompt, self.config.boot_timeout_ms);
        defer self.allocator.free(output);

        if (std.mem.indexOf(u8, output, self.config.shell_prompt) == null) {
            log.warn("VM boot: shell prompt not found in {d} bytes of output", .{output.len});
            vm.destroy();
            return error.BootTimeout;
        }

        log.info("VM shell prompt detected ({d} bytes boot output)", .{output.len});

        // Mark shell ready BEFORE setup commands (they use exec which checks shell_ready)
        vm.shell_ready = true;

        // Mount rootfs using octal-encoded exec (avoids serial mangling)
        _ = try vm.exec(self.allocator, "mkdir -p /mnt/root && mount -t ext4 /dev/vdb /mnt/root");

        // Verify Python is accessible
        const test_out = try vm.exec(self.allocator, "python3 --version");
        defer self.allocator.free(test_out);
        log.info("VM ready: {s}", .{test_out});

        self.vm = vm;
    }

    /// Execute code in the VM. Boot + setup happens lazily on first call.
    /// Subsequent calls reuse the same running VM (~40-60ms per exec).
    pub fn execCode(self: *@This(), command: []const u8) ![]const u8 {
        try self.ensureReady();
        return self.vm.?.exec(self.allocator, command);
    }
};

// ---- Public API (global pool) ----

/// Get or create the global pooled VM manager.
/// Thread-safe via spinlock.
pub fn getGlobalManager(allocator: std.mem.Allocator) !*PooledVmManager {
    // Fast path: already initialized
    if (global_vm_manager != null) return &global_vm_manager.?;

    // Slow path: acquire lock
    while (global_vm_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        // Spin — another thread is initializing
        std.atomic.spinLoopHint();
        if (global_vm_manager != null) return &global_vm_manager.?;
    }
    defer global_vm_lock.store(false, .release);

    // Double-check after acquiring lock
    if (global_vm_manager != null) return &global_vm_manager.?;

    const default_config = VmConfig{
        .boot_mode = .efi,
        .esp_path = "/Users/jean/dev/nullclaw/vm/esp.img",
        .rootfs_path = "/Users/jean/dev/nullclaw/vm/rootfs.img",
    };

    const manager = try PooledVmManager.init(allocator, default_config);
    global_vm_manager = manager;
    return &global_vm_manager.?;
}

/// Check if Apple Virtualization Framework is available at runtime.
pub fn isAvailable() bool {
    return vz_available() == 1;
}

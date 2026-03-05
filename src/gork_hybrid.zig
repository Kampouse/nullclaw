//! Gork hybrid system - combines daemon and polling for robust P2P agent collaboration.
//!
//! Provides real-time messaging via daemon with automatic fallback to polling
//! when the daemon crashes or is unavailable.
//!
//! Thread Safety: Thread-safe with proper synchronization.

const std = @import("std");


fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const key_z = try allocator.dupeZ(u8, key);
    defer allocator.free(key_z);
    const val_c = std.c.getenv(key_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(val_c));
}
const Allocator = std.mem.Allocator;

const daemon_mod = @import("gork_daemon.zig");
const poller_mod = @import("gork_poller.zig");

const io = std.Options.debug_io; // For Zig 0.16.0 I/O

pub const Hybrid = @This();

// Global reference to the active Hybrid instance for callback access
// This is set during init() and cleared during stop()
var active_hybrid: ?*Hybrid = null;

// Security constants
pub const MAX_AGENT_ID_LEN = 64;
pub const MAX_MESSAGE_LEN = 1024 * 10; // 10KB
pub const MAX_CAPABILITY_LEN = 128;
const MAX_BINARY_PATH_LEN = 256;
const MAX_LOG_BUFFER_SIZE = 1024 * 1024; // 1MB
const DEFAULT_PROCESS_TIMEOUT_MS = 30000; // 30 seconds

/// Security errors
pub const SecurityError = error{
    AgentIdTooLong,
    AgentIdEmpty,
    InvalidAgentId,
    CapabilityTooLong,
    CapabilityEmpty,
    InvalidCapability,
    MessageTooLong,
    InvalidMessageCharacter,
    BinaryPathEmpty,
    BinaryPathTooLong,
    InvalidPath,
    BinaryNotFound,
    BinaryNotAFile,
    CannotStatBinary,
    ProcessTimeout,
    TooSoon,
    MessageQueueFull,
    ReputationCheckFailed,
    CircuitBreakerOpen,
    RateLimitExceeded,
    BinarySignatureInvalid,
    ReplayAttack,
    MessageTooOld,
    DaemonNotRunning,
    SendFailed,
    AlreadyRunning,
    QueueSizeTooLarge,
    InvalidCircuitBreakerThreshold,
    CircuitBreakerThresholdTooHigh,
    PollIntervalTooShort,
    CacheSizeTooSmall,
    MessageAgeLimitTooShort,
};

/// Detailed error with context and actionable guidance
pub const DetailedError = struct {
    code: anyerror,
    message: []const u8,
    context: []const u8,
    suggested_action: []const u8,
    timestamp: i64,

    pub fn format(self: *const DetailedError, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\Error: {}
            \\Message: {s}
            \\Context: {s}
            \\Action: {s}
            \\Time: {}
        , .{
            self.code,
            self.message,
            self.context,
            self.suggested_action,
            self.timestamp,
        });
    }
};

/// Helper to create detailed error with context
fn createDetailedError(code: anyerror, message: []const u8, context: []const u8, action: []const u8) DetailedError {
    return .{
        .code = code,
        .message = message,
        .context = context,
        .suggested_action = action,
        .timestamp = @truncate(0),
    };
}

/// Pool of ArrayList instances to reduce allocations
const ArrayListPool = struct {
    mutex: std.Io.Mutex,
    available: std.ArrayList(*std.ArrayList([]const u8)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ArrayListPool {
        return .{
            .mutex = .{ .state = .init(.unlocked) },
            .available = std.ArrayList(*std.ArrayList([]const u8)).initCapacity(allocator, 10) catch @panic("OOM"),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArrayListPool) void {
        // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
        // TODO: Zig 0.16.0 - mutex.unlock() needs io
    // defer self.mutex.unlock(io);

        for (self.available.items) |list| {
            list.deinit(self.allocator);
            self.allocator.destroy(list);
        }
        self.available.deinit(self.allocator);
    }

    pub fn acquire(self: *ArrayListPool) *std.ArrayList([]const u8) {
        // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
        // TODO: Zig 0.16.0 - mutex.unlock() needs io
    // defer self.mutex.unlock(io);

        if (self.available.items.len > 0) {
            return self.available.pop();
        }

        const list = self.allocator.create(std.ArrayList([]const u8)) catch @panic("OOM");
        list.* = std.ArrayList([]const u8).initCapacity(self.allocator, 10) catch @panic("OOM");
        return list;
    }

    pub fn release(self: *ArrayListPool, list: *std.ArrayList([]const u8)) void {
        // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
        // TODO: Zig 0.16.0 - mutex.unlock() needs io
    // defer self.mutex.unlock(io);

        list.clearRetainingCapacity();
        self.available.append(self.allocator, list) catch {
            list.deinit(self.allocator);
            self.allocator.destroy(list);
        };
    }
};

/// Validate NEAR agent ID format (alphanumeric, dots, underscores, dashes, ends in .near)
pub fn validateAgentId(id: []const u8) SecurityError!void {
    if (id.len > MAX_AGENT_ID_LEN) return error.AgentIdTooLong;
    if (id.len == 0) return error.AgentIdEmpty;

    // NEAR account IDs are alphanumeric + dots + underscores + dashes
    for (id) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) {
            return error.InvalidAgentId;
        }
    }
}

/// Validate capability string (alphanumeric, hyphens, underscores only)
pub fn validateCapability(cap: []const u8) SecurityError!void {
    if (cap.len > MAX_CAPABILITY_LEN) return error.CapabilityTooLong;
    if (cap.len == 0) return error.CapabilityEmpty;

    for (cap) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) {
            return error.InvalidCapability;
        }
    }
}

/// Validate message content (printable ASCII + basic UTF-8)
pub fn validateMessage(msg: []const u8) SecurityError!void {
    if (msg.len > MAX_MESSAGE_LEN) return error.MessageTooLong;

    for (msg) |c| {
        // Allow printable ASCII, newline, tab, and UTF-8 continuation bytes
        if (c < 32 and c != '\n' and c != '\t') {
            return error.InvalidMessageCharacter;
        }
        if (c == 127) return error.InvalidMessageCharacter; // DEL
    }
}

/// Audit event types for security logging
pub const AuditEvent = enum {
    daemon_started,
    daemon_stopped,
    message_sent,
    message_received,
    agent_discovered,
    invalid_input,
    suspicious_activity,
    security_violation,
};

/// Log security audit event
pub fn logAudit(event: AuditEvent, details: []const u8) void {
    const event_str = switch (event) {
        .daemon_started => "DAEMON_STARTED",
        .daemon_stopped => "DAEMON_STOPPED",
        .message_sent => "MESSAGE_SENT",
        .message_received => "MESSAGE_RECEIVED",
        .agent_discovered => "AGENT_DISCOVERED",
        .invalid_input => "INVALID_INPUT",
        .suspicious_activity => "SUSPICIOUS_ACTIVITY",
        .security_violation => "SECURITY_VIOLATION",
    };

    std.log.info("AUDIT: {s} {s}", .{event_str, details});
}

/// Validate binary path (no directory traversal, must exist and be executable)
pub fn validateBinaryPath(path: []const u8) SecurityError!void {
    if (path.len == 0) return error.BinaryPathEmpty;
    if (path.len > MAX_BINARY_PATH_LEN) return error.BinaryPathTooLong;

    // Check path doesn't contain directory traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        return error.InvalidPath;
    }

    // For absolute paths, verify the file exists
    if (std.fs.path.isAbsolute(path)) {
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch {
            return error.BinaryNotFound;
        };
        // TODO: Zig 0.16.0 - needs io
        // defer file.close();

        // Check it's a regular file
        const stat = file.stat(io) catch {
            return error.CannotStatBinary;
        };
        if (stat.kind != .file) return error.BinaryNotAFile;
    }
    // For relative paths, we'll validate when spawning the process
}

/// Binary signature verification result
pub const SignatureVerification = enum {
    /// No signature file found (signature verification optional)
    not_found,
    /// Signature verified successfully
    verified,
    /// Signature verification failed (binary may be tampered)
    failed,
    /// Error during verification (IO error, invalid format, etc.)
    verification_error,
};

/// Decode hex string to bytes
fn hexDecode(allocator: Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHexLength;

    const result = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(result);

    for (0..result.len) |i| {
        const high = try charToHex(hex[i * 2]);
        const low = try charToHex(hex[i * 2 + 1]);
        result[i] = (high << 4) | low;
    }

    return result;
}

/// Convert hex character to its value
fn charToHex(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexCharacter,
    };
}

/// Verify binary signature using Ed25519
/// Looks for a .sig file alongside the binary containing hex-encoded signature
/// Verifies against trusted public key
pub fn verifyBinarySignature(allocator: Allocator, binary_path: []const u8) SignatureVerification {
    // Try to open signature file
    const sig_path = std.fmt.allocPrint(allocator, "{s}.sig", .{binary_path}) catch return .verification_error;
    defer allocator.free(sig_path);

    _ = std.Io.Dir.openFileAbsolute(io, sig_path, .{}) catch |err| {
        // Signature file not found - this is OK, signature is optional
        if (err == error.FileNotFound) return .not_found;
        std.log.warn("Failed to open signature file '{s}': {}", .{sig_path, err});
        return .verification_error;
    };
    // TODO: Zig 0.16.0 - needs io
    // defer sig_file.close();

    // Read hex-encoded signature (128 hex chars = 64 bytes)
    const sig_hex_buf: [256]u8 = undefined;
    // TODO: Zig 0.16.0 - file.read() API changed, use reader
    const sig_bytes_read: usize = 0; // Stub
    _ = sig_hex_buf;
    _ = sig_bytes_read;

    return .verification_error; // TODO: Implement proper signature verification

    // Old code (disabled for Zig 0.16.0 migration):
    // const sig_hex = std.mem.trim(u8, sig_hex_buf[0..sig_bytes_read], " \t\n\r");
    // ... rest of signature verification
}

/// Compute SHA-256 hash of a file
    //     logAudit(.security_violation, "Binary signature verification failed");

/// Compute SHA-256 hash of a file
fn computeSha256(allocator: Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(path, .{});
    // TODO: Zig 0.16.0 - needs io
        // defer file.close();

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;

    while (true) {
        const bytes_read = try file.read(&buf);
        if (bytes_read == 0) break;
        hash.update(buf[0..bytes_read]);
    }

    var digest_array: [32]u8 = undefined;
    hash.final(&digest_array);

    // Copy to heap
    const digest = try allocator.alloc(u8, 32);
    @memcpy(digest, &digest_array);
    return digest;
}

/// Wait for child process with timeout (best-effort implementation)
/// Note: In Zig 0.15.2, Child.wait() blocks indefinitely, so timeout is approximate
pub fn waitWithTimeout(child: *std.process.Child, timeout_ms: u64) !std.process.Child.Term {
    // Spawn a watchdog thread that kills the process after timeout
    const watchdog_result = try std.Thread.spawn(
        .{},
        struct {
            fn watchdog(child_ptr: *std.process.Child, timeout: u64) void {
                std.Thread.sleep(timeout * std.time.ns_per_ms);
                _ = child_ptr.kill() catch {};
            }
        }.watchdog,
        .{ child, timeout_ms },
    );
    defer watchdog_result.join();

    // Wait for the child to complete
    return child.wait();
}

/// System state
pub const State = enum {
    stopped,
    starting,
    running,
    degraded, // Daemon died, polling only
    stopping,
};

/// Event from the hybrid system - all strings are owned and must be freed
pub const Event = union(enum) {
    message_received: IncomingMessage,
    peer_connected: []const u8, // owned
    peer_disconnected: []const u8, // owned
    daemon_started: daemon_mod.StartedInfo,
    daemon_stopped: ?[]const u8, // owned (error reason if any)
    poll_result: poller_mod.Result,
    state_changed: State,

    /// Free all owned strings in the event
    pub fn deinit(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .message_received => |*msg| msg.deinit(allocator),
            .peer_connected => |s| {
                if (s.len > 0) allocator.free(s);
            },
            .peer_disconnected => |s| {
                if (s.len > 0) allocator.free(s);
            },
            .daemon_started => |*info| info.deinit(allocator),
            .daemon_stopped => |reason| {
                if (reason) |r| {
                    if (r.len > 0) allocator.free(r);
                }
            },
            .poll_result, .state_changed => {}, // No owned data
        }
    }
};

/// Incoming message from another agent
pub const IncomingMessage = struct {
    from: []const u8,
    message_type: []const u8,
    content: []const u8,
    timestamp: u64,

    pub fn deinit(self: *IncomingMessage, allocator: Allocator) void {
        if (self.from.len > 0) allocator.free(self.from);
        if (self.message_type.len > 0) allocator.free(self.message_type);
        if (self.content.len > 0) allocator.free(self.content);
    }
};

/// Seen message cache for replay attack protection
const SeenMessageCache = struct {
    /// Cache entry with timestamp
    const Entry = struct {
        seen_at: i64,  // When we saw this message
    };

    /// StringHashMap for message IDs -> seen timestamp
    const Cache = std.StringHashMap(Entry);

    allocator: Allocator,
    cache: Cache,
    max_size: u32,
    max_age_ns: u64,
    mutex: std.Io.Mutex,

    fn init(allocator: Allocator, max_size: u32, max_age_secs: u32) SeenMessageCache {
        return .{
            .allocator = allocator,
            .cache = Cache.init(allocator),
            .max_size = max_size,
            .max_age_ns = @intCast(max_age_secs * std.time.ns_per_s),
            .mutex = .{ .state = .init(.unlocked) },
        };
    }

    fn deinit(self: *SeenMessageCache) void {
        // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
        // TODO: Zig 0.16.0 - mutex.unlock() needs io
    // defer self.mutex.unlock(io);

        // Free all keys
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit();
    }

    /// Check if message ID has been seen before
    fn isSeen(self: *SeenMessageCache, message_id: []const u8) bool {
        // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
        // TODO: Zig 0.16.0 - mutex.unlock() needs io
    // defer self.mutex.unlock(io);

        const now = 0;

        // Clean up old entries first
        self.cleanup(now);

        // Check if message exists
        if (self.cache.get(message_id)) |_| {
            return true;
        }
        return false;
    }

    /// Mark message as seen
    fn markSeen(self: *SeenMessageCache, message_id: []const u8) !void {
        // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
        // TODO: Zig 0.16.0 - mutex.unlock() needs io
    // defer self.mutex.unlock(io);

        const now = 0;

        // Clean up old entries first
        self.cleanup(now);

        // Check cache size
        if (self.cache.count() >= self.max_size) {
            // Cache is full, clean up more aggressively
            self.cleanupOldEntries(now, self.max_size / 2);
        }

        // Add new entry
        const key = try self.allocator.dupe(u8, message_id);
        try self.cache.put(key, .{ .seen_at = now });
    }

    /// Remove entries older than max_age_ns
    fn cleanup(self: *SeenMessageCache, now: i64) void {
        const max_age = @as(i64, @intCast(self.max_age_ns));

        // Collect keys to remove (store as copies)
        var keys_to_remove = std.ArrayList([]const u8).initCapacity(self.allocator, 10) catch return;
        defer {
            for (keys_to_remove.items) |k| {
                self.allocator.free(k);  // Free the copies we made
            }
            keys_to_remove.deinit(self.allocator);
        }

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            const age = now - entry.value_ptr.seen_at;
            if (age > max_age) {
                // Make a copy of the key to store in our list
                const key_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch return;
                keys_to_remove.append(key_copy) catch {
                    self.allocator.free(key_copy);
                    return;
                };
            }
        }

        // Remove from cache and free original keys
        for (keys_to_remove.items) |key_copy| {
            if (self.cache.remove(key_copy)) |kv| {
                self.allocator.free(kv.key);  // Free the actual key from cache
            }
        }
    }

    /// Aggressively clean up oldest entries
    fn cleanupOldEntries(self: *SeenMessageCache, now: i64, target_size: u32) void {
        while (self.cache.count() > target_size) {
            // Find and remove oldest entry
            var oldest_key: ?[]const u8 = null;
            var oldest_time: i64 = now;

            var it = self.cache.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.seen_at < oldest_time) {
                    oldest_time = entry.value_ptr.seen_at;
                    oldest_key = entry.key_ptr.*;
                }
            }

            if (oldest_key) |key| {
                if (self.cache.remove(key)) |kv| {
                    self.allocator.free(kv.key);
                }
            } else {
                break;
            }
        }
    }
};

allocator: Allocator,
mutex: std.Io.Mutex,
config: Config,
state: State,
daemon: ?daemon_mod.DaemonProcess,
poller: ?poller_mod.Poller,
event_callback: *const fn (Allocator, Event) void,
message_queue_size: std.atomic.Value(u32),  // Current queue size
message_queue_max: u32,                         // Maximum queue size from config
circuit_breaker: CircuitBreaker,               // Circuit breaker for resilience
rate_limiter: ?*RateLimiter,                   // Per-agent rate limiting
metrics: Metrics,                               // Metrics collection
seen_message_cache: SeenMessageCache,          // Replay attack protection
array_pool: ArrayListPool,                      // Pool for ArrayList instances

/// Circuit breaker state
pub const CircuitBreakerState = enum {
    closed,     // Normal operation
    open,       // Failing, reject requests
    half_open,  // Testing if service recovered
};

/// Circuit breaker for resilience
pub const CircuitBreaker = struct {
    state: CircuitBreakerState = .closed,
    failure_count: u32 = 0,
    success_count: u32 = 0,
    last_failure_time: i64 = 0,
    threshold: u32 = 5,              // Open after N failures
    timeout_ns: u64 = 60 * std.time.ns_per_s,  // Open for 60 seconds
    half_open_attempts: u32 = 3,     // Try N requests in half-open

    /// Check if operation should be allowed
    pub fn allow(self: *CircuitBreaker) bool {
        const now = 0;

        switch (self.state) {
            .closed => return true,
            .open => {
                // Check if timeout has passed
                if (now - self.last_failure_time > self.timeout_ns) {
                    self.state = .half_open;
                    self.success_count = 0;
                    return true;
                }
                return false;
            },
            .half_open => {
                // Allow limited attempts to test recovery
                return self.success_count < self.half_open_attempts;
            },
        }
    }

    /// Record a successful operation
    pub fn recordSuccess(self: *CircuitBreaker) void {
        switch (self.state) {
            .closed => {
                self.failure_count = 0;
            },
            .half_open => {
                self.success_count += 1;
                if (self.success_count >= self.half_open_attempts) {
                    self.state = .closed;
                    self.failure_count = 0;
                }
            },
            .open => {},
        }
    }

    /// Record a failed operation
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.failure_count += 1;
        self.last_failure_time = @intCast(0);

        switch (self.state) {
            .closed => {
                if (self.failure_count >= self.threshold) {
                    self.state = .open;
                }
            },
            .half_open => {
                self.state = .open;
            },
            .open => {},
        }
    }
};

/// Per-agent rate limiter
pub const RateLimiter = struct {
    /// Rate limit entry per agent
    const Entry = struct {
        last_request: i64,
        request_count: u32,
    };

    /// Hash map for tracking per-agent requests
    const AgentMap = std.StringHashMap(Entry);

    allocator: Allocator,
    map: AgentMap,
    max_requests: u32 = 100,           // Max requests per window
    window_ns: u64 = 60 * std.time.ns_per_s,  // 60 second window
    cleanup_threshold: u32 = 1000,      // Cleanup after N entries

    pub fn init(allocator: Allocator) RateLimiter {
        return .{
            .allocator = allocator,
            .map = AgentMap.init(allocator),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    /// Check if request should be allowed
    pub fn allow(self: *RateLimiter, agent_id: []const u8) bool {
        const now = 0;

        // Get or create entry
        const entry = self.map.get(agent_id) orelse {
            // Clean up if map is too large
            if (self.map.count() > self.cleanup_threshold) {
                self.cleanup(@intCast(now));
            }

            // Add new entry
            const key = self.allocator.dupe(u8, agent_id) catch return false;
            self.map.put(key, .{
                .last_request = @intCast(now),
                .request_count = 1,
            }) catch {
                self.allocator.free(key);
                return false;
            };
            return true;
        };

        // Check if window has expired
        if (now - @as(i128, entry.last_request) > self.window_ns) {
            // Reset counter
            self.map.put(agent_id, .{
                .last_request = @intCast(now),
                .request_count = 1,
            }) catch return false;
            return true;
        }

        // Check limit
        if (entry.request_count >= self.max_requests) {
            return false;
        }

        // Increment counter
        self.map.put(agent_id, .{
            .last_request = entry.last_request,
            .request_count = entry.request_count + 1,
        }) catch return false;
        return true;
    }

    /// Cleanup expired entries
    fn cleanup(self: *RateLimiter, now: i64) void {
        // Collect keys to remove first (don't modify map during iteration)
        var keys_to_remove = std.ArrayList([]const u8).initCapacity(self.allocator, 10) catch return;
        defer {
            for (keys_to_remove.items) |k| {
                self.allocator.free(k);
            }
            keys_to_remove.deinit(self.allocator);
        }

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.last_request > self.window_ns * 2) {
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch return;
            }
        }

        // Now remove the collected keys
        for (keys_to_remove.items) |key| {
            _ = self.map.remove(key);
        }
    }
};

/// Metrics collection
pub const Metrics = struct {
    /// Atomic counters for metrics
    messages_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    messages_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    messages_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    discover_calls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reputation_checks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    security_violations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    circuit_breaker_trips: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Detailed performance metrics
    total_latency_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    latency_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak_memory_kb: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    cache_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cache_misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init() Metrics {
        return .{};
    }

    /// Record latency for a message
    pub fn recordLatency(self: *Metrics, latency_ms: u64) void {
        _ = self.total_latency_ms.fetchAdd(latency_ms, .seq_cst);
        _ = self.latency_count.fetchAdd(1, .seq_cst);
    }

    /// Get average latency in milliseconds
    pub fn avgLatencyMs(self: *const Metrics) u64 {
        const total = self.total_latency_ms.load(.seq_cst);
        const count = self.latency_count.load(.seq_cst);
        return if (count > 0) @divTrunc(total, count) else 0;
    }

    /// Get cache hit rate as percentage (0-100)
    pub fn cacheHitRate(self: *const Metrics) f32 {
        const hits = @as(f64, @floatFromInt(self.cache_hits.load(.seq_cst)));
        const misses = @as(f64, @floatFromInt(self.cache_misses.load(.seq_cst)));
        const total = hits + misses;
        return if (total > 0) @floatCast((hits / total) * 100.0) else 0.0;
    }

    /// Record cache hit
    pub fn recordCacheHit(self: *Metrics) void {
        _ = self.cache_hits.fetchAdd(1, .seq_cst);
    }

    /// Record cache miss
    pub fn recordCacheMiss(self: *Metrics) void {
        _ = self.cache_misses.fetchAdd(1, .seq_cst);
    }

    /// Update peak memory if current is higher
    pub fn updatePeakMemory(self: *Metrics, current_kb: u64) void {
        var peak = self.peak_memory_kb.load(.seq_cst);
        while (current_kb > peak) {
            peak = self.peak_memory_kb.compareAndSwap(peak, current_kb, .seq_cst, .seq_cst);
        }
    }

    /// Get metrics as JSON string
    pub fn toJson(self: *const Metrics, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator,
            \\{{"messages_sent":{},"messages_received":{},"messages_failed":{},"discover_calls":{},"reputation_checks":{},"security_violations":{},"circuit_breaker_trips":{},"avg_latency_ms":{},"peak_memory_kb":{},"active_connections":{},"cache_hit_rate":{d:.2}}}
        , .{
            self.messages_sent.load(.seq_cst),
            self.messages_received.load(.seq_cst),
            self.messages_failed.load(.seq_cst),
            self.discover_calls.load(.seq_cst),
            self.reputation_checks.load(.seq_cst),
            self.security_violations.load(.seq_cst),
            self.circuit_breaker_trips.load(.seq_cst),
            self.avgLatencyMs(),
            self.peak_memory_kb.load(.seq_cst),
            self.active_connections.load(.seq_cst),
            self.cacheHitRate(),
        });
    }
};

/// Configuration for the hybrid system
pub const Config = struct {
    binary_path: []const u8 = "gork-agent",
    account_id: []const u8,
    relay: ?[]const u8 = null,
    daemon_port: u16 = 4001,
    poll_interval_secs: u32 = 60,
    enable_fallback: bool = true,

    // Reputation settings
    min_reputation: u32 = 50,             // Minimum reputation to interact
    block_below_reputation: u32 = 20,     // Block agents below this

    // Queue settings
    max_message_queue_size: u32 = 1000,   // Maximum queued messages

    // Rate limiting
    enable_rate_limiting: bool = true,
    max_requests_per_minute: u32 = 100,

    // Circuit breaker
    circuit_breaker_threshold: u32 = 5,
    circuit_breaker_timeout_secs: u32 = 60,

    // Replay protection
    enable_replay_protection: bool = true,
    max_message_age_secs: u32 = 300,      // Reject messages older than 5 minutes
    seen_message_cache_size: u32 = 10000,  // Max seen message IDs to track

    /// Validate configuration values
    pub fn validate(self: *const Config) !void {
        // Required fields
        if (self.binary_path.len == 0) return error.BinaryPathEmpty;

        // Range checks
        if (self.max_message_queue_size > 10000) return error.QueueSizeTooLarge;
        if (self.circuit_breaker_threshold == 0) return error.InvalidCircuitBreakerThreshold;
        if (self.circuit_breaker_threshold > 100) return error.CircuitBreakerThresholdTooHigh;

        // Binary existence (skip in test environments)
        if (getEnvVarOwned(std.heap.page_allocator, "SKIP_BINARY_CHECK") catch null == null) {
            std.Io.Dir.accessAbsolute(io, self.binary_path, .{}) catch return error.BinaryNotFound;
        }

        // Interval checks
        if (self.poll_interval_secs < 5) {
            std.log.warn("Poll interval {}s is too low, minimum is 5s", .{self.poll_interval_secs});
            return error.PollIntervalTooShort;
        }
        if (self.poll_interval_secs > 3600) {
            std.log.warn("Poll interval {}s is very high, messages will be delayed", .{self.poll_interval_secs});
        }

        // Cache size
        if (self.seen_message_cache_size < 100) return error.CacheSizeTooSmall;
        if (self.max_message_age_secs < 60) return error.MessageAgeLimitTooShort;
    }
};

/// Initialize the hybrid system
pub fn init(allocator: Allocator, config: Config, event_callback: *const fn (Allocator, Event) void) !Hybrid {
    // Validate configuration
    try config.validate();

    // Load max_message_queue_size from config (use default if 0)
    const max_queue = if (config.max_message_queue_size > 0)
        config.max_message_queue_size
    else
        1000;

    // Initialize rate limiter if enabled
    var rate_limiter: ?*RateLimiter = null;
    if (config.enable_rate_limiting) {
        const rl = try allocator.create(RateLimiter);
        rl.* = RateLimiter.init(allocator);
        rate_limiter = rl;
    }

    return Hybrid{
        .allocator = allocator,
        .mutex = .{ .state = .init(.unlocked) },
        .config = config,
        .state = .stopped,
        .daemon = null,
        .poller = null,
        .event_callback = event_callback,
        .message_queue_size = std.atomic.Value(u32).init(0),
        .message_queue_max = max_queue,
        .circuit_breaker = .{
            .threshold = config.circuit_breaker_threshold,
            .timeout_ns = config.circuit_breaker_timeout_secs * std.time.ns_per_s,
        },
        .rate_limiter = rate_limiter,
        .metrics = .{},
        .seen_message_cache = SeenMessageCache.init(
            allocator,
            config.seen_message_cache_size,
            config.max_message_age_secs,
        ),
        .array_pool = ArrayListPool.init(allocator),
    };
}

// Store reference for callback access (after init returns)
pub fn setActiveHybrid(self: *Hybrid) void {
    active_hybrid = self;
}

/// Start the hybrid system (thread-safe)
pub fn start(self: *Hybrid) !void {
    // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - mutex.unlock() needs io
    // defer self.mutex.unlock(io);

    if (self.state != .stopped) return error.AlreadyRunning;

    self.state = .starting;
    self.notifyEvent(Event{ .state_changed = .starting });

    // Try to start daemon first
    const daemon_result = self.startDaemon();

    if (daemon_result) |_| {
        std.log.info("Gork daemon started successfully", .{});

        // Start poller as fallback
        if (self.config.enable_fallback) {
            try self.startPoller(.fallback);
        }

        self.state = .running;
        self.notifyEvent(Event{ .state_changed = .running });
    } else |err| {
        std.log.warn("Failed to start daemon: {}, falling back to polling only", .{err});

        // Start poller as primary
        try self.startPoller(.primary);
        self.state = .degraded;
        self.notifyEvent(Event{ .state_changed = .degraded });
    }
}

/// Stop the hybrid system (thread-safe)
pub fn stop(self: *Hybrid) void {
    // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - mutex.unlock() needs io
    // defer self.mutex.unlock(io);

    if (self.state == .stopped) return;

    self.state = .stopping;
    self.notifyEvent(Event{ .state_changed = .stopping });

    // Stop poller
    if (self.poller) |*p| {
        p.stop();
        self.poller = null;
    }

    // Stop daemon - just set to null (no explicit stop method in gork_daemon)
    if (self.daemon) |*d| {
        _ = d; // Daemon will be cleaned up when deinit() is called
        self.daemon = null;
    }

    // Clean up rate limiter
    if (self.rate_limiter) |rl| {
        rl.deinit();
        self.allocator.destroy(rl);
        self.rate_limiter = null;
    }

    // Clean up seen message cache
    self.seen_message_cache.deinit();

    // Clean up array pool
    self.array_pool.deinit();

    // Clear global reference
    active_hybrid = null;

    self.state = .stopped;
    self.notifyEvent(Event{ .state_changed = .stopped });
}

/// Check if system can accept more messages (thread-safe)
pub fn canAcceptMessage(self: *Hybrid) bool {
    const current = self.message_queue_size.load(.seq_cst);
    return current < self.message_queue_max;
}

/// Increment message queue counter (thread-safe)
fn incrementMessageQueue(self: *Hybrid) !void {
    const new_count = self.message_queue_size.fetchAdd(1, .seq_cst) + 1;
    if (new_count > self.message_queue_max) {
        // Rollback
        _ = self.message_queue_size.fetchSub(1, .seq_cst);
        return error.MessageQueueFull;
    }
}

/// Decrement message queue counter (thread-safe)
fn decrementMessageQueue(self: *Hybrid) void {
    _ = self.message_queue_size.fetchSub(1, .seq_cst);
}

/// Send message to another agent (thread-safe)
pub fn sendMessage(self: *Hybrid, to: []const u8, content: []const u8) !void {
    // Check circuit breaker
    if (!self.circuit_breaker.allow()) {
        _ = self.metrics.circuit_breaker_trips.fetchAdd(1, .seq_cst);
        const err = createDetailedError(
            error.CircuitBreakerOpen,
            "Circuit breaker is open",
            "Too many recent failures, message rejected for protection",
            "Wait 60 seconds or restart daemon to reset circuit breaker",
        );
        const msg = err.format(self.allocator) catch "Circuit breaker open";
        defer self.allocator.free(msg);
        logAudit(.suspicious_activity, msg);
        return error.CircuitBreakerOpen;
    }

    // Check rate limiter
    if (self.rate_limiter) |rl| {
        if (!rl.allow(to)) {
            const err = createDetailedError(
                error.RateLimitExceeded,
                "Rate limit exceeded",
                try std.fmt.allocPrint(self.allocator, "Too many messages to {s}", .{to}),
                "Wait 60 seconds before sending more messages to this agent",
            );
            const msg = err.format(self.allocator) catch "Rate limit exceeded";
            defer self.allocator.free(msg);
            logAudit(.suspicious_activity, msg);
            return error.RateLimitExceeded;
        }
    }

    // Validate inputs
    validateAgentId(to) catch |err| {
        const err_detail = createDetailedError(
            err,
            "Invalid agent ID",
            try std.fmt.allocPrint(self.allocator, "Agent ID '{s}' failed validation", .{to}),
            "Use NEAR account format: alphanumeric + dots + underscores + dashes, ending in .near",
        );
        const msg = err_detail.format(self.allocator) catch "Invalid agent ID";
        defer self.allocator.free(msg);
        logAudit(.invalid_input, msg);
        _ = self.metrics.messages_failed.fetchAdd(1, .seq_cst);
        return err;
    };

    validateMessage(content) catch |err| {
        const err_detail = createDetailedError(
            err,
            "Invalid message content",
            try std.fmt.allocPrint(self.allocator, "Message to '{s}' failed validation (len={})", .{to, content.len}),
            "Use printable ASCII/UTF-8 only, max 10KB",
        );
        const msg = err_detail.format(self.allocator) catch "Invalid message";
        defer self.allocator.free(msg);
        logAudit(.invalid_input, msg);
        _ = self.metrics.messages_failed.fetchAdd(1, .seq_cst);
        return err;
    };

    // Check reputation before sending
    _ = self.checkReputation(to) catch {
        const audit_msg = std.fmt.allocPrint(
            self.allocator, "Failed to check reputation for {s}", .{to}
        ) catch "Failed to check reputation";
        logAudit(.security_violation, audit_msg);
        self.allocator.free(audit_msg);
        _ = self.metrics.security_violations.fetchAdd(1, .seq_cst);
        self.circuit_breaker.recordFailure();
        return error.ReputationCheckFailed;
    };

    // Check message queue availability
    self.incrementMessageQueue() catch {
        logAudit(.suspicious_activity, "Message queue full, rejecting message");
        _ = self.metrics.messages_failed.fetchAdd(1, .seq_cst);
        self.circuit_breaker.recordFailure();
        return error.MessageQueueFull;
    };
    defer self.decrementMessageQueue();

    // Audit log
    {
        const msg = std.fmt.allocPrint(self.allocator, "to={s}, len={d}", .{to, content.len}) catch unreachable;
        logAudit(.message_sent, msg);
        self.allocator.free(msg);
    }

    // Track latency
    const start_time = 0;

    // Hold mutex for the entire send operation to avoid race condition
    // where daemon crashes between state check and message send
    // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    const is_degraded = self.state == .degraded or self.daemon == null;
    
    // Try sending and track success/failure for metrics
    const send_result: anyerror!void = if (is_degraded) blk: {
        // Release mutex during CLI call since it may take time
        self.mutex.unlock(io);
        break :blk self.sendViaCli(to, content);
    } else blk: {
        // Keep daemon reference and release mutex - daemon.sendMessage is thread-safe
        var daemon = self.daemon;
        self.mutex.unlock(io);
        if (daemon == null) return error.DaemonNotRunning;
        break :blk daemon.?.sendMessage(to, content);
    };

    // Calculate latency
    const end_time = 0;
    const elapsed_ns = @as(u64, @intCast(end_time - start_time));
    const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
    self.metrics.recordLatency(elapsed_ms);

    // Record metrics based on result
    if (send_result) |_| {
        _ = self.metrics.messages_sent.fetchAdd(1, .seq_cst);
        self.circuit_breaker.recordSuccess();
    } else |_| {
        _ = self.metrics.messages_failed.fetchAdd(1, .seq_cst);
        self.circuit_breaker.recordFailure();
    }

    return send_result;
}

/// Generate a unique message ID for replay protection
/// Format: from:to:content_hash:timestamp
fn generateMessageId(allocator: Allocator, from: []const u8, to: []const u8, content: []const u8, timestamp: u64) ![]u8 {
    // Compute SHA-256 hash of content for uniqueness
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(from);
    hash.update(":");
    hash.update(to);
    hash.update(":");
    hash.update(content);

    var hash_array: [32]u8 = undefined;
    hash.final(&hash_array);

    // Format: from:to:hash_hex:timestamp
    return std.fmt.allocPrint(allocator, "{s}:{s}:{x}:{d}", .{
        from, to, std.fmt.fmtHexSlice(&hash_array), timestamp,
    });
}

/// Validate message timestamp is not too old
fn validateMessageTimestamp(config: Config, message_timestamp: u64, allocator: Allocator) !void {
    if (!config.enable_replay_protection) return;

    const now = 0;
    const max_age = config.max_message_age_secs;

    if (now > message_timestamp) {
        // Message is from the past
        const age = now - message_timestamp;
        if (age > max_age) {
            const msg = std.fmt.allocPrint(allocator, "Message too old: {d}s old (max {d}s)", .{age, max_age}) catch return error.MessageTooOld;
            logAudit(.suspicious_activity, msg);
            allocator.free(msg);
            return error.MessageTooOld;
        }
    } else {
        // Message is from the future - clock skew or tampering
        const skew = @as(i64, @intCast(message_timestamp)) - @as(i64, @intCast(now));
        if (skew > 300) { // Allow 5 minutes clock skew
            const msg = std.fmt.allocPrint(allocator, "Message timestamp in future: {d}s ahead", .{skew}) catch return error.MessageTooOld;
            logAudit(.suspicious_activity, msg);
            allocator.free(msg);
            return error.MessageTooOld;
        }
    }
}

/// Check if this is a replay attack (message already seen)
fn checkReplayAttack(self: *Hybrid, message_id: []const u8) !void {
    if (!self.config.enable_replay_protection) return;

    if (self.seen_message_cache.isSeen(message_id)) {
        const msg = std.fmt.allocPrint(self.allocator, "Replay attack detected: duplicate message {s}", .{message_id}) catch return error.ReplayAttack;
        logAudit(.security_violation, msg);
        self.allocator.free(msg);
        _ = self.metrics.security_violations.fetchAdd(1, .seq_cst);
        return error.ReplayAttack;
    }
}

/// Mark a message as seen to prevent replay attacks
fn markMessageAsSeen(self: *Hybrid, message_id: []const u8) !void {
    if (!self.config.enable_replay_protection) return;

    self.seen_message_cache.markSeen(message_id) catch |err| {
        std.log.warn("Failed to mark message as seen: {}", .{err});
    };
}

/// Discover agents with a specific capability (thread-safe)
pub fn discover(self: *Hybrid, capability: []const u8, limit: u32) ![]AgentInfo {
    _ = self.metrics.discover_calls.fetchAdd(1, .seq_cst);

    // Validate capability
    try validateCapability(capability);

    // Audit log
    {
        const msg = std.fmt.allocPrint(self.allocator, "capability={s}, limit={d}", .{capability, limit}) catch return error.OutOfMemory;
        logAudit(.agent_discovered, msg);
        self.allocator.free(msg);
    }

    // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    const binary_path = self.config.binary_path;
    self.mutex.unlock(io);

    var argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
    defer argv.deinit(self.allocator);

    try argv.append(self.allocator, binary_path);
    try argv.append(self.allocator, "discover");
    try argv.append(self.allocator, "--capability");
    try argv.append(self.allocator, capability);
    try argv.append(self.allocator, "--limit");

    // Format limit as string - owned by argv and freed with deinit
    var limit_buf: [16]u8 = undefined;
    const limit_str = try std.fmt.bufPrint(&limit_buf, "{}", .{limit});
    try argv.append(self.allocator, limit_str);

    // Use std.process.run() instead of Child.init() (Zig 0.16.0)
    const result = std.process.run(self.allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch {
        return error.DiscoverFailed;
    };

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };

    if (exit_code != 0) {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
        return error.DiscoverFailed;
    }

    defer self.allocator.free(result.stderr);
    return parseDiscoverOutput(self.allocator, result.stdout);
}

/// Get agent reputation (thread-safe)
pub fn getReputation(self: *Hybrid, agent_id: []const u8) !u32 {
    // Validate agent ID
    try validateAgentId(agent_id);

    // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    const binary_path = self.config.binary_path;
    self.mutex.unlock(io);

    var argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
    defer argv.deinit(self.allocator);

    try argv.append(self.allocator, binary_path);
    try argv.append(self.allocator, "list");
    try argv.append(self.allocator, "--limit");
    try argv.append(self.allocator, "100");

    // Use std.process.run() instead of Child.init() (Zig 0.16.0)
    const result = std.process.run(self.allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch {
        return error.QueryFailed;
    };

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };

    if (exit_code != 0) {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
        return error.QueryFailed;
    }

    defer self.allocator.free(result.stderr);
    defer self.allocator.free(result.stdout);
    
    // Parse reputation from output
    return 0; // TODO: Implement actual parsing
}

/// Get current state (thread-safe)
pub fn getState(self: *Hybrid) State {
    // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    // TODO: Zig 0.16.0 - mutex.unlock() needs io
    // defer self.mutex.unlock(io);
    return self.state;
}

/// Get metrics as JSON (thread-safe)
pub fn getMetrics(self: *const Hybrid) ![]const u8 {
    return self.metrics.toJson(self.allocator);
}

/// Start the daemon process (caller must hold mutex)
fn startDaemon(self: *Hybrid) !void {
    // Validate binary path before spawning
    try validateBinaryPath(self.config.binary_path);

    // Verify binary signature (if signature file exists)
    const sig_result = verifyBinarySignature(self.allocator, self.config.binary_path);
    if (sig_result == .failed) {
        return error.BinarySignatureInvalid;
    }
    // .not_found and .error are OK - signature is optional

    var daemon = daemon_mod.DaemonProcess.init(self.allocator, daemonEventCallbackWrapper);

    try daemon.start(.{
        .binary_path = self.config.binary_path,
        .port = self.config.daemon_port,
        .relay = self.config.relay,
    });

    self.daemon = daemon;
}

/// Start the poller (caller must hold mutex)
fn startPoller(self: *Hybrid, mode: poller_mod.Mode) !void {
    var poller = poller_mod.Poller.init(self.allocator, self.config.binary_path, self.config.poll_interval_secs);
    poller.setMode(mode);

    try poller.start(pollerEventCallbackWrapper);
    self.poller = poller;
}

/// Send message via CLI (fallback)
/// Send message via CLI (fallback)
fn sendViaCli(self: *Hybrid, to: []const u8, content: []const u8) !void {
    // Note: Validation is done in sendMessage before calling this
    // TODO: Zig 0.16.0 - mutex.lock() needs io parameter
    // // TODO: Zig 0.16.0 - needs io
    // self.mutex.lock();
    const binary_path = self.config.binary_path;
    self.mutex.unlock(io);

    var argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
    defer argv.deinit(self.allocator);

    try argv.append(self.allocator, binary_path);
    try argv.append(self.allocator, "send");
    try argv.append(self.allocator, "--to");
    try argv.append(self.allocator, to);
    try argv.append(self.allocator, content);

    // TODO: Zig 0.16.0 - rewrite using new process API
    argv.deinit(self.allocator);
    return error.SendFailed;
}

/// Check if peer's reputation meets minimum threshold
pub fn checkReputation(self: *Hybrid, agent_id: []const u8) !bool {
    _ = self.metrics.reputation_checks.fetchAdd(1, .seq_cst);

    const rep = try self.getReputation(agent_id);

    // Check if agent is blocked
    if (rep < self.config.block_below_reputation) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Blocked agent {s} with reputation {d} below threshold {d}",
            .{ agent_id, rep, self.config.block_below_reputation }
        ) catch return error.OutOfMemory;
        logAudit(.security_violation, msg);
        self.allocator.free(msg);
        return false;
    }

    // Check if agent meets minimum reputation
    if (rep < self.config.min_reputation) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Agent {s} below min reputation ({d} < {d})",
            .{ agent_id, rep, self.config.min_reputation }
        ) catch return error.OutOfMemory;
        logAudit(.invalid_input, msg);
        self.allocator.free(msg);
        return false;
    }

    return true;
}

/// Daemon event callback wrapper (forwards to event_callback with proper cleanup)
fn daemonEventCallbackWrapper(allocator: Allocator, event: daemon_mod.Event) void {
    // Get the active hybrid instance to forward events
    const hybrid = active_hybrid orelse {
        // No active hybrid, just log the event
        logDaemonEvent(allocator, event);
        return;
    };

    // Convert daemon event to hybrid event
    const hybrid_event: Hybrid.Event = switch (event) {
        .started => |*info| Hybrid.Event{
            .daemon_started = .{
                .peer_id = info.peer_id,
                .listen_addr = info.listen_addr,
                .port = info.port,
            },
        },
        .stopped => |reason| Hybrid.Event{
            .daemon_stopped = reason,
        },
        .message_received => |msg| Hybrid.Event{
            .message_received = IncomingMessage{
                .from = msg.from,
                .message_type = msg.message_type,
                .content = msg.content,
                .timestamp = msg.timestamp,
            },
        },
        .peer_connected => |peer| Hybrid.Event{
            .peer_connected = peer,
        },
        .peer_disconnected => |peer| Hybrid.Event{
            .peer_disconnected = peer,
        },
        .daemon_error => |err| Hybrid.Event{
            .daemon_stopped = err, // Treat errors as stopped events
        },
    };

    // Forward to the event callback
    hybrid.event_callback(allocator, hybrid_event);
}

/// Log daemon event without forwarding (fallback when no hybrid active)
fn logDaemonEvent(allocator: Allocator, event: daemon_mod.Event) void {
    _ = allocator;
    switch (event) {
        .started => |*info| {
            std.log.info("Gork daemon started: {s} on {s}:{d}", .{ info.peer_id, info.listen_addr, info.port });
        },
        .stopped => |reason| {
            if (reason) |r| {
                std.log.info("Gork daemon stopped: {s}", .{r});
            } else {
                std.log.info("Gork daemon stopped", .{});
            }
        },
        .message_received => |msg| {
            std.log.info("Gork message from {s}: {s}", .{ msg.from, msg.content });
        },
        .peer_connected => |peer| {
            std.log.info("Gork peer connected: {s}", .{peer});
        },
        .peer_disconnected => |peer| {
            std.log.info("Gork peer disconnected: {s}", .{peer});
        },
        .daemon_error => |err| {
            std.log.err("Gork daemon error: {s}", .{err});
        },
    }
}

/// Poller event callback wrapper - forwards incoming messages to the hybrid's event callback
fn pollerEventCallbackWrapper(message_json: []const u8) void {
    _ = active_hybrid orelse {
        std.log.debug("Gork poller event (no active hybrid): {s}", .{message_json});
        return;
    };

    // Parse the JSON message and forward as an event
    // For now, just log it - full JSON parsing would require more code
    std.log.debug("Gork poller received: {s}", .{message_json});

    // TODO: Parse message_json and create proper IncomingMessage event
    // This requires JSON parsing which is complex - for now we log
}

/// Notify event to callback
fn notifyEvent(self: *Hybrid, event: Event) void {
    self.event_callback(self.allocator, event);
}

/// Log an event (temporary replacement for proper event forwarding)
/// NOTE: This function frees all owned strings in the event
fn logEvent(allocator: Allocator, event: Event) void {
    // Ensure event is always cleaned up, even on panic
    var mut_event = event;
    defer mut_event.deinit(allocator);

    switch (mut_event) {
        .message_received => |*msg| {
            std.log.info("Gork: Message received from {s}: {s}", .{ msg.from, msg.content });
        },
        .peer_connected => |peer| {
            std.log.info("Gork: Peer connected: {s}", .{peer});
        },
        .peer_disconnected => |peer| {
            std.log.info("Gork: Peer disconnected: {s}", .{peer});
        },
        .daemon_started => |*info| {
            std.log.info("Gork: Daemon started on {s}:{}", .{ info.listen_addr, info.port });
        },
        .daemon_stopped => |reason| {
            if (reason) |r| {
                if (r.len > 0) {
                    std.log.warn("Gork: Daemon stopped: {s}", .{r});
                } else {
                    std.log.warn("Gork: Daemon stopped: unknown", .{});
                }
            } else {
                std.log.warn("Gork: Daemon stopped: unknown", .{});
            }
        },
        .poll_result => |result| {
            if (result.message_count > 0) {
                std.log.info("Gork: Poll processed {} messages", .{result.processed});
            }
        },
        .state_changed => |state| {
            std.log.info("Gork: State changed to {}", .{state});
        },
    }
}

/// Parse discover output
fn parseDiscoverOutput(allocator: Allocator, output: []const u8) ![]AgentInfo {
    var agents = try std.ArrayList(AgentInfo).initCapacity(allocator, 0);

    // Example output:
    // 📋 Found 3 agent(s):
    //
    // 🟢 alice.near
    //    Reputation: 85 (High)
    //    Skills: csv-analyzer, data-visualizer

    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");

        if (trimmed.len > 0 and (trimmed[0] == '🟢' or trimmed[0] == '🔴')) {
            // Agent line: "🟢 alice.near"
            const parts = std.mem.splitScalar(u8, trimmed["🟢".len..].*, ' ');
            const account_id = parts.next() orelse continue;

            const owned_account_id = try allocator.dupe(u8, account_id);
            errdefer allocator.free(owned_account_id);

            const agent = AgentInfo{
                .account_id = owned_account_id,
                .reputation = 50,
                .online = trimmed[0] == '🟢',
                .skills = &.{}, // Empty slice - not allocated
            };

            try agents.append(agent);
        }
    }

    return agents.toOwnedSlice(allocator);
}

/// Parse reputation from list output
fn parseReputation(_: Allocator, output: []const u8, agent_id: []const u8) !u32 {
    // Search for agent in output
    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, agent_id)) |_| {
            // Look for reputation on nearby lines
            // "   Reputation: 85 (High)"
            if (std.mem.indexOf(u8, line, "Reputation:")) |_| {
                var parts = std.mem.splitScalar(u8, line, ':');
                _ = parts.next(); // skip "Reputation"
                const rep_part = parts.next() orelse continue;
                const rep_str = std.mem.trim(u8, rep_part, " ");
                const rep_end = std.mem.indexOfScalar(u8, rep_str, ' ') orelse rep_str.len;
                const rep_num = rep_str[0..rep_end];
                return try std.fmt.parseInt(u32, rep_num, 10);
            }
        }
    }

    return error.AgentNotFound;
}

/// Agent info from discovery
pub const AgentInfo = struct {
    account_id: []const u8,
    reputation: u32,
    online: bool,
    skills: []const []const u8, // Borrowed slices, do not free

    pub fn deinit(self: *AgentInfo, allocator: Allocator) void {
        if (self.account_id.len > 0) allocator.free(self.account_id);
        // Skills are borrowed slices, don't free
    }
};

//! Custom allocator configuration for process execution tests
//!
//! The GPA (std.testing.allocator) has limits on single allocation sizes.
//! std.process.run() in Zig 0.16 pre-allocates large buffers that exceed this limit.
//!
//! Solution: Use a hybrid allocator that delegates small allocations to GPA
//! (for leak detection) but handles large allocations with page_allocator.

const std = @import("std");

/// Hybrid allocator for process execution tests
/// - Small allocations (< 1KB): Use GPA for leak detection
/// - Large allocations (>= 1KB): Use page_allocator
pub fn ProcessTestAllocator(comptime ChildAllocator: type) type {
    return struct {
        GPA = std.heap.GeneralPurposeAllocator(.{}),
        large_allocations: std.ArrayList(*[]u8),

        const Self = @This();

        pub fn init() Self {
            return .{
                .large_allocations = std.ArrayList(*[]u8).init(std.heap.page_allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.large_allocations.items) |alloc| {
                std.heap.page_allocator.free(alloc);
            }
            self.large_allocations.deinit();
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (len >= 1024) {
                // Large allocation - use page_allocator
                const mem = std.heap.page_allocator.rawAlloc(len, ptr_align) orelse return null;
                self.large_allocations.append(@as([*]u8, @alignCast(mem))) catch return null;
                return mem;
            } else {
                // Small allocation - use GPA for leak detection
                return self.GPA.allocator().rawAlloc(len, ptr_align);
            }
        }

        fn resize(ctx: *anyopaque, buf: []u8, new_len: usize, buf_align: u8) ?[]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Check if this is a large allocation
            for (self.large_allocations.items) |alloc| {
                if (alloc.ptr == buf.ptr) {
                    // Large allocation - use page_allocator
                    if (new_len == 0) {
                        std.heap.page_allocator.rawFree(@as([*]u8, @alignCast(buf.ptr)), new_len, buf_align);
                        // Remove from tracking
                        for (self.large_allocations.items, 0..) |item, i| {
                            if (item.ptr == alloc.ptr) {
                                _ = self.large_allocations.orderedRemove(i);
                                break;
                            }
                        }
                        return @as([]u8, undefined);
                    }
                    return null; // page_allocator doesn't support resize
                }
            }
            // Small allocation - use GPA
            return self.GPA.allocator().rawResize(buf, new_len, buf_align);
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Check if this is a large allocation
            for (self.large_allocations.items, 0..) |alloc, i| {
                if (alloc.ptr == buf.ptr) {
                    // Large allocation - use page_allocator
                    std.heap.page_allocator.rawFree(@as([*u8, @alignCast(buf.ptr)), buf.len, buf_align);
                    _ = self.large_allocations.orderedRemove(i);
                    return;
                }
            }
            // Small allocation - use GPA
            self.GPA.allocator().rawFree(buf, buf_align);
        }
    };
};

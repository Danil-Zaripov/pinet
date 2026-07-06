const std = @import("std");

const Config = @import("../vm.zig").Config;

pub const HeapKind = enum { basic };

pub fn Heap(comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Error = std.mem.Allocator.Error;

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            allocOne: *const fn (*anyopaque) Error!*V,
            freeOne: *const fn (*anyopaque, elem: *V) void,
            printUsage: *const fn (*anyopaque) void,
        };

        pub inline fn allocOne(self: Self) Error!*V {
            return self.vtable.allocOne(self.ptr);
        }

        pub inline fn freeOne(self: Self, elem: *V) void {
            self.vtable.freeOne(self.ptr, elem);
        }

        pub inline fn printUsage(self: Self) void {
            self.vtable.printUsage(self.ptr);
        }
    };
}

pub fn BasicHeap(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Optional = union(enum) {
            free: void,
            item: T,
        };

        items: []Optional,
        free_idx: usize,
        capacity: usize,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) !Self {
            const items = try gpa.alloc(Optional, capacity);
            @memset(items, .free);
            return .{
                .items = items,
                .capacity = capacity,
                .free_idx = 0,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.items);
        }

        const vtable: Heap(T).VTable = .{
            .allocOne = allocOne,
            .freeOne = freeOne,
            .printUsage = printUsage,
        };

        pub fn heap(self: *Self) Heap(T) {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn allocOne(ctx: *anyopaque) !*T {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (self.findFree()) |idx| {
                self.free_idx = idx;
                self.items[idx] = .{ .item = undefined };

                return &self.items[idx].item;
            }

            return error.OutOfMemory;
        }

        fn findFree(self: *Self) ?usize {
            for (self.free_idx..self.capacity) |idx|
                if (self.items[idx] == .free) return idx;

            for (0..self.free_idx) |idx|
                if (self.items[idx] == .free) return idx;

            return null;
        }

        fn freeOne(ctx: *anyopaque, elem: *T) void {
            _ = ctx;

            const real_elem: *Optional = @fieldParentPtr("item", elem);

            if (Config.debug_printing.print_frees and real_elem.* == .free) {
                std.debug.print("Double-free\n", .{});
                return;
            }

            real_elem.* = .free;
        }

        fn printUsage(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var used: usize = 0;
            for (self.items) |maybe_elem| {
                if (maybe_elem == .item) {
                    used += 1;
                }
            }

            const free = self.items.len - used;
            std.debug.print("Heap({s}): {} used, {} free, sizeOf(Optional) = {}, sizeOf(T) = {}\n", .{
                @typeName(T),
                used,
                free,
                @sizeOf(Optional),
                @sizeOf(T),
            });
        }
    };
}

//! Interface for fetching equations to the worker.
const std = @import("std");
const Types = @import("types.zig");
const Equation = Types.Equation;

const Error = std.mem.Allocator.Error;

pub const EquationFetcher = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    fetch: *const fn (*anyopaque) ?Equation,
    push: *const fn (*anyopaque, Equation) Error!void,
    pushUrgent: *const fn (*anyopaque, Equation) Error!void,
};

pub inline fn fetch(self: EquationFetcher) ?Equation {
    return self.vtable.fetch(self.ptr);
}

pub inline fn push(self: EquationFetcher, eq: Equation) Error!void {
    return self.vtable.push(self.ptr, eq);
}

pub inline fn pushUrgent(self: EquationFetcher, eq: Equation) Error!void {
    return self.vtable.pushUrgent(self.ptr, eq);
}

/// Works like a queue. Single-threaded only.
pub const TwoDequeEquationFetcher = struct {
    const Self = @This();

    equation_deque: std.Deque(Equation),
    urgent_deque: std.Deque(Equation),
    gpa: std.mem.Allocator,

    const vtable: VTable = .{
        .fetch = Self.fetch,
        .push = Self.push,
        .pushUrgent = Self.pushUrgent,
    };

    pub fn equationFetcher(self: *Self) EquationFetcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn fetch(ctx: *anyopaque) ?Equation {
        const self: *Self = @ptrCast(@alignCast(ctx));

        return self.urgent_deque.popFront() orelse self.equation_deque.popFront();
    }

    pub fn push(ctx: *anyopaque, eq: Equation) Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        try self.equation_deque.pushBack(self.gpa, eq);
    }

    pub fn pushUrgent(ctx: *anyopaque, eq: Equation) Error!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        try self.urgent_deque.pushBack(self.gpa, eq);
    }

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .equation_deque = .empty,
            .urgent_deque = .empty,
            .gpa = gpa,
        };
    }
    pub fn deinit(self: *Self) void {
        self.equation_deque.deinit(self.gpa);
        self.urgent_deque.deinit(self.gpa);
    }
};

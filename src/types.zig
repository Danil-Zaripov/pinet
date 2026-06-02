const std = @import("std");
const Heap = @import("vm.zig").Heap;

const number_of_ports = 10;

pub const Ports = [number_of_ports]?Value;

pub const Agent = struct {
    id: Agent.Id,
    ports: Ports,
    pub const Id = u32;
    pub const Arity = u8;
};

pub const Name = struct {
    port: ?Value,

    // Unchaining is not used anywhere
    // As it brings instability
    pub fn unchain(name: *Name) void {
        var node = if ((name.port orelse return) == .name) name.port.?.name else return;
        while (node.port) |port| {
            if (port == .name) {
                Heap(Name).freeOne(node);
                node = port.name;
            } else break;
        }
        name.port = node.port;
        Heap(Name).freeOne(node);
    }
};

pub const Value = union(enum) {
    name: *Name,
    agent: *Agent,

    pub fn unchain(val: Value) Value {
        switch (val) {
            .name => |name| {
                name.unchain();
                if (name.port) |port| {
                    Heap(Name).freeOne(name);
                    return .{ .agent = port.agent };
                }
                return val;
            },
            .agent => {
                return val;
            },
        }
    }

    pub fn unchainPtr(val: *Value) void {
        switch (val.*) {
            .name => |name| {
                name.unchain();
                if (name.port) |port| {
                    Heap(Name).freeOne(name);
                    val.* = .{ .agent = port.agent };
                }
            },
            .agent => {},
        }
    }
};

pub const Equation = struct {
    lhs: Value,
    rhs: Value,
};

pub const BufferedStringStream = struct {
    buffer: []u8,
    offset: usize,
    print_buf: []u8,

    pub fn init(gpa: std.mem.Allocator, size: usize) !BufferedStringStream {
        const buffer = try gpa.alloc(u8, size);
        @memset(buffer, 0);
        return .{
            .buffer = buffer,
            .offset = 0,
            .print_buf = buffer,
        };
    }
    pub fn write(self: *BufferedStringStream, comptime fmt: []const u8, args: anytype) !void {
        const written = try std.fmt.bufPrint(self.print_buf, fmt, args);
        self.offset += written.len;
        self.print_buf = self.buffer[self.offset..];
    }
};

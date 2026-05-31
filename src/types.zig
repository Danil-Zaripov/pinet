const std = @import("std");

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
};

pub const Value = union(enum) {
    name: *Name,
    agent: *Agent,
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

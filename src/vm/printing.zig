//! This module encapsulates prints to stdout and whatever.
const std = @import("std");

const VM = @import("../vm.zig");
const Config = VM.Config;
const Types = @import("types.zig");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

pub const BufferedStringStream = struct {
    buffer: []u8,
    offset: usize,
    print_buf: []u8,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, size: usize) !BufferedStringStream {
        const buffer = try gpa.alloc(u8, size);
        @memset(buffer, 0);
        return .{
            .buffer = buffer,
            .offset = 0,
            .print_buf = buffer,
            .gpa = gpa,
        };
    }
    pub fn write(self: *BufferedStringStream, comptime fmt: []const u8, args: anytype) !void {
        errdefer self.gpa.free(self.buffer);
        const written = try std.fmt.bufPrint(self.print_buf, fmt, args);
        self.offset += written.len;
        self.print_buf = self.buffer[self.offset..];
    }
};

/// Handles construction of a list of lines.
/// Useful for printing errors.
/// The last line is between the last '\n' (if present) and eof.
pub const Lines = struct {
    lines: [][]const u8,
    gpa: std.mem.Allocator,

    pub const padding = "    | ";
    pub const enumeration_padding = padding.len;

    pub fn init(gpa: std.mem.Allocator, contents: [:0]const u8) !Lines {
        var list = std.ArrayList([]const u8).empty;
        errdefer list.deinit(gpa);

        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            try list.append(gpa, line);
        }

        return .{
            .gpa = gpa,
            .lines = try list.toOwnedSlice(gpa),
        };
    }

    /// Caller owns the string.
    pub fn getEnumerated(self: *const Lines, arena: std.mem.Allocator, idx: usize) ![]const u8 {
        // self.enumeration_padding = 4 + "| ".len
        return std.fmt.allocPrint(arena, "{: >4}| {s}", .{ idx + 1, self.lines[idx] });
    }

    pub fn deinit(self: *Lines) void {
        self.gpa.free(self.lines);
    }

    test "single line" {
        const gpa = std.testing.allocator;
        const file = "hello world";

        var lines = try Lines.init(gpa, file);
        defer lines.deinit();

        try std.testing.expectEqualStrings("hello world", lines.lines[0]);
    }

    test "multiple lines" {
        const gpa = std.testing.allocator;
        const file = "hello\nworld\n";

        var lines = try Lines.init(gpa, file);
        defer lines.deinit();

        try std.testing.expectEqualStrings("hello", lines.lines[0]);
        try std.testing.expectEqualStrings("world", lines.lines[1]);
        try std.testing.expectEqualStrings("", lines.lines[2]);
    }
};

const max_cycle_length = 100;

fn getAgentSymbolNested(vm: *const VM, ag: *const Agent, stream: *BufferedStringStream) !void {
    const name = vm.runtime.agent_id_map.findKey(ag.id);
    try stream.write("{s}(", .{name.?});
    {
        var idx: usize = 0;
        outer: while (ag.ports[idx]) |port| : (idx += 1) {
            if (idx != 0) {
                try stream.write(", ", .{});
            }
            switch (port) {
                .name => |_wire| {
                    var wire = _wire;
                    var cnt: u32 = 0;

                    while (wire.port) |wired_to| {
                        if (Config.debug_printing.print_interactions) {
                            try stream.write("(n)", .{});
                        }
                        if (wired_to == .agent) {
                            try getAgentSymbolNested(vm, wired_to.agent, stream);
                            continue :outer;
                        } else {
                            wire = wired_to.name;
                        }
                        cnt = cnt + 1;
                        if (cnt > max_cycle_length) {
                            break;
                        }
                    }
                    try stream.write("<NAME>", .{});
                },
                .agent => |new_ag| {
                    try getAgentSymbolNested(vm, new_ag, stream);
                },
                .special => |special| {
                    switch (special) {
                        .float => |float| {
                            try stream.write("{}", .{float});
                        },
                        .integer => |integer| {
                            try stream.write("{}", .{integer});
                        },
                    }
                },
            }
        }
    }
    try stream.write(")", .{});
}

pub fn getAgentSymbol(vm: *const VM, ag: *const Agent) ![]const u8 {
    const max_agent_name_size = 512;
    var stream = try BufferedStringStream.init(vm.gpa, max_agent_name_size);
    try getAgentSymbolNested(vm, ag, &stream);
    return stream.buffer;
}

pub fn tryPrint(vm: *const VM, val: Value) !void {
    var cur = val;
    var idx: u32 = 0;
    while (cur == .name) : ({
        cur = cur.name.port.?;
        idx += 1;
    }) {
        if (Config.debug_printing.print_interactions) {
            std.debug.print("(n)", .{});
        }
        if (idx > max_cycle_length) {
            std.debug.print("{any} is cyclic\n", .{val.name.*});
            return;
        }
    }
    const bytes = getAgentSymbol(vm, cur.agent) catch |err| {
        if (err == error.NoSpaceLeft) {
            std.debug.print("Agent symbol is too long to print\n", .{});
            return;
        }
        return err;
    };
    defer vm.gpa.free(bytes);
    const string = std.mem.sliceTo(bytes, 0);
    var stdout = std.Io.File.stdout();
    var writer = stdout.writerStreaming(vm.runtime.io, &.{});
    try writer.interface.print("{s}\n", .{string});
}

test {
    _ = .{
        Lines,
    };
}

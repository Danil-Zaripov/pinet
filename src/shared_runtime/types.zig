//! Module that contains basic types for interaction nets logic.
const std = @import("std");

const memory = @import("memory.zig");

const assert = std.debug.assert;

const number_of_ports = 10;

pub const Ports = [number_of_ports]Value;

pub const Agent = struct {
    id: Id,
    ports: Ports = undefined,
    pub const Id = u32;
    pub const Arity = u8;
};

pub const Name = struct {
    port: Value,

    /// This procedure makes it so that the chain starting with
    /// "name" (argument) is shortened to a direct link (or null in case there is no agent).
    /// Intermediate names are freed.
    ///
    /// Example: a -> b -> c -> Agent() >> unchain(a); >> a -> Agent()
    ///          a -> b -> c -> null    >> unchain(a); >> a -> null
    pub fn unchain(name: *Name, heap: memory.Heap(Name)) void {
        var node = if (name.port.tag == .name) name.port.getName() else return;
        while (node.port.isNonEmpty()) {
            const port = node.port;
            if (port.tag == .name) {
                heap.freeOne(node);
                node = port.getName();
            } else break;
        }

        name.port = node.port;
        heap.freeOne(node);
    }

    /// This function is used to check if the name chain
    /// contains an agent at the end or not
    /// without changing the chain
    pub fn unwind(name: *Name) ?*Agent {
        var node = name;
        while (node.port.tag.isNonEmpty()) {
            const port = node.port;
            switch (port.tag) {
                .name => {
                    node = port.getName();
                },
                .agent => return port.getAgent(),
                else => unreachable,
            }
        }
        return null;
    }

    /// Like unchain, but instead returns the last in the chain, erasing every name before it.
    ///
    /// a -> b -> c -> Agent() >> traverseFree(a); >> c -> Agent()
    pub fn traverseFree(name: *Name, heap: memory.Heap(Name)) *Name {
        var node = name;
        while (node.port.isNonEmpty()) {
            const port = node.port;
            if (port.tag == .name) {
                heap.freeOne(node);
                node = port.getName();
            } else {
                break;
            }
        }
        return node;
    }

    pub fn is_open(name: *Name) bool {
        return name.port.isEmpty();
    }
};

pub const Special = packed struct(u33) {
    tag: enum(u1) {
        integer,
        float,
    },
    num: packed union {
        integer: i32,
        float: f32,
    },

    pub fn integer(int: i32) Special {
        return .{ .tag = .integer, .num = .{ .integer = int } };
    }

    pub fn float(fl: f32) Special {
        return .{ .tag = .float, .num = .{ .float = fl } };
    }

    pub fn coerceFloat(self: Special) f32 {
        switch (self.tag) {
            .float => return self.num.float,
            .integer => return @floatFromInt(self.num.integer),
        }
    }

    pub fn add(self: Special, other: Special) Special {
        if (self.tag == .integer and other.tag == .integer) {
            return integer(self.num.integer + other.num.integer);
        } else {
            return float(self.coerceFloat() + other.coerceFloat());
        }
    }
    pub fn sub(self: Special, other: Special) Special {
        if (self.tag == .integer and other.tag == .integer) {
            return integer(self.num.integer - other.num.integer);
        } else {
            return float(self.coerceFloat() - other.coerceFloat());
        }
    }
    pub fn mul(self: Special, other: Special) Special {
        if (self.tag == .integer and other.tag == .integer) {
            return integer(self.num.integer * other.num.integer);
        } else {
            return float(self.coerceFloat() * other.coerceFloat());
        }
    }
    pub fn div(self: Special, other: Special) Special {
        if (self.tag == .integer and other.tag == .integer) {
            return integer(@divFloor(self.num.integer, other.num.integer));
        } else {
            return float(self.coerceFloat() / other.coerceFloat());
        }
    }

    pub fn eq(self: Special, other: Special) bool {
        if (self.tag == .integer and other.tag == .integer) {
            return self.num.integer == other.num.integer;
        } else {
            // no guarantees
            return self.coerceFloat() == other.coerceFloat();
        }
    }
    pub fn neq(self: Special, other: Special) bool {
        if (self.tag == .integer and other.tag == .integer) {
            return self.num.integer != other.num.integer;
        } else {
            // no guarantees
            return self.coerceFloat() != other.coerceFloat();
        }
    }

    pub fn less(self: Special, other: Special) bool {
        if (self.tag == .integer and other.tag == .integer) {
            return self.num.integer < other.num.integer;
        } else {
            return self.coerceFloat() < other.coerceFloat();
        }
    }
    pub fn leq(self: Special, other: Special) bool {
        if (self.tag == .integer and other.tag == .integer) {
            return self.num.integer <= other.num.integer;
        } else {
            return self.coerceFloat() <= other.coerceFloat();
        }
    }
    pub fn greater(self: Special, other: Special) bool {
        if (self.tag == .integer and other.tag == .integer) {
            return self.num.integer > other.num.integer;
        } else {
            return self.coerceFloat() > other.coerceFloat();
        }
    }
    pub fn geq(self: Special, other: Special) bool {
        if (self.tag == .integer and other.tag == .integer) {
            return self.num.integer >= other.num.integer;
        } else {
            return self.coerceFloat() >= other.coerceFloat();
        }
    }

    pub fn parse(str: []const u8) !Special {
        return if (std.mem.findScalar(u8, str, '.')) |_|
            float(try std.fmt.parseFloat(f32, str))
        else
            integer(try std.fmt.parseInt(i32, str, 10));
    }
};

pub const Value = packed struct(u64) {
    tag: Tag,
    payload: u61,

    pub const Tag = enum(u3) {
        empty = 0,
        special,
        name,
        agent,
    };

    pub fn empty() Value {
        // empty should always be equal to 0u64
        comptime {
            const zero: u64 = 0;
            const zero_bitcast: Value = @bitCast(zero);

            assert(zero_bitcast.tag == .empty and zero_bitcast.payload == 0);
        }

        return .{ .tag = .empty, .payload = 0 };
    }

    pub inline fn isEmpty(val: Value) bool {
        assert(val.tag != .empty or val.payload == 0);
        return @as(u64, @bitCast(val)) == 0;
    }

    pub fn isNonEmpty(val: Value) bool {
        assert(val.tag != .empty or val.payload == 0);
        return @as(u64, @bitCast(val)) != 0;
    }

    pub fn name(ptr: *Name) Value {
        comptime assert(@alignOf(Name) == 8);
        assert(@clz(@intFromPtr(ptr)) >= 3);

        const num: usize = @intFromPtr(ptr);

        return .{ .tag = .name, .payload = @intCast(num >> 3) };
    }

    pub fn agent(ptr: *Agent) Value {
        comptime assert(@alignOf(Agent) == 8);

        const num: usize = @intFromPtr(ptr);

        return .{ .tag = .agent, .payload = @truncate(num >> 3) };
    }

    pub fn special(num: Special) Value {
        return .{ .tag = .special, .payload = @intCast(@as(u33, @bitCast(num))) };
    }

    pub fn getName(val: Value) *Name {
        assert(val.tag == .name);

        const num: usize = @intCast(val.payload);

        return @ptrFromInt(num << 3);
    }

    pub fn getAgent(val: Value) *Agent {
        assert(val.tag == .agent);

        const num: usize = @intCast(val.payload);

        return @ptrFromInt(num << 3);
    }

    pub fn getSpecial(val: Value) Special {
        assert(val.tag == .special);

        return @bitCast(@as(u33, @truncate(val.payload)));
    }
};

pub const EquationUnnormalized = struct {
    lhs: Value,
    rhs: Value,
};

pub const Equation = struct {
    lhs: *Agent,
    rhs: *Agent,
};

test "value conversion" {
    var n1: Name = .{ .port = .empty() };
    var n2: Name = .{ .port = .empty() };
    n1.port = .name(&n2);

    try std.testing.expectEqual(&n2, n1.port.getName());
}

test "unchain" {
    const gpa = std.testing.allocator;

    var basic_name_heap: memory.BasicHeap(Name) = try .init(gpa, 20);
    defer basic_name_heap.deinit(gpa);

    var basic_agent_heap: memory.BasicHeap(Agent) = try .init(gpa, 20);
    defer basic_agent_heap.deinit(gpa);

    var name_heap = basic_name_heap.heap();
    var agent_heap = basic_agent_heap.heap();
    // a -> b -> c -> Agent() ===> a -> Agent()

    const a = try name_heap.allocOne();
    const b = try name_heap.allocOne();
    const c = try name_heap.allocOne();
    const agent = try agent_heap.allocOne();
    agent.* = .{ .id = 0 };
    a.port = Value.name(b);
    b.port = Value.name(c);
    c.port = Value.agent(agent);
    a.unchain(name_heap);
    // b and c get cleaned, a -> agent
    const Optional = memory.BasicHeap(Name).Optional;
    try std.testing.expectEqual(.free, @as(*Optional, @fieldParentPtr("item", b)).*);
    try std.testing.expectEqual(.free, @as(*Optional, @fieldParentPtr("item", c)).*);
    try std.testing.expectEqual(a.port.getAgent(), agent);
}

//! Builtin agents logic.
const std = @import("std");
const Core = @import("core.zig");
const Types = @import("shared_runtime").Types;
const Printing = @import("printing");
const AST = @import("ast");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Special = Types.Special;
const Equation = Types.Equation;

const Config = @import("config");

pub const BuiltinAgentError = error{
    Exiter,
    ArityMismatch,
    NoRuleSpecified,
    BadSecondaryArgument,
} || std.mem.Allocator.Error;

const BuiltinSignature = *const fn (*Core, *Agent, *Agent) BuiltinAgentError!void;

pub var BuiltinTable: std.AutoHashMap(Agent.Id, BuiltinSignature) = undefined;

const BuiltinAgent = struct {
    name: []const u8,
    arity: Agent.Arity,
    impl: BuiltinSignature,
};

pub const BuiltinNameMap = comptime_init: {
    var kvs: [builtin_agents.len]struct { []const u8, Agent.Id } = undefined;
    for (builtin_agents, 0..) |builtin_ag, idx| {
        kvs[idx] = .{ builtin_ag.name, @as(Agent.Id, @intCast(idx)) };
    }
    break :comptime_init std.StaticStringMap(Agent.Id).initComptime(&kvs);
};

pub const user_agent_id_start = builtin_agents.len;

pub fn isBuiltinAgent(id: Agent.Id) bool {
    return id < user_agent_id_start;
}

pub fn init(allocator: std.mem.Allocator) !void {
    BuiltinTable = std.AutoHashMap(Agent.Id, BuiltinSignature).init(allocator);
    for (builtin_agents) |builtin_ag| {
        try BuiltinTable.put(BuiltinNameMap.get(builtin_ag.name).?, builtin_ag.impl);
    }
}
pub fn deinit() void {
    BuiltinTable.deinit();
}

pub const number_builtin_ident = AST.number_special_ident;

// Making this empty makes there be no
// builtin agents. TODO: use compile flag for that
//
// Maybe make the "Abc0" , ... , "Abc10" agents be placed here at compile time
pub const builtin_agents = [_]BuiltinAgent{
    .{ .name = "Exiter", .arity = 0, .impl = exiter },

    .{ .name = "Eraser", .arity = 0, .impl = eraser },

    // Dups
    .{ .name = "Dup", .arity = 2, .impl = dupCopy },
    .{ .name = "Dup2", .arity = 2, .impl = dupCopy },
    .{ .name = "Dup3", .arity = 3, .impl = dupCopy },
    .{ .name = "Dup4", .arity = 4, .impl = dupCopy },

    // Tuples
    .{ .name = "Tuple0", .arity = 0, .impl = tuple },
    .{ .name = "Tuple1", .arity = 1, .impl = tuple },
    .{ .name = "Tuple2", .arity = 2, .impl = tuple },
    .{ .name = "Tuple3", .arity = 3, .impl = tuple },
    .{ .name = "Tuple4", .arity = 4, .impl = tuple },
    .{ .name = "Tuple5", .arity = 5, .impl = tuple },
    .{ .name = "Tuple6", .arity = 6, .impl = tuple },

    // numbers
    .{ .name = number_builtin_ident, .arity = 1, .impl = number },
    .{ .name = "Add", .arity = 2, .impl = unbuiltin },
    .{ .name = "Sub", .arity = 2, .impl = unbuiltin },
    .{ .name = "Mul", .arity = 2, .impl = unbuiltin },
    .{ .name = "Div", .arity = 2, .impl = unbuiltin },

    // lists
    .{ .name = "Cons", .arity = 2, .impl = unbuiltin },
    .{ .name = "Nil", .arity = 0, .impl = unbuiltin },
    .{ .name = "MakeRandomList", .arity = 1, .impl = make_random_list },
};

// Add more builtin agents logic here

pub fn exiter(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    _ = c;
    _ = self;
    _ = other;
    return BuiltinAgentError.Exiter;
}

pub fn unbuiltin(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    _ = c;
    _ = self;
    _ = other;
    return BuiltinAgentError.NoRuleSpecified;
}

/// Module of functions used by the builtin eraser
pub const Eraser = struct {
    fn createEraser(c: *Core) !*Agent {
        return c.createAgent(BuiltinNameMap.get("Eraser").?);
    }

    pub fn erase(c: *Core, agent: *Agent) !void {
        defer c.agent_heap.freeOne(agent);
        const ag_arity = c.runtime.agent_arities.map.get(agent.id).?;
        for (0..ag_arity) |idx| {
            const port = agent.ports[idx].?;
            port_switch: switch (port) {
                .name => |name| {
                    if (name.port) |name_port| {
                        defer c.name_heap.freeOne(name);
                        continue :port_switch name_port;
                    } else {
                        // If the name is free yet, create eraser on its port
                        name.port = Value{ .agent = try createEraser(c) };
                    }
                },
                .agent => |_agent| {
                    try erase(c, _agent);
                },
                .special => {},
            }
        }
    }
};

pub fn eraser(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    defer c.agent_heap.freeOne(self);

    if (Config.debug_printing.print_interactions) {
        std.debug.print("Freeing ", .{});
        Printing.tryPrint(c.runtime, c.runtime.gpa, Value{ .agent = other }) catch {};
    }

    try Eraser.erase(c, other);
}

pub fn dupCopy(c: *Core, self: *Agent, ag: *Agent) BuiltinAgentError!void {
    defer c.agent_heap.freeOne(self);
    // This allocates :(

    var arena = std.heap.ArenaAllocator.init(c.runtime.gpa);
    defer arena.deinit();
    const _allocator = arena.allocator();

    const arity = c.runtime.agent_arities.map.get(self.id).?;
    var _names_map = std.AutoHashMap(*Name, []*Name).init(_allocator);

    const makeCopy = struct {
        pub fn makeCopy(_c: *Core, _arity: u8, port_idx: usize, agent: *Agent, names_map: *std.AutoHashMap(*Name, []*Name)) !*Agent {
            const ag_copy = try _c.createAgent(agent.id);
            const ag_arity = _c.runtime.agent_arities.map.get(agent.id).?;
            for (0..ag_arity) |idx| {
                const port = agent.ports[idx].?;
                port_switch: switch (port) {
                    .name => |connected_name| {
                        if (connected_name.port) |connected_thing| {
                            // If the name has a port then we skip the original name and
                            // go straight to its port
                            defer _c.name_heap.freeOne(connected_name);
                            continue :port_switch connected_thing;
                        } else {
                            std.debug.print("Dup to name\n", .{});
                            const names = names_map.get(connected_name).?;
                            names[port_idx] = try _c.name_heap.allocOne();
                            ag_copy.ports[idx] = Value{ .name = names[port_idx] };
                            names[port_idx].port = Value{ .agent = ag_copy };
                        }
                    },
                    .agent => |connected_agent| {
                        ag_copy.ports[idx] = Value{ .agent = try makeCopy(_c, _arity, port_idx, connected_agent, names_map) };
                    },
                    .special => |special| {
                        ag_copy.ports[idx] = Value{ .special = special };
                    },
                }
            }
            return ag_copy;
        }
        pub fn copyNames(_c: *Core, _arity: u8, agent: *Agent, names_map: *std.AutoHashMap(*Name, []*Name), allocator: std.mem.Allocator) !*Agent {
            const ag_arity = _c.runtime.agent_arities.map.get(agent.id).?;
            for (0..ag_arity) |idx| {
                const port = agent.ports[idx].?;
                port_switch: switch (port) {
                    .name => |connected_name| {
                        if (connected_name.port) |connected_thing| {
                            // If the name has a port then we skip the original name and
                            // go straight to its port
                            defer _c.name_heap.freeOne(connected_name);
                            continue :port_switch connected_thing;
                        } else {
                            std.debug.print("Dup to name\n", .{});
                            const names = try allocator.alloc(*Name, _arity);
                            const new_name = try _c.name_heap.allocOne();
                            try names_map.put(new_name, names);
                            names[0] = connected_name;
                            agent.ports[idx] = Value{ .name = new_name };
                            new_name.port = Value{ .agent = agent };
                        }
                    },
                    .agent => |connected_agent| {
                        agent.ports[idx] = Value{ .agent = try copyNames(_c, _arity, connected_agent, names_map, allocator) };
                    },
                    .special => {},
                }
            }
            return agent;
        }
    };

    _ = try makeCopy.copyNames(c, arity, ag, &_names_map, _allocator);

    if (self.ports[0].? == .name and self.ports[0].?.name.is_open()) {
        self.ports[0].?.name.port = Value{ .agent = ag };
    } else {
        try c.pushUrgent(Equation{
            .lhs = self.ports[0].?,
            .rhs = Value{ .agent = ag },
        });
    }

    for (1..arity) |port_idx| {
        const port = self.ports[port_idx].?;
        const copy = try makeCopy.makeCopy(c, arity, port_idx, ag, &_names_map);
        if (port == .name and port.name.is_open()) {
            port.name.port = Value{ .agent = copy };
        } else {
            const eq = Equation{
                .lhs = port,
                .rhs = Value{ .agent = copy },
            };
            try c.pushUrgent(eq);
        }
    }

    var it = _names_map.iterator();
    while (it.next()) |kv| {
        const dup_ag = try c.createAgent(self.id);
        var port_idx: Agent.Arity = 1;
        while (port_idx < arity) : (port_idx += 1) {
            dup_ag.ports[port_idx] = Value{ .name = kv.value_ptr.*[port_idx] };
        }
        dup_ag.ports[0] = Value{ .name = kv.key_ptr.* };
        const eq = Equation{
            .lhs = Value{ .name = kv.value_ptr.*[0] },
            .rhs = Value{ .agent = dup_ag },
        };
        try c.pushUrgent(eq);
    }
}

pub fn tuple(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    if (self.id != other.id) {
        return BuiltinAgentError.NoRuleSpecified;
    }
    defer c.agent_heap.freeOne(self);
    defer c.agent_heap.freeOne(other);
    const arity = c.runtime.agent_arities.map.get(self.id).?;

    for (0..arity) |port_idx| {
        const eq = Equation{
            .lhs = self.ports[port_idx].?,
            .rhs = other.ports[port_idx].?,
        };

        try c.pushEquation(eq);
    }
}

pub fn number(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    const adder_id = comptime BuiltinNameMap.get("Add").?;
    const mult_id = comptime BuiltinNameMap.get("Mul").?;
    const div_id = comptime BuiltinNameMap.get("Div").?;
    const sub_id = comptime BuiltinNameMap.get("Sub").?;
    if (other.id != adder_id and other.id != mult_id and other.id != div_id and other.id != sub_id) return BuiltinAgentError.NoRuleSpecified;

    const self_special = self.ports[0].?.special;

    const getSecondValue = struct {
        pub fn getSecondValue(val: Value, _c: *Core) ?Special {
            switch (val) {
                .name => |name| {
                    if (name.unwind()) |agent| {
                        name.unchain(_c.name_heap);
                        _c.name_heap.freeOne(name);
                        defer _c.agent_heap.freeOne(agent);
                        return agent.ports[0].?.special;
                    } else {
                        return null;
                    }
                },
                .agent => |agent| {
                    return getSecondValue(agent.ports[0].?, _c);
                },
                .special => |special| return special,
            }
        }
    }.getSecondValue;

    const sv = getSecondValue(other.ports[1].?, c) orelse {
        // We switch places: self with secondary argument port
        const port = other.ports[1].?;
        other.ports[1] = .{ .agent = self };
        const eq = Equation{
            .lhs = .{ .agent = other },
            .rhs = port,
        };
        try c.pushEquation(eq);
        return;
    };
    defer c.agent_heap.freeOne(self);
    defer c.agent_heap.freeOne(other);

    const ret = switch (other.id) {
        adder_id => Special.add(self_special, sv),
        mult_id => Special.mul(self_special, sv),
        div_id => Special.div(self_special, sv),
        sub_id => Special.sub(self_special, sv),
        else => unreachable,
    };

    const ret_ag = try c.createAgent(self.id);
    ret_ag.ports[0] = Value{ .special = ret };

    const eq = Equation{
        .lhs = other.ports[0].?,
        .rhs = .{ .agent = ret_ag },
    };
    try c.pushUrgent(eq);
}

pub fn make_random_list(c: *Core, self: *Agent, other: *Agent) BuiltinAgentError!void {
    const number_id = BuiltinNameMap.get(number_builtin_ident).?;
    if (other.id != number_id) return BuiltinAgentError.NoRuleSpecified;

    const num_special = other.ports[0].?.special;
    const num = switch (num_special) {
        .integer => |i| i,
        .float => return BuiltinAgentError.BadSecondaryArgument,
    };

    defer c.agent_heap.freeOne(self);
    defer c.agent_heap.freeOne(other);

    var prng: std.Random.DefaultPrng = .init(blk: {
        var buffer: [8]u8 = undefined;
        c.runtime.io.random(buffer[0..]);
        break :blk std.mem.readInt(u64, buffer[0..], .native);
    });
    const rand = prng.random();

    const lst = blk: {
        if (num > 0) {
            const ag = try c.createAgent(BuiltinNameMap.get("Cons").?);
            ag.ports[0] = Value{ .agent = try c.createNumberAgent(.{ .integer = rand.intRangeAtMost(i32, -10000, 10000) }) };
            break :blk ag;
        } else {
            break :blk try c.createAgent(BuiltinNameMap.get("Nil").?);
        }
    };

    var node = lst;
    for (1..@as(usize, @intCast(num))) |_| {
        var new_node = try c.createAgent(BuiltinNameMap.get("Cons").?);
        new_node.ports[0] = Value{ .agent = try c.createNumberAgent(.{ .integer = rand.intRangeAtMost(i32, -10000, 10000) }) };
        node.ports[1] = Value{ .agent = new_node };
        node = new_node;
    }

    if (num > 0) {
        node.ports[1] = Value{ .agent = try c.createAgent(BuiltinNameMap.get("Nil").?) };
    }

    const eq = Equation{
        .lhs = self.ports[0].?,
        .rhs = Value{ .agent = lst },
    };
    try c.pushEquation(eq);
}

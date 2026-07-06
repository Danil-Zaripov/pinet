const std = @import("std");
const VM = @import("../vm.zig");
const Types = @import("types.zig");
const Printing = @import("printing.zig");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Special = Types.Special;
const Equation = Types.Equation;

// builtin agents logic

// TODO: make there be less outside errors?
pub const BuiltinAgentError = error{
    Exiter,
    OutOfMemory,
    NoSpaceLeft,
    WriteFailed,
    ArityMismatch,
    NoRuleSpecified,
    BadSecondaryArgument,
};

const BuiltinSignature = *const fn (*VM, *Agent, *Agent) BuiltinAgentError!void;

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

pub const number_builtin_ident = @import("../ast.zig").number_special_ident;

// Making this empty makes there be no
// builtin agents. TODO: use compile flag for that
//
// Maybe make the "Abc0" , ... , "Abc10" agents be placed here at compile time
pub const builtin_agents = [_]BuiltinAgent{
    // Let this be the first agent.
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

pub fn exiter(vm: *VM, self: *Agent, other: *Agent) BuiltinAgentError!void {
    _ = vm;
    _ = self;
    _ = other;
    return BuiltinAgentError.Exiter;
}

pub fn unbuiltin(vm: *VM, self: *Agent, other: *Agent) BuiltinAgentError!void {
    _ = vm;
    _ = self;
    _ = other;
    return BuiltinAgentError.NoRuleSpecified;
}

/// Module of functions used by the builtin eraser
pub const Eraser = struct {
    fn createEraser(vm: *VM) !*Agent {
        return vm.createAgent(BuiltinNameMap.get("Eraser").?);
    }

    pub fn erase(vm: *VM, agent: *Agent) !void {
        defer vm.agent_heap.freeOne(agent);
        const ag_arity = vm.runtime.agent_arities.map.get(agent.id).?;
        for (0..ag_arity) |idx| {
            const port = agent.ports[idx].?;
            port_switch: switch (port) {
                .name => |name| {
                    if (name.port) |name_port| {
                        defer vm.name_heap.freeOne(name);
                        continue :port_switch name_port;
                    } else {
                        // If the name is free yet, create eraser on its port
                        name.port = Value{ .agent = try createEraser(vm) };
                    }
                },
                .agent => |_agent| {
                    try erase(vm, _agent);
                },
                .special => {},
            }
        }
    }
};

pub fn eraser(vm: *VM, self: *Agent, other: *Agent) BuiltinAgentError!void {
    defer vm.agent_heap.freeOne(self);

    if (VM.Config.debug_printing.print_interactions) {
        std.debug.print("Freeing ", .{});
        try Printing.tryPrint(vm, Value{ .agent = other });
    }

    try Eraser.erase(vm, other);
}

pub fn dupCopy(vm: *VM, self: *Agent, ag: *Agent) BuiltinAgentError!void {
    defer vm.agent_heap.freeOne(self);
    // This allocates :(

    var arena = std.heap.ArenaAllocator.init(vm.gpa);
    defer arena.deinit();
    const _allocator = arena.allocator();

    const arity = vm.runtime.agent_arities.map.get(self.id).?;
    var _names_map = std.AutoHashMap(*Name, []*Name).init(_allocator);

    const makeCopy = struct {
        pub fn makeCopy(_vm: *VM, _arity: u8, port_idx: usize, agent: *Agent, names_map: *std.AutoHashMap(*Name, []*Name)) !*Agent {
            const ag_copy = try _vm.createAgent(agent.id);
            const ag_arity = _vm.runtime.agent_arities.map.get(agent.id).?;
            for (0..ag_arity) |idx| {
                const port = agent.ports[idx].?;
                port_switch: switch (port) {
                    .name => |connected_name| {
                        if (connected_name.port) |connected_thing| {
                            // If the name has a port then we skip the original name and
                            // go straight to its port
                            defer _vm.name_heap.freeOne(connected_name);
                            continue :port_switch connected_thing;
                        } else {
                            std.debug.print("Dup to name\n", .{});
                            const names = names_map.get(connected_name).?;
                            names[port_idx] = try _vm.name_heap.allocOne();
                            ag_copy.ports[idx] = Value{ .name = names[port_idx] };
                            names[port_idx].port = Value{ .agent = ag_copy };
                        }
                    },
                    .agent => |connected_agent| {
                        ag_copy.ports[idx] = Value{ .agent = try makeCopy(_vm, _arity, port_idx, connected_agent, names_map) };
                    },
                    .special => |special| {
                        ag_copy.ports[idx] = Value{ .special = special };
                    },
                }
            }
            return ag_copy;
        }
        pub fn copyNames(_vm: *VM, _arity: u8, agent: *Agent, names_map: *std.AutoHashMap(*Name, []*Name), allocator: std.mem.Allocator) !*Agent {
            const ag_arity = _vm.runtime.agent_arities.map.get(agent.id).?;
            for (0..ag_arity) |idx| {
                const port = agent.ports[idx].?;
                port_switch: switch (port) {
                    .name => |connected_name| {
                        if (connected_name.port) |connected_thing| {
                            // If the name has a port then we skip the original name and
                            // go straight to its port
                            defer _vm.name_heap.freeOne(connected_name);
                            continue :port_switch connected_thing;
                        } else {
                            std.debug.print("Dup to name\n", .{});
                            const names = try allocator.alloc(*Name, _arity);
                            const new_name = try _vm.name_heap.allocOne();
                            try names_map.put(new_name, names);
                            names[0] = connected_name;
                            agent.ports[idx] = Value{ .name = new_name };
                            new_name.port = Value{ .agent = agent };
                        }
                    },
                    .agent => |connected_agent| {
                        agent.ports[idx] = Value{ .agent = try copyNames(_vm, _arity, connected_agent, names_map, allocator) };
                    },
                    .special => {},
                }
            }
            return agent;
        }
    };

    _ = try makeCopy.copyNames(vm, arity, ag, &_names_map, _allocator);

    if (self.ports[0].? == .name and self.ports[0].?.name.is_open()) {
        self.ports[0].?.name.port = Value{ .agent = ag };
    } else {
        try vm.pushUrgent(Equation{
            .lhs = self.ports[0].?,
            .rhs = Value{ .agent = ag },
        });
    }

    for (1..arity) |port_idx| {
        const port = self.ports[port_idx].?;
        const copy = try makeCopy.makeCopy(vm, arity, port_idx, ag, &_names_map);
        if (port == .name and port.name.is_open()) {
            port.name.port = Value{ .agent = copy };
        } else {
            const eq = Equation{
                .lhs = port,
                .rhs = Value{ .agent = copy },
            };
            try vm.pushUrgent(eq);
        }
    }

    var it = _names_map.iterator();
    while (it.next()) |kv| {
        const dup_ag = try vm.createAgent(self.id);
        var port_idx: Agent.Arity = 1;
        while (port_idx < arity) : (port_idx += 1) {
            dup_ag.ports[port_idx] = Value{ .name = kv.value_ptr.*[port_idx] };
        }
        dup_ag.ports[0] = Value{ .name = kv.key_ptr.* };
        const eq = Equation{
            .lhs = Value{ .name = kv.value_ptr.*[0] },
            .rhs = Value{ .agent = dup_ag },
        };
        try vm.pushUrgent(eq);
    }
}

pub fn tuple(vm: *VM, self: *Agent, other: *Agent) BuiltinAgentError!void {
    if (self.id != other.id) {
        return BuiltinAgentError.NoRuleSpecified;
    }
    defer vm.agent_heap.freeOne(self);
    defer vm.agent_heap.freeOne(other);
    const arity = vm.runtime.agent_arities.map.get(self.id).?;

    for (0..arity) |port_idx| {
        const eq = Equation{
            .lhs = self.ports[port_idx].?,
            .rhs = other.ports[port_idx].?,
        };

        try vm.pushEquation(eq);
    }
}

pub fn number(vm: *VM, self: *Agent, other: *Agent) BuiltinAgentError!void {
    const adder_id = comptime BuiltinNameMap.get("Add").?;
    const mult_id = comptime BuiltinNameMap.get("Mul").?;
    const div_id = comptime BuiltinNameMap.get("Div").?;
    const sub_id = comptime BuiltinNameMap.get("Sub").?;
    if (other.id != adder_id and other.id != mult_id and other.id != div_id and other.id != sub_id) return BuiltinAgentError.NoRuleSpecified;

    const self_special = self.ports[0].?.special;

    const getSecondValue = struct {
        pub fn getSecondValue(val: Value, _vm: *VM) ?Special {
            switch (val) {
                .name => |name| {
                    if (name.unwind()) |agent| {
                        name.unchain(_vm.name_heap);
                        _vm.name_heap.freeOne(name);
                        defer _vm.agent_heap.freeOne(agent);
                        return agent.ports[0].?.special;
                    } else {
                        return null;
                    }
                },
                .agent => |agent| {
                    return getSecondValue(agent.ports[0].?, _vm);
                },
                .special => |special| return special,
            }
        }
    }.getSecondValue;

    const sv = getSecondValue(other.ports[1].?, vm) orelse {
        // We switch places: self with secondary argument port
        const port = other.ports[1].?;
        other.ports[1] = .{ .agent = self };
        const eq = Equation{
            .lhs = .{ .agent = other },
            .rhs = port,
        };
        try vm.pushEquation(eq);
        return;
    };
    defer vm.agent_heap.freeOne(self);
    defer vm.agent_heap.freeOne(other);

    const ret = switch (other.id) {
        adder_id => Special.add(self_special, sv),
        mult_id => Special.mul(self_special, sv),
        div_id => Special.div(self_special, sv),
        sub_id => Special.sub(self_special, sv),
        else => unreachable,
    };

    const ret_ag = try vm.createAgent(self.id);
    ret_ag.ports[0] = Value{ .special = ret };

    const eq = Equation{
        .lhs = other.ports[0].?,
        .rhs = .{ .agent = ret_ag },
    };
    try vm.pushUrgent(eq);
}

pub fn make_random_list(vm: *VM, self: *Agent, other: *Agent) BuiltinAgentError!void {
    const number_id = BuiltinNameMap.get(number_builtin_ident).?;
    if (other.id != number_id) return BuiltinAgentError.NoRuleSpecified;

    const num_special = other.ports[0].?.special;
    const num = switch (num_special) {
        .integer => |i| i,
        .float => return BuiltinAgentError.BadSecondaryArgument,
    };

    defer vm.agent_heap.freeOne(self);
    defer vm.agent_heap.freeOne(other);

    var prng: std.Random.DefaultPrng = .init(blk: {
        var buffer: [8]u8 = undefined;
        vm.runtime.io.random(buffer[0..]);
        break :blk std.mem.readInt(u64, buffer[0..], .native);
    });
    const rand = prng.random();

    const lst = blk: {
        if (num > 0) {
            const ag = try vm.createAgent(BuiltinNameMap.get("Cons").?);
            ag.ports[0] = Value{ .agent = try vm.createNumberAgent(.{ .integer = rand.intRangeAtMost(i32, -10000, 10000) }) };
            break :blk ag;
        } else {
            break :blk try vm.createAgent(BuiltinNameMap.get("Nil").?);
        }
    };

    var node = lst;
    for (1..@as(usize, @intCast(num))) |_| {
        var new_node = try vm.createAgent(BuiltinNameMap.get("Cons").?);
        new_node.ports[0] = Value{ .agent = try vm.createNumberAgent(.{ .integer = rand.intRangeAtMost(i32, -10000, 10000) }) };
        node.ports[1] = Value{ .agent = new_node };
        node = new_node;
    }

    if (num > 0) {
        node.ports[1] = Value{ .agent = try vm.createAgent(BuiltinNameMap.get("Nil").?) };
    }

    const eq = Equation{
        .lhs = self.ports[0].?,
        .rhs = Value{ .agent = lst },
    };
    try vm.pushEquation(eq);
}

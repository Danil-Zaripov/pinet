const std = @import("std");
const VM = @import("vm.zig");
const Types = @import("types.zig");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

// builtin agents logic

const BuiltinAgentError = error{
    OutOfMemory,
    NoSpaceLeft,
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

pub const UserAgentIdStart = builtin_agents.len;

pub fn isBuiltinAgent(id: Agent.Id) bool {
    return id < UserAgentIdStart;
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

// Making this empty makes there be no
// builtin agents. TODO: use compile flag for that
pub const builtin_agents = [_]BuiltinAgent{
    .{ .name = "Eraser", .arity = 0, .impl = eraser },
    .{ .name = "Dup", .arity = 2, .impl = dupCopy },
    .{ .name = "Dup2", .arity = 2, .impl = dupCopy },
    .{ .name = "Dup3", .arity = 3, .impl = dupCopy },
    .{ .name = "Dup4", .arity = 4, .impl = dupCopy },
};

// Add more builtin agents logic here

pub fn eraser(vm: *VM, self: *Agent, ag: *Agent) BuiltinAgentError!void {
    defer VM.Heap(Agent).freeOne(self);
    defer VM.Heap(Agent).freeOne(ag);

    if (VM.Config.debug_printing.print_interactions) {
        std.debug.print("Freeing ", .{});
        try vm.tryPrint(Value{ .agent = ag });
    }
    // Anonymous function
    const createEraser = struct {
        pub fn createEraser(_vm: *VM) !*Agent {
            return _vm.createAgent(BuiltinNameMap.get("Eraser").?);
        }
    }.createEraser;

    for (ag.ports) |maybe_port| {
        if (maybe_port) |port| {
            port_switch: switch (port) {
                .name => |name| {
                    if (name.port) |name_port| {
                        defer VM.Heap(Name).freeOne(name);
                        continue :port_switch name_port;
                    } else {
                        // If the name is free yet, create eraser on its port
                        name.port = Value{ .agent = try createEraser(vm) };
                    }
                },
                .agent => |agent| {
                    return eraser(vm, self, agent);
                },
            }
        }
    }
}

pub fn dupCopy(vm: *VM, self: *Agent, ag: *Agent) BuiltinAgentError!void {
    defer VM.Heap(Agent).freeOne(self);
    // This allocates :(

    var arena = std.heap.ArenaAllocator.init(vm.gpa);
    defer arena.deinit();
    const _allocator = arena.allocator();

    const arity = vm.runtime.agent_arities.map.get(self.id).?;
    var _names_map = std.AutoHashMap(*Name, []*Name).init(_allocator);

    const makeCopy = struct {
        pub fn makeCopy(_vm: *VM, _arity: u8, port_idx: usize, agent: *Agent, names_map: *std.AutoHashMap(*Name, []*Name)) !*Agent {
            const ag_copy = try _vm.createAgent(agent.id);
            for (agent.ports, 0..) |maybe_port, idx| {
                if (maybe_port) |port| {
                    port_switch: switch (port) {
                        .name => |connected_name| {
                            if (connected_name.port) |connected_thing| {
                                // If the name has a port then we skip the original name and
                                // go straight to its port
                                VM.Heap(Name).freeOne(connected_name);
                                continue :port_switch connected_thing;
                            } else {
                                const names = names_map.get(connected_name).?;
                                names[port_idx] = try _vm.name_heap.getOne();
                                ag_copy.ports[idx] = Value{ .name = names[port_idx] };
                                names[port_idx].port = Value{ .agent = ag_copy };
                            }
                        },
                        .agent => |connected_agent| {
                            ag_copy.ports[idx] = Value{ .agent = try makeCopy(_vm, _arity, port_idx, connected_agent, names_map) };
                        },
                    }
                }
            }
            return ag_copy;
        }
        pub fn copyNames(_vm: *VM, _arity: u8, agent: *Agent, names_map: *std.AutoHashMap(*Name, []*Name), allocator: std.mem.Allocator) !*Agent {
            for (agent.ports, 0..) |maybe_port, idx| {
                if (maybe_port) |port| {
                    port_switch: switch (port) {
                        .name => |connected_name| {
                            if (connected_name.port) |connected_thing| {
                                // If the name has a port then we skip the original name and
                                // go straight to its port
                                VM.Heap(Name).freeOne(connected_name);
                                continue :port_switch connected_thing;
                            } else {
                                const names = try allocator.alloc(*Name, _arity);
                                const new_name = try _vm.name_heap.getOne();
                                try names_map.put(new_name, names);
                                names[0] = connected_name;
                                agent.ports[idx] = Value{ .name = new_name };
                                new_name.port = Value{ .agent = agent };
                            }
                        },
                        .agent => |connected_agent| {
                            agent.ports[idx] = Value{ .agent = try copyNames(_vm, _arity, connected_agent, names_map, allocator) };
                        },
                    }
                }
            }
            return agent;
        }
    };

    _ = try makeCopy.copyNames(vm, arity, ag, &_names_map, _allocator);

    try vm.pushEquation(Equation{
        .lhs = self.ports[0].?,
        .rhs = Value{ .agent = ag },
    });

    for (self.ports[1..arity], 1..) |port, port_idx| {
        const copy = try makeCopy.makeCopy(vm, arity, port_idx, ag, &_names_map);
        const eq = Equation{
            .lhs = port.?,
            .rhs = Value{ .agent = copy },
        };
        try vm.pushEquation(eq);
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
        try vm.pushEquation(eq);
    }
}

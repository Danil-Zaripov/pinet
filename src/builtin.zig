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

const BuiltinSignature = *const fn (*VM, *Agent) BuiltinAgentError!void;

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
};

// Add more builtin agents logic here

pub fn eraser(vm: *VM, ag: *Agent) BuiltinAgentError!void {
    defer VM.Heap(Agent).freeOne(ag);

    if (VM.Config.debug_printing.print_interactions) {
        std.debug.print("Freeing ", .{});
        try vm.tryPrint(Value{ .agent = ag });
    }

    // Anonymous function
    const createEraser = struct {
        pub fn createEraser(_vm: *VM) !*Agent {
            const agent = try _vm.agent_heap.getOne();
            agent.id = BuiltinNameMap.get("Eraser").?;
            return agent;
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
                    return eraser(vm, agent);
                },
            }
        }
    }
}

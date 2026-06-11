const std = @import("std");
const AST = @import("../parser.zig");
const Lexer = @import("../lexer.zig");
const Types = @import("types.zig");
const Runtime = @import("runtime.zig");
const Instruction = @import("instruction.zig");
const Builtin = @import("builtin.zig");
const VM = @import("../vm.zig");

pub const Config = VM.Config;

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;
const Special = Types.Special;

pub fn name_name(vm: *VM, lname: *Name, rname: *Name) !void {
    // I'm sure this is very unintuitive,
    // but fixing would require some cognitive effort.
    // For some reason name-name logic is very error prone.
    // What even is a "name"? A "wire"? No, because it is one way only.
    // But sometimes it is a wire. And when two wires interact?
    // They create cycles. And what happens after cycles?
    // Everything breaks.

    if (Config.debug_printing.print_interactions) {
        std.debug.print("name - name interaction\n", .{});
    }

    // Also can this be rewritten to be more linear?
    if (lname.port) |lport| {
        if (rname.port) |rport| {
            defer VM.Heap(Name).freeOne(lname);
            defer VM.Heap(Name).freeOne(rname);

            const eq = Equation{
                .lhs = lport,
                .rhs = rport,
            };
            try vm.pushEquation(eq);
        } else {
            rname.port = Value{ .name = lname };
        }
    } else {
        lname.port = Value{ .name = rname };
    }
}

pub fn name_agent(vm: *VM, name: *Name, agent: *Agent) !void {
    if (Config.debug_printing.print_interactions) {
        std.debug.print("{s} - name interaction\n", .{vm.runtime.agent_id_map.findKey(agent.id).?});
    }

    if (name.port) |port| {
        defer VM.Heap(Name).freeOne(name);
        const eq = Equation{
            .lhs = port,
            .rhs = Value{ .agent = agent },
        };
        try vm.pushUrgent(eq);
    } else {
        name.port = Value{ .agent = agent };
    }
}

// fn unwindAgent()

const Condition = Instruction.CompiledCondition;

const SimpleValue = union(enum) {
    bool: bool,
    special: Special,
};

const EvaluationError = error{
    BadSecondaryValue,
};

fn evalCondition(vm: *const VM, lagent: *const Agent, ragent: *const Agent, condition: *Condition) EvaluationError!SimpleValue {
    // Compilation of expressions is needed.
    switch (condition.*) {
        .atom => |atom| {
            switch (atom) {
                .special => |special| {
                    return .{ .special = special };
                },
                .port => |port| {
                    const a = if (port.owner == .lhs) lagent else ragent;
                    const node = a.ports[port.idx].?;
                    node_blk: switch (node) {
                        .agent => |agent| {
                            const number_id = Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?;
                            if (agent.id == number_id) {
                                return .{ .special = agent.ports[0].?.special };
                            } else {
                                std.debug.print("Port wasn't a number\n", .{});
                                return EvaluationError.BadSecondaryValue;
                            }
                        },
                        .name => |name| {
                            if (name.port) |name_port| {
                                continue :node_blk name_port;
                            } else {
                                std.debug.print("Port name was empty\n", .{});
                                return EvaluationError.BadSecondaryValue;
                            }
                        },
                        else => unreachable,
                    }
                },
            }
        },
        .binary_op => |binary| {
            const lhs = try evalCondition(vm, lagent, ragent, binary.lhs);
            const rhs = try evalCondition(vm, lagent, ragent, binary.rhs);
            if (lhs == .special and rhs == .special) {
                switch (binary.op) {
                    .eq => {
                        return SimpleValue{ .bool = lhs.special.integer == rhs.special.integer };
                    },
                    else => unreachable,
                }
            } else {
                unreachable;
            }
        },
        .unary_op => unreachable,
    }

    unreachable;
}

pub fn agent_agent(vm: *VM, _lagent: *Agent, _ragent: *Agent) !void {
    var lagent = _lagent;
    var ragent = _ragent;

    if (Config.debug_printing.print_interactions) {
        std.debug.print("{s} - {s} interaction\n", .{
            vm.runtime.agent_id_map.findKey(lagent.id).?,
            vm.runtime.agent_id_map.findKey(ragent.id).?,
        });
    }
    if (Builtin.isBuiltinAgent(lagent.id)) {
        const handler = Builtin.BuiltinTable.get(lagent.id).?;
        if (handler(vm, lagent, ragent)) {
            return;
        } else |err| {
            if (err != Builtin.BuiltinAgentError.NoRuleSpecified) {
                return err;
            }
        }
    }
    if (Builtin.isBuiltinAgent(ragent.id)) {
        const handler = Builtin.BuiltinTable.get(ragent.id).?;
        if (handler(vm, ragent, lagent)) {
            return;
        } else |err| {
            if (err != Builtin.BuiltinAgentError.NoRuleSpecified) {
                return err;
            }
        }
    }

    defer VM.Heap(Agent).freeOne(lagent);
    defer VM.Heap(Agent).freeOne(ragent);

    // Not builtin
    const rule = vm.runtime.rule_table.get(.{ .lhs = lagent.id, .rhs = ragent.id }) catch |err| {
        if (err == error.UnknownRule) {
            std.debug.print("Unknown rule {s} - {s}\n", .{
                vm.runtime.agent_id_map.findKey(lagent.id).?,
                vm.runtime.agent_id_map.findKey(ragent.id).?,
            });
        }
        return err;
    };

    if (rule[1]) {
        std.mem.swap(*Agent, &lagent, &ragent);
    }

    const conditioned_rules = rule[0];

    for (conditioned_rules) |conditioned| {
        if (conditioned.condition) |condition| {
            const evaluated = evalCondition(vm, lagent, ragent, condition) catch |err| errblk: {
                switch (err) {
                    EvaluationError.BadSecondaryValue => break :errblk SimpleValue{ .bool = false },
                }
            };
            if (evaluated == .bool and evaluated.bool) {
                try VM.execInstructions(vm, conditioned.instructions, lagent, ragent);
                return;
            }
        } else {
            try VM.execInstructions(vm, conditioned.instructions, lagent, ragent);
            return;
        }
    }
    return error.UnknownRule;
}

pub fn evalEquation(vm: *VM, eq: Equation) !void {
    switch (eq.lhs) {
        .name => |lname| {
            switch (eq.rhs) {
                .name => |rname| {
                    try name_name(vm, lname, rname);
                },
                .agent => |ragent| {
                    try name_agent(vm, lname, ragent);
                },
                else => unreachable,
            }
        },
        .agent => |lagent| {
            switch (eq.rhs) {
                .name => |rname| {
                    try name_agent(vm, rname, lagent);
                },
                .agent => |ragent| {
                    try agent_agent(vm, lagent, ragent);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

const std = @import("std");
const AST = @import("../ast.zig");
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
    // TODO: optimise name chaining

    if (Config.debug_printing.print_interactions) {
        std.debug.print("name - name interaction\n", .{});
    }

    // Also can this be rewritten to be more linear?
    if (lname.port) |lport| {
        if (rname.port) |rport| {
            defer vm.name_heap.freeOne(lname);
            defer vm.name_heap.freeOne(rname);

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
        defer vm.name_heap.freeOne(name);
        const eq = Equation{
            .lhs = port,
            .rhs = Value{ .agent = agent },
        };
        try vm.pushUrgent(eq);
    } else {
        name.port = Value{ .agent = agent };
    }
}

const Condition = Instruction.CompiledCondition;

const SimpleValue = union(enum) {
    bool: bool,
    special: Special,
};

const EvaluationError = error{
    BadSecondaryValue,
    WrongArgument,
};

fn evalCondition(vm: *const VM, lagent: *const Agent, ragent: *const Agent, condition: *Condition) EvaluationError!SimpleValue {
    switch (condition.*) {
        .atom => |atom| {
            switch (atom) {
                .special => |special| {
                    return .{ .special = special };
                },
                .port => |port| {
                    const a = if (port.owner == .lhs) lagent else ragent;
                    // constCast !!!
                    const node = if (port.idx) |port_idx| a.ports[port_idx].? else Value{ .agent = @constCast(a) };

                    node_blk: switch (node) {
                        .agent => |agent| {
                            const number_id = Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?;
                            if (agent.id == number_id) {
                                return .{ .special = agent.ports[0].?.special };
                            } else {
                                return EvaluationError.BadSecondaryValue;
                            }
                        },
                        .name => |name| {
                            if (name.port) |name_port| {
                                continue :node_blk name_port;
                            } else {
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
                    .eq => return SimpleValue{ .bool = Special.eq(lhs.special, rhs.special) },
                    .less => return SimpleValue{ .bool = Special.less(lhs.special, rhs.special) },
                    .leq => return SimpleValue{ .bool = Special.leq(lhs.special, rhs.special) },
                    .greater => return SimpleValue{ .bool = Special.greater(lhs.special, rhs.special) },
                    .geq => return SimpleValue{ .bool = Special.geq(lhs.special, rhs.special) },
                    else => return EvaluationError.WrongArgument,
                }
            } else if (lhs == .bool and rhs == .bool) {
                switch (binary.op) {
                    .logic_or => return SimpleValue{ .bool = lhs.bool or rhs.bool },
                    .logic_and => return SimpleValue{ .bool = lhs.bool and rhs.bool },
                    else => return EvaluationError.WrongArgument,
                }
            } else {
                return EvaluationError.WrongArgument;
            }
        },
        .unary_op => |unary| {
            const item = try evalCondition(vm, lagent, ragent, unary.item);
            if (item.bool) {
                switch (unary.op) {
                    .not => return SimpleValue{ .bool = !item.bool },
                }
            } else {
                return EvaluationError.WrongArgument;
            }
        },
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

    // Not builtin
    const search_result = vm.runtime.rule_table.get(.{ .lhs = lagent.id, .rhs = ragent.id }) catch |err| rule_blk: {
        if (err == error.UnknownRule) {
            // The rule may still be defined as wildcard
            if (vm.runtime.wildcard_table.get(lagent.id)) |wildcard_rule| {
                break :rule_blk Runtime.RuleSearchResult{ .rules = wildcard_rule, .tag = .wildcard_lhs };
            } else if (vm.runtime.wildcard_table.get(ragent.id)) |wildcard_rule| {
                break :rule_blk Runtime.RuleSearchResult{ .rules = wildcard_rule, .tag = .wildcard_rhs };
            }

            std.debug.print("Unknown rule {s} - {s}\n", .{
                vm.runtime.agent_id_map.findKey(lagent.id).?,
                vm.runtime.agent_id_map.findKey(ragent.id).?,
            });
        }
        return err;
    };

    var wildcarded: bool = false;

    evaluation: switch (search_result.tag) {
        .normal => {
            // We don't free the ragent in case it's wildcarded
            // because it functions like a name and will interact
            // later
            defer vm.agent_heap.freeOne(lagent);
            defer if (!wildcarded) vm.agent_heap.freeOne(ragent);

            const conditioned_rules = search_result.rules;
            for (conditioned_rules) |conditioned| {
                if (conditioned.condition) |condition| {
                    const evaluated = evalCondition(vm, lagent, ragent, condition) catch |err| errblk: {
                        switch (err) {
                            EvaluationError.BadSecondaryValue => break :errblk SimpleValue{ .bool = false },
                            // There probably should be some other error handling in case of bad arguments
                            // but since many things can go badly, we can simply ignore it?
                            // TODO: research into more constraining conditions
                            EvaluationError.WrongArgument => break :errblk SimpleValue{ .bool = false },
                        }
                    };
                    if (evaluated == .bool and evaluated.bool) {
                        try VM.execInstructions(vm, conditioned.instructions, lagent, ragent, wildcarded);
                        return;
                    }
                } else {
                    try VM.execInstructions(vm, conditioned.instructions, lagent, ragent, wildcarded);
                    return;
                }
            }
        },
        .swap => {
            std.mem.swap(*Agent, &lagent, &ragent);
            continue :evaluation .normal;
        },
        .wildcard_lhs => {
            wildcarded = true;
            continue :evaluation .normal;
        },
        .wildcard_rhs => {
            std.mem.swap(*Agent, &lagent, &ragent);
            continue :evaluation .wildcard_lhs;
        },
    }
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

const std = @import("std");

const AST = @import("ast");
const Lexer = AST.Lexer;

const Runtime = @import("shared_runtime");
const Types = Runtime.Types;

const Compilation = @import("compilation");
const Instruction = Compilation.Instruction;
const Condition = Compilation.Condition;

const Builtin = @import("builtin.zig");
const VM = @import("vm.zig");
const Debug = @import("debug");

pub const Config = @import("config");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;
const Special = Types.Special;

pub fn name_name(vm: *VM, lname: *Name, rname: *Name) !void {
    // TODO: optimise name chaining

    Debug.log(.print_interactions, "name - name interaction\n", .{});

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
    // TODO (KoGora): perf analysis
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

const SimpleValue = union(enum) {
    bool: bool,
    special: Special,
};

const EvaluationError = error{
    BadSecondaryValue,
    WrongArgument,
};

fn evalCondition(vm: *VM, lagent: *Agent, ragent: *Agent, instructions: []Condition.Instruction) !bool {
    const registers = &vm.condition_registers;
    for (instructions) |instr| {
        switch (instr.tag) {
            .put_port => |port| {
                const owner = if (port.owner == .lhs) lagent else ragent;
                const value = if (port.idx) |idx| owner.ports[idx].? else Value{ .agent = owner };
                const agent = agent: {
                    switch (value) {
                        .name => |name| {
                            // Will this work everywhere?
                            const unwinded = name.unwind();
                            if (unwinded) |agent| {
                                name.unchain(vm.name_heap);
                                break :agent agent;
                            } else {
                                return EvaluationError.BadSecondaryValue;
                            }
                        },
                        .agent => |agent| break :agent agent,
                        else => unreachable,
                    }
                };

                registers[instr.result] = .{ .agent = agent };
            },
            .assert_id => |asserted_id| {
                if (registers[instr.lhs] == .agent) {
                    const agent = registers[instr.lhs].agent;
                    if (agent.id != asserted_id) {
                        return error.BadSecondaryValue;
                    }
                }
            },
            .get_special => {
                registers[instr.result] = Condition.Register.CondValue{ .special = registers[instr.lhs].agent.ports[0].?.special };
            },
            .put_constant => |special| {
                registers[instr.result] = Condition.Register.CondValue{ .special = special };
            },
            .apply_bin => |op| {
                const lhs = registers[instr.lhs];
                const rhs = registers[instr.rhs];
                if (lhs == .special and rhs == .special) {
                    registers[instr.result] = .{ .bool = switch (op) {
                        .eq => lhs.special.eq(rhs.special),
                        .geq => lhs.special.geq(rhs.special),
                        .leq => lhs.special.leq(rhs.special),
                        .less => lhs.special.less(rhs.special),
                        .greater => lhs.special.greater(rhs.special),
                        else => return error.WrongArgument,
                    } };
                } else if (lhs == .bool and rhs == .bool) {
                    registers[instr.result] = .{ .bool = switch (op) {
                        .logic_and => lhs.bool and rhs.bool,
                        .logic_or => lhs.bool and rhs.bool,
                        else => return error.WrongArgument,
                    } };
                } else {
                    return error.WrongArgument;
                }
            },
            .apply_un => unreachable,
            .get_result => {
                if (registers[instr.result] == .bool) {
                    return registers[instr.result].bool;
                }
                return false;
            },
        }
    }
    unreachable;
}

pub fn agent_agent(vm: *VM, _lagent: *Agent, _ragent: *Agent) !void {
    var lagent = _lagent;
    var ragent = _ragent;

    // TODO (KoGora): perf analysis
    if (Config.debug_printing.print_interactions) {
        std.debug.print("{s} - {s}\n", .{
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
                        std.debug.print("Caught an error {s}!\n", .{@errorName(err)});
                        switch (err) {
                            EvaluationError.BadSecondaryValue => break :errblk false,
                            // There probably should be some other error handling in case of bad arguments
                            // but since many things can go badly, we can simply ignore it?
                            // TODO: research into more constraining conditions
                            EvaluationError.WrongArgument => break :errblk false,
                        }
                    };
                    if (evaluated) {
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

const std = @import("std");
const AST = @import("ast");
const Runtime = @import("shared_runtime");
const Types = Runtime.Types;

const Compilation = @import("compilation.zig");
const Diagnostic = Compilation.Diagnostic;
const HandledError = Diagnostic.HandledError;

pub const Condition = @import("condition.zig");
const Shrinker = @import("shrinker.zig");
pub const Bytecode = Shrinker.Bytecode;

const Scope = @import("scope.zig");
const RegisterId = Scope.RegisterId;
const NameInfo = Scope.NameInfo;

const Agent = Types.Agent;
const Special = Types.Special;
const Name = Types.Name;
const Value = Types.Value;
const Equation = Types.Equation;

pub const Port = Condition.Port;

pub const AgentsKey = struct { lhs: Agent.Id, rhs: Agent.Id };

pub const CompiledLhs = union(enum) {
    agents: AgentsKey,
    wildcard: Agent.Id,
};

const Instruction = @This();

const Location = struct {
    reg: RegisterId,
    port: ?usize,
};

tag: Tag,
// Better than optional?
operand1: RegisterId = undefined,
operand2: RegisterId = undefined,
const Tag = union(enum) {
    mk_agent: Agent.Id,
    mk_name,
    mk_special: Special,
    put_into_port: Port.Idx,
    push,
    load_arguments,
};

pub fn mk_agent(id: Agent.Id, loc: RegisterId) Instruction {
    return .{
        .tag = .{ .mk_agent = id },
        .operand1 = loc,
    };
}

pub fn mk_name(loc: RegisterId) Instruction {
    return .{
        .tag = .mk_name,
        .operand1 = loc,
    };
}

pub fn mk_special(special: Special, loc: RegisterId) Instruction {
    return .{
        .tag = .{ .mk_special = special },
        .operand1 = loc,
    };
}

pub fn put_into_port(port_idx: Port.Idx, src: RegisterId, dest: RegisterId) Instruction {
    return .{
        .tag = .{ .put_into_port = port_idx },
        .operand1 = src,
        .operand2 = dest,
    };
}

pub fn push(lhs: RegisterId, rhs: RegisterId) Instruction {
    return .{
        .tag = .push,
        .operand1 = lhs,
        .operand2 = rhs,
    };
}

pub fn load_arguments() Instruction {
    return .{
        .tag = .load_arguments,
    };
}

pub fn debugPrintInstruction(runtime: *const Runtime, conditioned_rules: []ConditionedRule) !void {
    for (conditioned_rules, 0..) |conditioned_rule, idx| {
        if (conditioned_rules.len > 1) {
            std.debug.print("Condition {}\n\n", .{idx});
        }
        const instrs = conditioned_rule.instructions;
        for (instrs) |instr| {
            defer std.debug.print("\n\n", .{});
            if (instr.tag != .load_arguments) {
                std.debug.print("REG{}", .{instr.operand1});
            }
            if (instr.tag == .push or instr.tag == .put_into_port) {
                std.debug.print(" TO REG{}", .{instr.operand2});
            }
            std.debug.print(": ", .{});
            switch (instr.tag) {
                .mk_agent => |id| {
                    const name = runtime.agent_id_map.findKey(id).?;
                    std.debug.print("MKAGENT {s}", .{name});
                },
                .push => {
                    std.debug.print("PUSH", .{});
                },
                .mk_name => {
                    std.debug.print("MKNAME", .{});
                },
                .load_arguments => {
                    std.debug.print("LOAD ARGUMENTS", .{});
                },
                .put_into_port => |port| {
                    std.debug.print("PUT INTO {} PORT", .{port});
                },
                .mk_special => |special| {
                    std.debug.print("MKSPECIAL {any}", .{special});
                },
            }
        }
    }
}

const toArenaOwnedSlice = Compilation.toArenaOwnedSlice;

pub const CompiledRule = struct {
    CompiledLhs,
    []ConditionedRule,
};

pub const ConditionedRule = struct {
    condition: ?[]Condition.Instruction,
    instructions: CompiledPairs,
};

const CompiledPairs = []Instruction;

const CompiledTerm = struct {
    reg: RegisterId,
};

const CompiledName = struct {
    name_info: *NameInfo,
};

const TermContext = struct {
    runtime: *Runtime,
    list: *std.ArrayList(Instruction),
    scope: *Scope,
    diag: *Diagnostic,

    inline fn appendInstruction(ctx: *const TermContext, instr: Instruction) !void {
        try ctx.list.append(ctx.runtime.gpa, instr);
    }
};

pub fn compileNumber(
    ctx: *const TermContext,
    obj: AST.Object,
) !CompiledTerm {
    const agent_id = ctx.runtime.agent_id_map.map.get(AST.number_special_ident).?;
    const reg = ctx.scope.getFree();
    try ctx.appendInstruction(mk_agent(agent_id, reg));
    const special_reg = ctx.scope.getFree();
    const special = try Compilation.getNumberType(obj.portlist.?[0].val.name);
    try ctx.appendInstruction(mk_special(special, special_reg));
    try ctx.appendInstruction(put_into_port(0, special_reg, reg));

    return .{ .reg = reg };
}

pub fn compileName(
    ctx: *const TermContext,
    na: AST.Node(AST.Object),
) !CompiledName {
    const name = na.val.name;
    var name_info: *NameInfo = undefined;
    if (ctx.scope.map.getPtr(name)) |existing| {
        if (!existing.used) {
            name_info = existing;
            existing.used = true;
        } else {
            ctx.diag.tag = .{
                .name_used_twice = .{
                    .first = existing.token_slice,
                    .second = na.tslice,
                },
            };
            return HandledError.NameUsedTwice;
        }
    } else {
        name_info = try ctx.scope.associate(name, na.tslice);
        try ctx.appendInstruction(Instruction.mk_name(name_info.location));
    }

    return .{ .name_info = name_info };
}

pub fn compileAgent(
    ctx: *const TermContext,
    ag: AST.Object,
) !CompiledTerm {
    const id = try ctx.runtime.agent_id_map.get(ag.name);
    const arity = try ctx.runtime.agent_arities.get(id, ag.portlist.?.len);
    const reg = ctx.scope.getFree();
    try ctx.appendInstruction(Instruction.mk_agent(id, reg));

    for (0..arity) |idx| {
        const port = ag.portlist.?[idx];
        if (port.val.portlist) |_| {
            if (port.val.isNumber()) {
                // number
                const compiledNumber = try compileNumber(ctx, port.val);
                try ctx.appendInstruction(Instruction.put_into_port(idx, compiledNumber.reg, reg));
            } else {
                const compiledAgent = try compileAgent(ctx, port.val);
                try ctx.appendInstruction(Instruction.put_into_port(idx, compiledAgent.reg, reg));
            }
        } else {
            const compiledName = try compileName(ctx, port);
            try ctx.appendInstruction(Instruction.put_into_port(idx, compiledName.name_info.location, reg));
        }
    }

    return .{ .reg = reg };
}

pub fn compileTerm(ctx: *const TermContext, obj: AST.Node(AST.Object)) !CompiledTerm {
    if (obj.val.portlist) |_| {
        if (obj.val.isNumber()) {
            return try compileNumber(ctx, obj.val);
        } else {
            return try compileAgent(ctx, obj.val);
        }
    } else {
        const compiledName = try compileName(ctx, obj);
        return .{ .reg = compiledName.name_info.location };
    }
}

pub fn compilePairs(
    runtime: *Runtime,
    lhs: AST.Node(AST.Object),
    rhs: AST.Node(AST.Object),
    pairs: []AST.Node(AST.ActivePair),
    diag: *Diagnostic,
) !CompiledPairs {
    var list = std.ArrayList(Instruction).empty;
    var scope = Scope.init(runtime.gpa);
    defer scope.deinit();
    const ctx: TermContext = .{
        .runtime = runtime,
        .list = &list,
        .scope = &scope,
        .diag = diag,
    };

    try ctx.appendInstruction(load_arguments());

    for (lhs.val.portlist.?) |port_node| {
        const port = port_node.val;
        if (port.portlist) |_| {
            diag.tag = .{ .agent_in_argument = port_node.tslice };
            return HandledError.AgentInArgument;
        } else {
            _ = scope.associate(port.name, port_node.tslice) catch |err| {
                if (err == error.ValueExists) {
                    diag.tag = .{
                        .name_used_twice = .{
                            .first = scope.map.get(port.name).?.token_slice,
                            .second = port_node.tslice,
                        },
                    };
                    return HandledError.NameUsedTwice;
                } else {
                    return err;
                }
            };
        }
    }

    // RHS may be a wildcard
    if (rhs.val.portlist) |portlist| {
        for (portlist) |port_node| {
            const port = port_node.val;
            if (port.portlist) |_| {
                diag.tag = .{ .agent_in_argument = port_node.tslice };
                return HandledError.AgentInArgument;
            } else {
                _ = scope.associate(port.name, port_node.tslice) catch |err| {
                    if (err == error.ValueExists) {
                        diag.tag = .{
                            .name_used_twice = .{
                                .first = scope.map.get(port.name).?.token_slice,
                                .second = port_node.tslice,
                            },
                        };
                        return HandledError.NameUsedTwice;
                    } else {
                        return err;
                    }
                };
            }
        }
    } else {
        _ = scope.associate(rhs.val.name, rhs.tslice) catch |err| {
            if (err == error.ValueExists) {
                diag.tag = .{
                    .name_used_twice = .{
                        .first = scope.map.get(rhs.val.name).?.token_slice,
                        .second = rhs.tslice,
                    },
                };
                return HandledError.NameUsedTwice;
            } else {
                return err;
            }
        };
    }

    for (pairs) |node_pair| {
        const pair = node_pair.val;
        const compiledLhs = try compileTerm(&ctx, pair.lhs);
        const compiledRhs = try compileTerm(&ctx, pair.rhs);
        try list.append(runtime.gpa, Instruction.push(compiledLhs.reg, compiledRhs.reg));
    }

    try scope.checkNameUsage(diag);
    return try toArenaOwnedSlice(Instruction, &list, runtime.gpa, runtime.arena);
}

pub fn compileWildcard(
    runtime: *Runtime,
    agent: AST.Node(AST.Object),
    name: AST.Node(AST.Object),
    rule_exprs: []AST.RuleExpression,
    diag: *Diagnostic,
) !CompiledRule {
    const agent_id = try runtime.agent_id_map.get(agent.val.name);

    _ = try runtime.agent_arities.get(agent_id, agent.val.portlist.?.len);

    var lst = try std.ArrayList(ConditionedRule).initCapacity(runtime.gpa, 1);
    defer lst.deinit(runtime.gpa);

    var port_info: std.StringHashMap(Port) = .init(runtime.gpa);
    defer port_info.deinit();

    for (agent.val.portlist.?, 0..) |port, idx| {
        // agent is lhs by default
        try port_info.put(port.val.name, Port{ .idx = idx, .owner = .lhs });
    }

    try port_info.put(name.val.name, Port{ .idx = null, .owner = .rhs });

    for (rule_exprs) |rule_expr| {
        const instructions = try compilePairs(runtime, agent, name, rule_expr.pairs, diag);
        try lst.append(runtime.gpa, .{
            .condition = if (rule_expr.expr) |condition| try Condition.compile(runtime, &port_info, condition, diag) else null,
            .instructions = instructions,
        });
    }

    return CompiledRule{
        .{ .wildcard = agent_id },
        try toArenaOwnedSlice(ConditionedRule, &lst, runtime.gpa, runtime.arena),
    };
}

pub fn compileRule(runtime: *Runtime, rule: AST.Rule, diag: *Diagnostic) !CompiledRule {
    if (rule.lhs.val.portlist == null or rule.rhs.val.portlist == null) {
        // Wildcard rule
        if (rule.lhs.val.portlist) |_| {
            return try compileWildcard(runtime, rule.lhs, rule.rhs, rule.rule_exprs, diag);
        } else if (rule.rhs.val.portlist) |_| {
            return try compileWildcard(runtime, rule.rhs, rule.lhs, rule.rule_exprs, diag);
        } else {
            unreachable;
        }
    }

    const lhs_id = try runtime.agent_id_map.get(rule.lhs.val.name);
    const rhs_id = try runtime.agent_id_map.get(rule.rhs.val.name);

    _ = try runtime.agent_arities.get(lhs_id, rule.lhs.val.portlist.?.len);
    _ = try runtime.agent_arities.get(rhs_id, rule.rhs.val.portlist.?.len);

    var lst = try std.ArrayList(ConditionedRule).initCapacity(runtime.gpa, 1);
    defer lst.deinit(runtime.gpa);

    var port_info: std.StringHashMap(Port) = .init(runtime.gpa);
    defer port_info.deinit();

    for (rule.lhs.val.portlist.?, 0..) |port, idx| {
        try port_info.put(port.val.name, Port{ .idx = idx, .owner = .lhs });
    }

    for (rule.rhs.val.portlist.?, 0..) |port, idx| {
        try port_info.put(port.val.name, Port{ .idx = idx, .owner = .rhs });
    }

    for (rule.rule_exprs) |rule_expr| {
        const instructions = try compilePairs(runtime, rule.lhs, rule.rhs, rule_expr.pairs, diag);
        try lst.append(runtime.gpa, .{
            .condition = if (rule_expr.expr) |condition| try Condition.compile(runtime, &port_info, condition, diag) else null,
            .instructions = instructions,
        });
    }

    return CompiledRule{
        .{ .agents = .{ .lhs = lhs_id, .rhs = rhs_id } },
        try toArenaOwnedSlice(ConditionedRule, &lst, runtime.gpa, runtime.arena),
    };
}

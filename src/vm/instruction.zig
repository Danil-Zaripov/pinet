const std = @import("std");
const AST = @import("../ast.zig");
const Types = @import("types.zig");
const Runtime = @import("runtime.zig");
const VM = @import("../vm.zig");

const Agent = Types.Agent;
const Special = Types.Special;
const Name = Types.Name;
const Value = Types.Value;
const Equation = Types.Equation;

const RegisterId = usize;

pub const Port = struct {
    owner: Owner,

    // Null means the owner is a name in case of a wildcard rule
    idx: ?Idx,

    pub const Idx = usize;

    pub const Owner = enum {
        rhs,
        lhs,
    };
};

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
    MkAgent: Agent.Id,
    MkName,
    MkSpecial: Special,
    PutIntoPort: Port.Idx,
    Push,
    LoadArguments,
};

pub fn mk_agent(id: Agent.Id, loc: RegisterId) Instruction {
    return .{
        .tag = .{ .MkAgent = id },
        .operand1 = loc,
    };
}

pub fn mk_name(loc: RegisterId) Instruction {
    return .{
        .tag = .MkName,
        .operand1 = loc,
    };
}

pub fn mk_special(special: Special, loc: RegisterId) Instruction {
    return .{
        .tag = .{ .MkSpecial = special },
        .operand1 = loc,
    };
}

pub fn put_into_port(port_idx: Port.Idx, src: RegisterId, dest: RegisterId) Instruction {
    return .{
        .tag = .{ .PutIntoPort = port_idx },
        .operand1 = src,
        .operand2 = dest,
    };
}

pub fn push(lhs: RegisterId, rhs: RegisterId) Instruction {
    return .{
        .tag = .Push,
        .operand1 = lhs,
        .operand2 = rhs,
    };
}

pub fn load_arguments() Instruction {
    return .{
        .tag = .LoadArguments,
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
            if (instr.tag != .LoadArguments) {
                std.debug.print("REG{}", .{instr.operand1});
            }
            if (instr.tag == .Push or instr.tag == .PutIntoPort) {
                std.debug.print(" TO REG{}", .{instr.operand2});
            }
            std.debug.print(": ", .{});
            switch (instr.tag) {
                .MkAgent => |id| {
                    const name = runtime.agent_id_map.findKey(id).?;
                    std.debug.print("MKAGENT {s}", .{name});
                },
                .Push => {
                    std.debug.print("PUSH", .{});
                },
                .MkName => {
                    std.debug.print("MKNAME", .{});
                },
                .LoadArguments => {
                    std.debug.print("LOAD ARGUMENTS", .{});
                },
                .PutIntoPort => |port| {
                    std.debug.print("PUT INTO {} PORT", .{port});
                },
                .MkSpecial => |special| {
                    std.debug.print("MKSPECIAL {any}", .{special});
                },
            }
        }
    }
}

pub const CompiledRule = struct { CompiledLhs, []ConditionedRule };

pub const ConditionedRule = struct { condition: ?*CompiledCondition, instructions: CompiledPairs };

pub const CompiledCondition = union(enum) {
    binary_op: Binary,
    unary_op: Unary,
    atom: Atom,

    pub const Atom = union(enum) {
        special: Special,
        port: Port,
    };

    pub const Binary = struct {
        lhs: *CompiledCondition,
        rhs: *CompiledCondition,
        op: Op,

        pub const Op = AST.Expression.BinaryExpr.Tag;
    };

    pub const Unary = struct {
        item: *CompiledCondition,
        op: Op,

        pub const Op = AST.Expression.UnaryExpr.Tag;
    };
};

const CompiledPairs = []Instruction;

const CompiledTerm = struct { reg: RegisterId, instrs: []Instruction };

const NameInfo = struct { location: RegisterId, is_on_port: bool = false, used: bool = false };

const CompiledName = struct { name_info: *NameInfo, instrs: []Instruction };

const Scope = struct {
    map: std.StringHashMap(NameInfo),
    free_idx: RegisterId,
    pub fn getFree(self: *Scope) RegisterId {
        defer self.free_idx += 1;
        return self.free_idx;
    }

    pub fn associate(self: *Scope, name: []const u8) !*NameInfo {
        if (self.map.get(name)) |_| {
            return error.ValueExists;
        } else {
            const val = self.getFree();
            const info = NameInfo{ .location = val };
            const result = try self.map.getOrPutValue(name, info);
            return result.value_ptr;
        }
    }

    pub fn init(allocator: std.mem.Allocator) Scope {
        return .{
            .free_idx = 0,
            .map = std.StringHashMap(NameInfo).init(allocator),
        };
    }
    pub fn deinit(self: *Scope) void {
        self.map.deinit();
    }
};

pub fn compileNumber(runtime: *Runtime, obj: AST.Object, scope: *Scope) !CompiledTerm {
    const agent_id = runtime.agent_id_map.map.get(AST.number_special_ident).?;
    var list = std.ArrayList(Instruction).empty;
    const reg = scope.getFree();
    try list.append(runtime.allocator, mk_agent(agent_id, reg));
    const special_reg = scope.getFree();
    const special = try VM.getNumberType(obj.portlist.?[0].val.name);
    try list.append(runtime.allocator, mk_special(special, special_reg));
    try list.append(runtime.allocator, put_into_port(0, special_reg, reg));
    return .{ .reg = reg, .instrs = try list.toOwnedSlice(runtime.allocator) };
}

pub fn compileName(runtime: *Runtime, na: AST.Object, scope: *Scope) !CompiledName {
    const name = na.name;
    var list = std.ArrayList(Instruction).empty;
    var name_info: *NameInfo = undefined;
    if (scope.map.getPtr(name)) |existing| {
        if (!existing.used) {
            name_info = existing;
            existing.used = true;
        } else {
            return error.NameUsedTwice;
        }
    } else {
        name_info = try scope.associate(name);
        try list.append(runtime.allocator, Instruction.mk_name(name_info.location));
    }

    return .{ .name_info = name_info, .instrs = try list.toOwnedSlice(runtime.allocator) };
}

pub fn compileAgent(runtime: *Runtime, ag: AST.Object, scope: *Scope) !CompiledTerm {
    var list = std.ArrayList(Instruction).empty;
    const id = try runtime.agent_id_map.get(ag.name);
    const arity = try runtime.agent_arities.get(id, ag.portlist.?.len);
    const reg = scope.getFree();
    try list.append(runtime.allocator, Instruction.mk_agent(id, reg));

    for (0..arity) |idx| {
        const port = ag.portlist.?[idx].val;
        if (port.portlist) |_| {
            if (port.isNumber()) {
                // number
                const compiledNumber = try compileNumber(runtime, port, scope);
                try list.appendSlice(runtime.allocator, compiledNumber.instrs);
                try list.append(runtime.allocator, Instruction.put_into_port(idx, compiledNumber.reg, reg));
            } else {
                const compiledAgent = try compileAgent(runtime, port, scope);
                try list.appendSlice(runtime.allocator, compiledAgent.instrs);
                try list.append(runtime.allocator, Instruction.put_into_port(idx, compiledAgent.reg, reg));
            }
        } else {
            const compiledName = try compileName(runtime, port, scope);
            try list.appendSlice(runtime.allocator, compiledName.instrs);
            try list.append(runtime.allocator, Instruction.put_into_port(idx, compiledName.name_info.location, reg));
            // if (!compiledName.name_info.is_on_port) {
            //     compiledName.name_info.is_on_port = true;
            //     try list.append(runtime.allocator, Instruction.put_into_port(idx, compiledName.name_info.location, reg));
            // } else {
            //     // name is on port => make temp name and connect them
            //     const free_reg = scope.getFree();
            //     try list.append(runtime.allocator, Instruction.mk_name(free_reg));
            //     try list.append(runtime.allocator, Instruction.put_into_port(idx, free_reg, reg));
            //     try list.append(runtime.allocator, Instruction.push(free_reg, compiledName.name_info.location));
            // }
        }
    }

    return .{ .reg = reg, .instrs = try list.toOwnedSlice(runtime.allocator) };
}

pub fn compileTerm(runtime: *Runtime, obj: AST.Object, scope: *Scope) !CompiledTerm {
    if (obj.portlist) |_| {
        if (obj.isNumber()) {
            return try compileNumber(runtime, obj, scope);
        } else {
            return try compileAgent(runtime, obj, scope);
        }
    } else {
        const compiledName = try compileName(runtime, obj, scope);
        return .{ .instrs = compiledName.instrs, .reg = compiledName.name_info.location };
    }
}

pub fn compilePairs(runtime: *Runtime, lhs: AST.Object, rhs: AST.Object, pairs: []AST.Node(AST.ActivePair)) !CompiledPairs {
    var list = std.ArrayList(Instruction).empty;
    var scope = Scope.init(runtime.allocator);
    defer scope.deinit();

    // init the "arguments"
    try list.append(runtime.allocator, load_arguments());

    for (lhs.portlist.?) |port_node| {
        const port = port_node.val;
        if (port.portlist) |_| {
            return error.AgentInLhsArgument;
        } else {
            _ = scope.associate(port.name) catch |err| {
                if (err == error.ValueExists) {
                    return error.NameUsedTwice;
                } else {
                    return err;
                }
            };
        }
    }

    // RHS may be a wildcard
    if (rhs.portlist) |portlist| {
        for (portlist) |port_node| {
            const port = port_node.val;
            if (port.portlist) |_| {
                return error.AgentInRhsArgument;
            } else {
                _ = scope.associate(port.name) catch |err| {
                    if (err == error.ValueExists) {
                        return error.NameUsedTwice;
                    } else {
                        return err;
                    }
                };
            }
        }
    } else {
        _ = scope.associate(rhs.name) catch |err| {
            if (err == error.ValueExists) {
                return error.NameUsedTwice;
            } else {
                return err;
            }
        };
    }

    for (pairs) |node_pair| {
        const pair = node_pair.val;
        const compiledLhs = try compileTerm(runtime, pair.lhs.val, &scope);
        const compiledRhs = try compileTerm(runtime, pair.rhs.val, &scope);
        try list.appendSlice(runtime.allocator, compiledLhs.instrs);
        try list.appendSlice(runtime.allocator, compiledRhs.instrs);
        try list.append(runtime.allocator, Instruction.push(compiledLhs.reg, compiledRhs.reg));
    }

    return try list.toOwnedSlice(runtime.allocator);
}

pub fn compileCondition(runtime: *Runtime, port_info: *const std.StringHashMap(Port), condition: *AST.Node(AST.Expression)) !*CompiledCondition {
    const compiled = try runtime.allocator.create(CompiledCondition);
    switch (condition.val) {
        .atom => |atom_node| {
            const atom = atom_node.val;
            if (atom.portlist) |ports| {
                if (atom.isNumber()) {
                    const num = ports[0].val.name;
                    compiled.* = .{ .atom = .{ .special = try VM.getNumberType(num) } };
                }
            } else {
                if (port_info.get(atom.name)) |port_idx| {
                    compiled.* = .{ .atom = .{ .port = port_idx } };
                } else {
                    return error.UnknownName;
                }
            }
        },
        .binary_op => |binary| {
            compiled.* = .{ .binary_op = .{
                .op = binary.tag,
                .lhs = try compileCondition(runtime, port_info, binary.lhs),
                .rhs = try compileCondition(runtime, port_info, binary.rhs),
            } };
        },
        .unary_op => |unary| {
            compiled.* = .{ .unary_op = .{
                .op = unary.tag,
                .item = try compileCondition(runtime, port_info, unary.item),
            } };
        },
    }

    return compiled;
}

pub fn compileWildcard(runtime: *Runtime, agent: AST.Node(AST.Object), name: AST.Node(AST.Object), rule_exprs: []AST.RuleExpression) !CompiledRule {
    const agent_id = try runtime.agent_id_map.get(agent.val.name);

    _ = try runtime.agent_arities.get(agent_id, agent.val.portlist.?.len);

    var lst = try std.ArrayList(ConditionedRule).initCapacity(runtime.allocator, 1);

    var port_info: std.StringHashMap(Port) = .init(runtime.allocator);

    for (agent.val.portlist.?, 0..) |port, idx| {
        // agent is lhs by default
        try port_info.put(port.val.name, Port{ .idx = idx, .owner = .lhs });
    }

    try port_info.put(name.val.name, Port{ .idx = null, .owner = .rhs });

    for (rule_exprs) |rule_expr| {
        const instructions = try compilePairs(runtime, agent.val, name.val, rule_expr.pairs);
        try lst.append(runtime.allocator, .{
            .condition = if (rule_expr.expr) |condition| try compileCondition(runtime, &port_info, condition) else null,
            .instructions = instructions,
        });
    }

    return CompiledRule{
        .{ .wildcard = agent_id },
        try lst.toOwnedSlice(runtime.allocator),
    };
}

pub fn compileRule(runtime: *Runtime, rule: AST.Rule) !CompiledRule {
    if (rule.lhs.val.portlist == null or rule.rhs.val.portlist == null) {
        // Wildcard rule
        if (rule.lhs.val.portlist) |_| {
            return try compileWildcard(runtime, rule.lhs, rule.rhs, rule.rule_exprs);
        } else if (rule.rhs.val.portlist) |_| {
            return try compileWildcard(runtime, rule.rhs, rule.lhs, rule.rule_exprs);
        } else {
            unreachable;
        }
    }

    const lhs_id = try runtime.agent_id_map.get(rule.lhs.val.name);
    const rhs_id = try runtime.agent_id_map.get(rule.rhs.val.name);

    _ = try runtime.agent_arities.get(lhs_id, rule.lhs.val.portlist.?.len);
    _ = try runtime.agent_arities.get(rhs_id, rule.rhs.val.portlist.?.len);

    var lst = try std.ArrayList(ConditionedRule).initCapacity(runtime.allocator, 1);

    var port_info: std.StringHashMap(Port) = .init(runtime.allocator);

    for (rule.lhs.val.portlist.?, 0..) |port, idx| {
        try port_info.put(port.val.name, Port{ .idx = idx, .owner = .lhs });
    }

    for (rule.rhs.val.portlist.?, 0..) |port, idx| {
        try port_info.put(port.val.name, Port{ .idx = idx, .owner = .rhs });
    }

    for (rule.rule_exprs) |rule_expr| {
        const instructions = try compilePairs(runtime, rule.lhs.val, rule.rhs.val, rule_expr.pairs);
        try lst.append(runtime.allocator, .{
            .condition = if (rule_expr.expr) |condition| try compileCondition(runtime, &port_info, condition) else null,
            .instructions = instructions,
        });
    }

    return CompiledRule{
        .{ .agents = .{ .lhs = lhs_id, .rhs = rhs_id } },
        try lst.toOwnedSlice(runtime.allocator),
    };
}

const std = @import("std");
const AST = @import("ast");
const Runtime = @import("shared_runtime");
const Types = Runtime.Types;
const Compilation = @import("compilation.zig");

pub const Condition = @import("condition.zig");

const Scope = @import("scope.zig");
const RegisterId = Scope.RegisterId;
const NameInfo = Scope.NameInfo;

const Agent = Types.Agent;
const Special = Types.Special;
const Name = Types.Name;
const Value = Types.Value;
const Equation = Types.Equation;

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

pub const CompiledRule = struct {
    CompiledLhs,
    []ConditionedRule,
};

pub const ConditionedRule = struct {
    condition: ?*CompiledCondition,
    instructions: CompiledPairs,
};

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

const CompiledTerm = struct {
    reg: RegisterId,
    instrs: []Instruction,
};

const CompiledName = struct {
    name_info: *NameInfo,
    instrs: []Instruction,
};

pub fn compileNumber(
    runtime: *Runtime,
    obj: AST.Object,
    scope: *Scope,
) !CompiledTerm {
    const agent_id = runtime.agent_id_map.map.get(AST.number_special_ident).?;
    var list = std.ArrayList(Instruction).empty;
    const reg = scope.getFree();
    try list.append(runtime.allocator, mk_agent(agent_id, reg));
    const special_reg = scope.getFree();
    const special = try Compilation.getNumberType(obj.portlist.?[0].val.name);
    try list.append(runtime.allocator, mk_special(special, special_reg));
    try list.append(runtime.allocator, put_into_port(0, special_reg, reg));
    return .{ .reg = reg, .instrs = try list.toOwnedSlice(runtime.allocator) };
}

pub fn compileName(
    runtime: *Runtime,
    na: AST.Node(AST.Object),
    scope: *Scope,
    diag: *CompilationError,
) !CompiledName {
    const name = na.val.name;
    var list = std.ArrayList(Instruction).empty;
    var name_info: *NameInfo = undefined;
    if (scope.map.getPtr(name)) |existing| {
        if (!existing.used) {
            name_info = existing;
            existing.used = true;
        } else {
            diag.tag = .{
                .name_used_twice = .{
                    .first = existing.token_slice,
                    .second = na.tslice,
                },
            };
            return HandledError.NameUsedTwice;
        }
    } else {
        name_info = try scope.associate(name, na.tslice);
        try list.append(runtime.allocator, Instruction.mk_name(name_info.location));
    }

    return .{ .name_info = name_info, .instrs = try list.toOwnedSlice(runtime.allocator) };
}

pub fn compileAgent(
    runtime: *Runtime,
    ag: AST.Object,
    scope: *Scope,
    diag: *CompilationError,
) !CompiledTerm {
    var list = std.ArrayList(Instruction).empty;
    const id = try runtime.agent_id_map.get(ag.name);
    const arity = try runtime.agent_arities.get(id, ag.portlist.?.len);
    const reg = scope.getFree();
    try list.append(runtime.allocator, Instruction.mk_agent(id, reg));

    for (0..arity) |idx| {
        const port = ag.portlist.?[idx];
        if (port.val.portlist) |_| {
            if (port.val.isNumber()) {
                // number
                const compiledNumber = try compileNumber(runtime, port.val, scope);
                try list.appendSlice(runtime.allocator, compiledNumber.instrs);
                try list.append(runtime.allocator, Instruction.put_into_port(idx, compiledNumber.reg, reg));
            } else {
                const compiledAgent = try compileAgent(runtime, port.val, scope, diag);
                try list.appendSlice(runtime.allocator, compiledAgent.instrs);
                try list.append(runtime.allocator, Instruction.put_into_port(idx, compiledAgent.reg, reg));
            }
        } else {
            const compiledName = try compileName(runtime, port, scope, diag);
            try list.appendSlice(runtime.allocator, compiledName.instrs);
            try list.append(runtime.allocator, Instruction.put_into_port(idx, compiledName.name_info.location, reg));
        }
    }

    return .{ .reg = reg, .instrs = try list.toOwnedSlice(runtime.allocator) };
}

pub fn compileTerm(runtime: *Runtime, obj: AST.Node(AST.Object), scope: *Scope, diag: *CompilationError) !CompiledTerm {
    if (obj.val.portlist) |_| {
        if (obj.val.isNumber()) {
            return try compileNumber(runtime, obj.val, scope);
        } else {
            return try compileAgent(runtime, obj.val, scope, diag);
        }
    } else {
        const compiledName = try compileName(runtime, obj, scope, diag);
        return .{ .instrs = compiledName.instrs, .reg = compiledName.name_info.location };
    }
}

pub fn compilePairs(
    runtime: *Runtime,
    lhs: AST.Node(AST.Object),
    rhs: AST.Node(AST.Object),
    pairs: []AST.Node(AST.ActivePair),
    diag: *CompilationError,
) !CompiledPairs {
    var list = std.ArrayList(Instruction).empty;
    var scope = Scope.init(runtime.allocator);
    defer scope.deinit();

    // init the "arguments"
    try list.append(runtime.allocator, load_arguments());

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
        const compiledLhs = try compileTerm(runtime, pair.lhs, &scope, diag);
        const compiledRhs = try compileTerm(runtime, pair.rhs, &scope, diag);
        try list.appendSlice(runtime.allocator, compiledLhs.instrs);
        try list.appendSlice(runtime.allocator, compiledRhs.instrs);
        try list.append(runtime.allocator, Instruction.push(compiledLhs.reg, compiledRhs.reg));
    }

    return try list.toOwnedSlice(runtime.allocator);
}

pub fn compileCondition(
    runtime: *Runtime,
    port_info: *const std.StringHashMap(Port),
    condition: *AST.Node(AST.Expression),
    diag: *CompilationError,
) !*CompiledCondition {
    const compiled = try runtime.allocator.create(CompiledCondition);
    switch (condition.val) {
        .atom => |atom_node| {
            const atom = atom_node.val;
            if (atom.portlist) |ports| {
                if (atom.isNumber()) {
                    const num = ports[0].val.name;
                    compiled.* = .{ .atom = .{ .special = try Compilation.getNumberType(num) } };
                }
            } else {
                if (port_info.get(atom.name)) |port_idx| {
                    compiled.* = .{ .atom = .{ .port = port_idx } };
                } else {
                    diag.tag = .{ .unknown_name = condition.tslice };
                    return HandledError.UnknownName;
                }
            }
        },
        .binary_op => |binary| {
            compiled.* = .{ .binary_op = .{
                .op = binary.tag,
                .lhs = try compileCondition(runtime, port_info, binary.lhs, diag),
                .rhs = try compileCondition(runtime, port_info, binary.rhs, diag),
            } };
        },
        .unary_op => |unary| {
            compiled.* = .{ .unary_op = .{
                .op = unary.tag,
                .item = try compileCondition(runtime, port_info, unary.item, diag),
            } };
        },
    }

    return compiled;
}

pub fn compileWildcard(
    runtime: *Runtime,
    agent: AST.Node(AST.Object),
    name: AST.Node(AST.Object),
    rule_exprs: []AST.RuleExpression,
    diag: *CompilationError,
) !CompiledRule {
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
        const instructions = try compilePairs(runtime, agent, name, rule_expr.pairs, diag);
        try lst.append(runtime.allocator, .{
            .condition = if (rule_expr.expr) |condition| try compileCondition(runtime, &port_info, condition, diag) else null,
            .instructions = instructions,
        });
    }

    return CompiledRule{
        .{ .wildcard = agent_id },
        try lst.toOwnedSlice(runtime.allocator),
    };
}

pub fn compileRule(runtime: *Runtime, rule: AST.Rule, diag: *CompilationError) !CompiledRule {
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

    var lst = try std.ArrayList(ConditionedRule).initCapacity(runtime.allocator, 1);

    var port_info: std.StringHashMap(Port) = .init(runtime.allocator);

    for (rule.lhs.val.portlist.?, 0..) |port, idx| {
        try port_info.put(port.val.name, Port{ .idx = idx, .owner = .lhs });
    }

    for (rule.rhs.val.portlist.?, 0..) |port, idx| {
        try port_info.put(port.val.name, Port{ .idx = idx, .owner = .rhs });
    }

    for (rule.rule_exprs) |rule_expr| {
        const instructions = try compilePairs(runtime, rule.lhs, rule.rhs, rule_expr.pairs, diag);
        try lst.append(runtime.allocator, .{
            .condition = if (rule_expr.expr) |condition| try compileCondition(runtime, &port_info, condition, diag) else null,
            .instructions = instructions,
        });
    }

    return CompiledRule{
        .{ .agents = .{ .lhs = lhs_id, .rhs = rhs_id } },
        try lst.toOwnedSlice(runtime.allocator),
    };
}

pub const HandledError = CompilationError.HandledError;

const TokenSlice = AST.TokenSlice;

pub const CompilationError = struct {
    tag: ErrTag = undefined,

    const ErrTag = union(enum) {
        name_used_twice: struct {
            first: TokenSlice,
            second: TokenSlice,
        },
        unknown_name: TokenSlice,
        agent_in_argument: TokenSlice,
    };

    const HandledError = error{
        AgentInArgument,
        UnknownName,
        NameUsedTwice,
    };

    const Printing = @import("printing");
    const Token = AST.Lexer.Token;

    fn multiLineMarkup(
        connectedSlices: []const TokenSlice,
        tokens: []const Token,
        lines: *const Printing.Lines,
        gpa: std.mem.Allocator,
    ) ![]const u8 {
        var _arena = std.heap.ArenaAllocator.init(gpa);
        defer _arena.deinit();

        const arena = _arena.allocator();
        const init_line = tokens[connectedSlices[0].start].loc.start.line;
        var idx = init_line;

        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(gpa);

        for (connectedSlices) |slice| {
            const starting_line = tokens[slice.start].loc.start.line;
            const ending_line = tokens[slice.end].loc.end.line;

            while (idx < starting_line) : (idx += 1) {
                try list.append(gpa, try lines.getEnumerated(arena, idx));
            }

            if (ending_line == idx) {
                try list.append(gpa, try lines.getEnumerated(arena, idx));
                try list.append(gpa, try singleLineMarkup(&.{slice}, tokens, arena, Printing.Lines.enumeration_padding));
                idx += 1;
            } else {
                while (idx <= ending_line) : (idx += 1) {
                    const enumerated = try lines.getEnumerated(arena, idx);
                    try list.append(gpa, enumerated);

                    const markup_line = try arena.alloc(u8, enumerated.len);

                    if (idx == starting_line) {
                        const ch = tokens[slice.start].loc.start.ch + Printing.Lines.enumeration_padding;

                        @memset(markup_line, ' ');
                        markup_line[ch] = '^';

                        if (ch + 1 < markup_line.len)
                            @memset(markup_line[ch + 1 ..], '~');
                    } else if (idx == ending_line) {
                        const ch = tokens[slice.end].loc.end.ch + Printing.Lines.enumeration_padding;

                        @memset(markup_line, ' ');
                        @memset(markup_line[Printing.Lines.enumeration_padding .. ch + 1], '~');
                    } else {
                        @memset(markup_line[0..Printing.Lines.enumeration_padding], ' ');
                        @memset(markup_line[Printing.Lines.enumeration_padding..], '~');
                    }

                    try list.append(gpa, markup_line);
                }
            }
        }

        var ret: []const u8 = "";
        for (list.items) |line| {
            const cur = ret;
            defer gpa.free(cur);
            ret = try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ ret, line });
        }

        return ret;
    }

    /// Doesn't check if the tokens are really on the same line. The caller owns the slice.
    fn singleLineMarkup(
        connectedSlices: []const TokenSlice,
        tokens: []const Token,
        allocator: std.mem.Allocator,
        padding: usize,
    ) ![]const u8 {
        const markup_line = try allocator.alloc(u8, tokens[connectedSlices[connectedSlices.len - 1].end].loc.end.ch + padding);
        @memset(markup_line, ' ');
        for (connectedSlices) |slice| {
            markup_line[tokens[slice.start].loc.start.ch + padding] = '^';
            for (markup_line[tokens[slice.start].loc.start.ch + padding + 1 .. tokens[slice.end].loc.end.ch + padding]) |*c| {
                c.* = '~';
            }
        }
        return markup_line;
    }

    fn symbol(self: *const CompilationError) []const u8 {
        return switch (self.tag) {
            .name_used_twice => "Name used more than twice",
            .unknown_name => "Unknown name",
            .agent_in_argument => "Agent in the argument list",
        };
    }

    fn hint(self: *const CompilationError) []const u8 {
        return switch (self.tag) {
            .name_used_twice => "Names should be used exactly twice in one scope. Consider using duplicator agents (Dup2, Dup3, ...).",
            .unknown_name => "Check for typos.",
            .agent_in_argument =>
            \\What you're probably trying to do is nested pattern matching.
            \\Unfortunately it is either unimplemented or will never be implemented.
            \\Consider using real interaction nets nested pattern matching using additional helper agents.
        };
    }

    /// The message ends with a line break. The caller owns the message.
    pub fn getPrettyMessage(
        self: *const CompilationError,
        source_file: [:0]const u8,
        tokens: []const Token,
        gpa: std.mem.Allocator,
    ) ![]const u8 {
        var lines = try Printing.Lines.init(gpa, source_file);
        defer lines.deinit();
        const start_token, const end_token, const connectedSlices: []const TokenSlice = switch (self.tag) {
            .unknown_name, .agent_in_argument => |tslice| .{ tokens[tslice.start], tokens[tslice.end], &.{tslice} },
            .name_used_twice => |names| .{ tokens[names.first.start], tokens[names.second.end], &.{ names.first, names.second } },
        };

        if (start_token.loc.start.line == end_token.loc.end.line) {
            const line = lines.lines[start_token.loc.start.line];
            const marked_line = try singleLineMarkup(connectedSlices, tokens, gpa, 0);
            defer gpa.free(marked_line);
            return try std.fmt.allocPrint(
                gpa,
                "Rule compilation error on line {} index {}: {s}\n{s}\n{s}\n\nHint: {s}\n",
                .{
                    start_token.loc.start.line + 1,
                    start_token.loc.start.ch + 1,
                    self.symbol(),
                    line,
                    marked_line,
                    self.hint(),
                },
            );
        } else {
            const marked_lines = try multiLineMarkup(connectedSlices, tokens, &lines, gpa);
            defer gpa.free(marked_lines);
            return try std.fmt.allocPrint(
                gpa,
                "Rule compilation error starting on line {} index {}: {s}\n{s}\n\nHint: {s}\n",
                .{
                    start_token.loc.start.line + 1,
                    start_token.loc.start.ch + 1,
                    self.symbol(),
                    marked_lines,
                    self.hint(),
                },
            );
        }
    }
};

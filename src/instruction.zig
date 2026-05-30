const std = @import("std");
const AST = @import("parser.zig");
const Types = @import("types.zig");
const Runtime = @import("runtime.zig");
const VM = @import("vm.zig");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

const RegisterId = usize;
const PortIdx = usize;

pub const RuleKey = struct { lhs: Agent.Id, rhs: Agent.Id };

const Instruction = @This();

const Location = struct {
    reg: RegisterId,
    port: ?usize,
};

tag: Tag,
operand1: ?RegisterId,
operand2: ?RegisterId,
const Tag = union(enum) {
    MkAgent: Agent.Id,
    MkName,
    PutIntoPort: PortIdx,
    Push,
    PutArgumentPort: struct {
        take_lhs: bool,
        port_idx: usize,
    },
};

pub fn mk_agent(id: Agent.Id, loc: RegisterId) Instruction {
    return .{
        .tag = .{ .MkAgent = id },
        .operand1 = loc,
        .operand2 = null,
    };
}

pub fn mk_name(loc: RegisterId) Instruction {
    return .{
        .tag = .MkName,
        .operand1 = loc,
        .operand2 = null,
    };
}

pub fn put_into_port(port_idx: PortIdx, src: RegisterId, dest: RegisterId) Instruction {
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

pub fn put_argument_port(reg: RegisterId, take_lhs: bool, port_idx: usize) Instruction {
    return .{
        .tag = .{ .PutArgumentPort = .{ .take_lhs = take_lhs, .port_idx = port_idx } },
        .operand1 = reg,
        .operand2 = null,
    };
}

pub fn debugPrintInstruction(vm: *const VM, instrs: []Instruction) !void {
    for (instrs) |instr| {
        defer std.debug.print("\n\n", .{});
        std.debug.print("REG{} ", .{instr.operand1.?});
        if (instr.operand2) |operand2| {
            std.debug.print("TO REG{}", .{operand2});
        }
        std.debug.print(": ", .{});
        switch (instr.tag) {
            .MkAgent => |id| {
                const name = vm.runtime.agent_id_map.findKey(id).?;
                std.debug.print("MKAGENT {s}", .{name});
            },
            .Push => {
                std.debug.print("PUSH", .{});
            },
            .MkName => {
                std.debug.print("MKNAME", .{});
            },
            .PutArgumentPort => |port| {
                std.debug.print("PUT INTO {s} ARGUMENT PORT {}", .{ (if (port.take_lhs) "LHS" else "RHS"), port.port_idx });
            },
            .PutIntoPort => |port| {
                std.debug.print("PUT INTO {} PORT", .{port});
            },
        }
    }
}

const CompiledRule = struct { RuleKey, []Instruction };

const InstrsWithReturn = struct { reg: RegisterId, instrs: []Instruction };

const Scope = struct {
    map: std.StringHashMap(?RegisterId),
    free_idx: RegisterId,
    pub fn getFree(self: *Scope) RegisterId {
        defer self.free_idx += 1;
        return self.free_idx;
    }

    pub fn associate(self: *Scope, name: []const u8) !RegisterId {
        if (self.map.get(name)) |_| {
            return error.ValueExists;
        } else {
            const val = self.getFree();
            try self.map.put(name, val);
            return val;
        }
    }

    pub fn init(allocator: std.mem.Allocator) Scope {
        return .{
            .free_idx = 0,
            .map = std.StringHashMap(?RegisterId).init(allocator),
        };
    }
    pub fn deinit(self: *Scope) void {
        self.map.deinit();
    }
};

pub fn compileName(runtime: *Runtime, na: AST.Object, scope: *Scope) !InstrsWithReturn {
    const name = na.name;
    var list = std.ArrayList(Instruction).empty;
    var reg: usize = undefined;
    if (scope.map.getPtr(name)) |existing| {
        if (existing.*) |reg_id| {
            reg = reg_id;
            existing.* = null;
        } else {
            return error.NameUsedTwice;
        }
    } else {
        reg = try scope.associate(name);
        try list.append(runtime.allocator, Instruction.mk_name(reg));
    }

    return .{ .reg = reg, .instrs = try list.toOwnedSlice(runtime.allocator) };
}

pub fn compileAgent(runtime: *Runtime, ag: AST.Object, scope: *Scope) !InstrsWithReturn {
    var list = std.ArrayList(Instruction).empty;
    const id = try runtime.agent_id_map.get(ag.name);
    const arity = try runtime.agent_arities.get(id, ag.portlist.?.len);
    const reg = scope.getFree();
    try list.append(runtime.allocator, Instruction.mk_agent(id, reg));

    for (0..arity) |idx| {
        const port = ag.portlist.?[idx].val;
        if (port.portlist) |_| {
            const compiledAgent = try compileAgent(runtime, port, scope);
            try list.appendSlice(runtime.allocator, compiledAgent.instrs);
            try list.append(runtime.allocator, Instruction.put_into_port(idx, compiledAgent.reg, reg));
        } else {
            const compiledName = try compileName(runtime, port, scope);
            try list.appendSlice(runtime.allocator, compiledName.instrs);
            try list.append(runtime.allocator, Instruction.put_into_port(idx, compiledName.reg, reg));
        }
    }

    return .{ .reg = reg, .instrs = try list.toOwnedSlice(runtime.allocator) };
}

pub fn compileTerm(runtime: *Runtime, obj: AST.Object, scope: *Scope) !InstrsWithReturn {
    if (obj.portlist) |_| {
        return try compileAgent(runtime, obj, scope);
    } else {
        return try compileName(runtime, obj, scope);
    }
}

pub fn compileRule(runtime: *Runtime, rule: AST.Rule) !CompiledRule {
    const lhs = try runtime.agent_id_map.get(rule.lhs.val.name);
    const rhs = try runtime.agent_id_map.get(rule.rhs.val.name);
    var list = std.ArrayList(Instruction).empty;
    var scope = Scope.init(runtime.allocator);
    defer scope.deinit();

    // init the "arguments"

    for (rule.lhs.val.portlist.?, 0..) |port_node, idx| {
        const port = port_node.val;
        if (port.portlist) |_| {
            return error.AgentInLhsArgument;
        } else {
            const compiledName = try compileName(runtime, port, &scope);
            try list.appendSlice(runtime.allocator, compiledName.instrs);
            try list.append(runtime.allocator, put_argument_port(compiledName.reg, true, idx));
        }
    }

    for (rule.rhs.val.portlist.?, 0..) |port_node, idx| {
        const port = port_node.val;
        if (port.portlist) |_| {
            return error.AgentInRhsArgument;
        } else {
            const compiledName = try compileName(runtime, port, &scope);
            try list.appendSlice(runtime.allocator, compiledName.instrs);
            try list.append(runtime.allocator, put_argument_port(compiledName.reg, false, idx));
        }
    }

    for (rule.pairs) |node_pair| {
        const pair = node_pair.val;
        const compiledLhs = try compileTerm(runtime, pair.lhs.val, &scope);
        const compiledRhs = try compileTerm(runtime, pair.rhs.val, &scope);
        try list.appendSlice(runtime.allocator, compiledLhs.instrs);
        try list.appendSlice(runtime.allocator, compiledRhs.instrs);
        try list.append(runtime.allocator, Instruction.push(compiledLhs.reg, compiledRhs.reg));
    }
    return .{ .{ .lhs = lhs, .rhs = rhs }, try list.toOwnedSlice(runtime.allocator) };
}

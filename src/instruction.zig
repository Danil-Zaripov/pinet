const std = @import("std");
const AST = @import("parser.zig");
const Types = @import("types.zig");
const Runtime = @import("runtime.zig");
const VM = @import("vm.zig");

const Agent = Types.Agent;
const Special = Types.Special;
const Name = Types.Name;
const Value = Types.Value;
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
// Better than optional?
operand1: RegisterId = undefined,
operand2: RegisterId = undefined,
const Tag = union(enum) {
    MkAgent: Agent.Id,
    MkName,
    MkSpecial: Special,
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
    };
}

pub fn debugPrintInstruction(vm: *const VM, instrs: []Instruction) !void {
    for (instrs) |instr| {
        defer std.debug.print("\n\n", .{});
        std.debug.print("REG{} ", .{instr.operand1});
        if (instr.tag == .Push or instr.tag == .PutArgumentPort) {
            std.debug.print("TO REG{}", .{instr.operand2});
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
            if (port.name[0] == '#') {
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
        if (obj.name[0] == '#') {
            return try compileNumber(runtime, obj, scope);
        } else {
            return try compileAgent(runtime, obj, scope);
        }
    } else {
        const compiledName = try compileName(runtime, obj, scope);
        return .{ .instrs = compiledName.instrs, .reg = compiledName.name_info.location };
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
            try list.append(runtime.allocator, put_argument_port(compiledName.name_info.location, true, idx));
        }
    }

    for (rule.rhs.val.portlist.?, 0..) |port_node, idx| {
        const port = port_node.val;
        if (port.portlist) |_| {
            return error.AgentInRhsArgument;
        } else {
            const compiledName = try compileName(runtime, port, &scope);
            try list.appendSlice(runtime.allocator, compiledName.instrs);
            try list.append(runtime.allocator, put_argument_port(compiledName.name_info.location, false, idx));
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

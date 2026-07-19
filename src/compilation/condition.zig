//! Module that encapsulates compiling conditions into a stream of condition instructions.
//! Conditions are not a part of interaction nets, but rather a heuristic mechanism.
//! They may fail even when the interaction net is valid, therefore we need some better way to abstract that.
//! But for now this will do.

const std = @import("std");

const Scope = @import("scope.zig");
const AST = @import("ast");
const Runtime = @import("shared_runtime");
const Types = Runtime.Types;
const Builtin = @import("vm").Builtin;
const Compilation = @import("compilation.zig");
const Diagnostic = Compilation.Diagnostic;
const HandledError = Diagnostic.HandledError;

const Agent = Types.Agent;
const Special = Types.Special;
const Name = Types.Name;
const Value = Types.Value;
const Equation = Types.Equation;

pub const Port = struct {
    owner: Owner,

    // Null means the owner is a name in case of a wildcard rule
    idx: ?Idx,

    pub const Idx = u8;

    pub const Owner = enum {
        rhs,
        lhs,
    };
};

pub const Register = struct {
    pub const Id = u8;
    pub const CondValue = union(enum) {
        bool: bool,
        special: Special,
        agent: *Agent,
    };
};

const ConditionScope = struct {
    map: std.AutoHashMap(Port, Register.Id),
    free_idx: Register.Id = 0,

    pub fn init(gpa: std.mem.Allocator) !ConditionScope {
        return ConditionScope{
            .map = .init(gpa),
        };
    }

    pub fn getFree(self: *ConditionScope) Register.Id {
        defer self.free_idx += 1;
        return self.free_idx;
    }

    pub fn associate(self: *ConditionScope, port: Port) !Register.Id {
        std.debug.assert(!self.map.contains(port));

        defer self.free_idx += 1;

        try self.map.put(port, self.free_idx);

        return self.free_idx;
    }

    pub fn deinit(self: *ConditionScope) void {
        self.map.deinit();
    }
};

pub const Op = struct {
    pub const Binary = AST.Expression.BinaryExpr.Tag;
    pub const Unary = AST.Expression.UnaryExpr.Tag;
};

pub const Instruction = struct {
    /// lhs is used as the main argument in unary operations
    lhs: Register.Id = undefined,
    rhs: Register.Id = undefined,
    result: Register.Id = undefined,
    tag: Tag,

    const Tag = union(enum) {
        assert_id: Types.Agent.Id,

        /// Only after assertion
        get_special,

        apply_bin: Op.Binary,
        apply_un: Op.Unary,
        put_constant: Special,
        put_port: Port,
        get_result,
    };

    pub fn put_constant(reg: Register.Id, constant: Special) Instruction {
        return .{
            .result = reg,
            .tag = .{ .put_constant = constant },
        };
    }

    pub fn put_port(reg: Register.Id, port: Port) Instruction {
        return .{
            .result = reg,
            .tag = .{ .put_port = port },
        };
    }

    pub fn assert_id(reg: Register.Id, id: Agent.Id) Instruction {
        return .{
            .lhs = reg,
            .tag = .{ .assert_id = id },
        };
    }

    pub fn get_special(reg: Register.Id, res_id: Register.Id) Instruction {
        return .{
            .lhs = reg,
            .result = res_id,
            .tag = .get_special,
        };
    }

    pub fn apply_bin(lhs: Register.Id, rhs: Register.Id, res: Register.Id, op: Op.Binary) Instruction {
        return .{
            .lhs = lhs,
            .rhs = rhs,
            .result = res,
            .tag = .{ .apply_bin = op },
        };
    }

    pub fn get_result(reg: Register.Id) Instruction {
        return .{
            .result = reg,
            .tag = .get_result,
        };
    }
};

pub const Context = struct {
    runtime: *Runtime,
    instrs_list: std.ArrayList(Instruction),
    scope: ConditionScope,
    port_info: *const std.StringHashMap(Port),
    diag: *Diagnostic,

    pub fn init(runtime: *Runtime, port_info: *const std.StringHashMap(Port), diag: *Diagnostic) !Context {
        return .{
            .runtime = runtime,
            .instrs_list = .empty,
            .scope = try .init(runtime.gpa),
            .port_info = port_info,
            .diag = diag,
        };
    }

    pub fn putInstruction(self: *Context, instr: Instruction) !void {
        try self.instrs_list.append(self.runtime.gpa, instr);
    }

    pub fn deinitAndGetInstrs(self: *Context) ![]Instruction {
        self.scope.deinit();
        return try toArenaOwnedSlice(Instruction, &self.instrs_list, self.runtime.gpa, self.runtime.arena);
    }

    /// Use in case of an error.
    pub fn deinit(self: *Context) void {
        self.scope.deinit();
        self.instrs_list.deinit(self.runtime.gpa);
    }
};

pub const CompileResult = struct {
    result: Register.Id,
};

pub fn getPortReg(ctx: *Context, obj: AST.Node(AST.Object)) !CompileResult {
    if (ctx.port_info.get(obj.val.name)) |port| {
        return .{ .result = port_reg: {
            if (ctx.scope.map.get(port)) |reg| {
                break :port_reg reg;
            } else {
                const reg = try ctx.scope.associate(port);
                try ctx.putInstruction(.put_port(reg, port));
                break :port_reg reg;
            }
        } };
    } else {
        ctx.diag.* = .{
            .tag = .{ .unknown_name = obj.tslice },
        };
        return error.UnknownName;
    }
}

pub fn compileUnary(
    ctx: *Context,
    expr_node: *const AST.Node(AST.Expression),
    unary: AST.Expression.UnaryExpr,
) !CompileResult {
    _ = ctx;
    _ = expr_node;
    _ = unary;
}

/// If an operation expects a number, this function can help assert that it is there and get the result. Otherwise,
/// just a normal compilation.
pub fn tryAssertNumber(ctx: *Context, expr_node: *const AST.Node(AST.Expression)) !CompileResult {
    const number_id = comptime Builtin.BuiltinNameMap.get(AST.number_special_ident).?;

    const expr = expr_node.val;
    switch (expr) {
        .atom => |atom| {
            if (atom.val.getNumberIfNumber()) |num| {
                const special: Special = try .parse(num);
                const reg_id = ctx.scope.getFree();

                try ctx.putInstruction(.put_constant(reg_id, special));

                return .{ .result = reg_id };
            } else {
                const port_reg = try getPortReg(ctx, atom);

                try ctx.putInstruction(.assert_id(port_reg.result, number_id));
                const res_id = ctx.scope.getFree();
                try ctx.putInstruction(.get_special(port_reg.result, res_id));

                return .{ .result = res_id };
            }
        },
        else => return try compileCondition(ctx, expr_node),
    }
}
pub fn compileBinary(
    ctx: *Context,
    expr_node: *const AST.Node(AST.Expression),
    binary: AST.Expression.BinaryExpr,
) !CompileResult {
    _ = expr_node;

    switch (binary.tag) {
        .eq,
        .geq,
        .leq,
        .greater,
        .less,
        => {
            const lhs = try tryAssertNumber(ctx, binary.lhs);
            const rhs = try tryAssertNumber(ctx, binary.rhs);
            const res = ctx.scope.getFree();
            try ctx.putInstruction(.apply_bin(lhs.result, rhs.result, res, binary.tag));
            return .{ .result = res };
        },
        else => {
            const lhs = try compileCondition(ctx, binary.lhs);
            const rhs = try compileCondition(ctx, binary.rhs);
            const res = ctx.scope.getFree();
            try ctx.putInstruction(.apply_bin(lhs.result, rhs.result, res, binary.tag));
            return .{ .result = res };
        },
    }
}

const ConditionError = error{
    UnknownName,
} || std.mem.Allocator.Error || std.fmt.ParseIntError;

pub fn compileCondition(ctx: *Context, expr_node: *const AST.Node(AST.Expression)) ConditionError!CompileResult {
    const expr = expr_node.val;
    switch (expr) {
        .atom => |atom| {
            return try getPortReg(ctx, atom);
        },
        .unary_op => |unary| {
            _ = unary;
            unreachable;
        },
        .binary_op => |binary| {
            return try compileBinary(ctx, expr_node, binary);
        },
    }
}

pub fn compile(
    runtime: *Runtime,
    port_info: *const std.StringHashMap(Port),
    expr_node: *const AST.Node(AST.Expression),
    diag: *Compilation.Diagnostic,
) ![]Instruction {
    var context: Context = try .init(runtime, port_info, diag);
    errdefer context.deinit();

    const res = try compileCondition(&context, expr_node);
    try context.putInstruction(.get_result(res.result));

    return try context.deinitAndGetInstrs();
}

const toArenaOwnedSlice = Compilation.toArenaOwnedSlice;

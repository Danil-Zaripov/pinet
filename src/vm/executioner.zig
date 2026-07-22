const std = @import("std");
const builtin = @import("builtin");

const Core = @import("core.zig");

const Compilation = @import("compilation");
const Bytecode = Compilation.Instruction.Bytecode;

const Runtime = @import("shared_runtime");
const Types = Runtime.Types;
const Agent = Types.Agent;
const Name = Types.Name;
const Value = Types.Value;
const Special = Types.Special;
const EquationUnnormalized = Types.EquationUnnormalized;

pub const ExecContext = struct {
    c: *Core,
    code: []Bytecode,
    lagent: *Agent,
    ragent: *Agent,
    wildcarded: bool,
    pc: usize,
};

const ExecutionError = error{NoFallBack} || std.mem.Allocator.Error;

const InstructionHandler = *const fn (*ExecContext) ExecutionError!void;

const handlers = comptime_init: {
    var init: [256]InstructionHandler = undefined;
    for (@typeInfo(Bytecode.Opcode).@"enum".fields) |field| {
        const enumed: Bytecode.Opcode = @enumFromInt(field.value);
        init[field.value] = switch (enumed) {
            .begin_block => begin_block,
            .end_block => end,
            .o_return => end,
            .load_port => load_port,
            .mk_agent => mk_agent,
            .mk_name => mk_name,
            .mk_special_float => mk_special_float,
            .mk_special_integer => mk_special_integer,
            .push => push,
            .c_apply_bin => c_apply_bin,
            .c_load_port_lhs => c_load_port_lhs,
            .c_load_port_rhs => c_load_port_rhs,
            .c_load_wildcard_rhs => c_load_wildcard_rhs,
            .c_assert_id => c_assert_id,
            .c_put_special_float => c_put_special_float,
            .c_put_special_integer => c_put_special_integer,
            .c_get_special => c_get_special,
            .c_apply_un => c_apply_un,
            .c_njump => c_njump,
            .load_arguments => load_arguments,
        };
    }

    break :comptime_init init;
};

inline fn dispatchFallback(ctx: *ExecContext, potential_fallback: anytype) ExecutionError!void {
    const fallback: usize =
        if (potential_fallback != -1)
            @intCast(potential_fallback)
        else
            return error.NoFallBack;
    ctx.pc = fallback;
}

fn begin_block(ctx: *ExecContext) ExecutionError!void {
    _ = ctx;
}

fn end(ctx: *ExecContext) ExecutionError!void {
    ctx.pc = ctx.code.len;
}

fn load_arguments(ctx: *ExecContext) ExecutionError!void {
    const larity = ctx.c.runtime.agent_arities.map.items[ctx.lagent.id];
    var idx: u16 = 0;
    for (0..larity) |port_idx| {
        ctx.c.registers[idx] = ctx.lagent.ports[port_idx];
        idx += 1;
    }
    if (!ctx.wildcarded) {
        const rarity = ctx.c.runtime.agent_arities.map.items[ctx.ragent.id];
        for (0..rarity) |port_idx| {
            ctx.c.registers[idx] = ctx.ragent.ports[port_idx];
            idx += 1;
        }
    } else {
        ctx.c.registers[idx] = .{ .agent = ctx.ragent };
        idx += 1;
    }
}

fn load_port(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    ctx.c.registers[instr.dest].agent.ports[instr.val.id] = ctx.c.registers[instr.src];
}

fn mk_agent(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    ctx.c.registers[instr.dest] = .{ .agent = try ctx.c.createAgent(instr.val.id) };
}

fn mk_name(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    const name = try ctx.c.name_heap.allocOne();
    name.port = null;
    ctx.c.registers[instr.dest] = .{ .name = name };
}

fn mk_special_float(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    ctx.c.registers[instr.dest] = .{ .special = .{ .float = instr.val.float } };
}

fn mk_special_integer(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    ctx.c.registers[instr.dest] = .{ .special = .{ .integer = instr.val.integer } };
}

fn push(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    const eq = EquationUnnormalized{
        .lhs = ctx.c.registers[instr.src],
        .rhs = ctx.c.registers[instr.dest],
    };
    try ctx.c.pushEquation(eq);
}

fn c_load_port_lhs(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    const agent = ctx.lagent.ports[instr.src].getAgent() orelse {
        try dispatchFallback(ctx, instr.val.integer);
        return;
    };
    ctx.c.condition_registers[instr.dest] = .{ .agent = agent };
}

fn c_load_port_rhs(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    const agent = ctx.ragent.ports[instr.src].getAgent() orelse {
        try dispatchFallback(ctx, instr.val.integer);
        return;
    };
    ctx.c.condition_registers[instr.dest] = .{ .agent = agent };
}

fn c_load_wildcard_rhs(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    ctx.c.condition_registers[instr.dest] = .{ .agent = ctx.ragent };
}

fn c_assert_id(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    const agent_id = ctx.c.condition_registers[instr.dest].agent.id;
    if (agent_id != @as(usize, @intCast(instr.src))) {
        try dispatchFallback(ctx, instr.val.integer);
        return;
    }
}

fn c_put_special_float(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    ctx.c.condition_registers[instr.dest] = .{ .special = Special{ .float = instr.val.float } };
}

fn c_put_special_integer(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    ctx.c.condition_registers[instr.dest] = .{ .special = Special{ .integer = instr.val.integer } };
}

fn c_get_special(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    ctx.c.condition_registers[instr.dest] = .{ .special = ctx.c.condition_registers[instr.src].agent.ports[0].special };
}

fn c_apply_bin(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    const potential_fallback = instr.val.binary_operation.fallback;

    const lhs = ctx.c.condition_registers[instr.src];
    const rhs = ctx.c.condition_registers[instr.val.binary_operation.additional_argument];
    if (lhs == .bool and rhs == .bool) {
        switch (instr.val.binary_operation.tag) {
            .logic_and => ctx.c.condition_registers[instr.dest] = .{ .bool = lhs.bool and rhs.bool },
            .logic_or => ctx.c.condition_registers[instr.dest] = .{ .bool = lhs.bool or rhs.bool },
            else => {
                try dispatchFallback(ctx, potential_fallback);
                return;
            },
        }
        return;
    }

    if (lhs == .special and rhs == .special) {
        switch (instr.val.binary_operation.tag) {
            .eq => ctx.c.condition_registers[instr.dest] = .{ .bool = Special.eq(lhs.special, rhs.special) },
            .geq => ctx.c.condition_registers[instr.dest] = .{ .bool = Special.geq(lhs.special, rhs.special) },
            .greater => ctx.c.condition_registers[instr.dest] = .{ .bool = Special.greater(lhs.special, rhs.special) },
            .leq => ctx.c.condition_registers[instr.dest] = .{ .bool = Special.leq(lhs.special, rhs.special) },
            .less => ctx.c.condition_registers[instr.dest] = .{ .bool = Special.less(lhs.special, rhs.special) },
            else => {
                try dispatchFallback(ctx, potential_fallback);
                return;
            },
        }
        return;
    }
    try dispatchFallback(ctx, potential_fallback);
}

fn c_apply_un(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    const potential_fallback = instr.val.unary_operation.fallback;
    if (ctx.c.condition_registers[instr.src] == .bool) {
        ctx.c.condition_registers[instr.dest] = .{ .bool = !ctx.c.condition_registers[instr.src].bool };
        return;
    }

    try dispatchFallback(ctx, potential_fallback);
}

fn c_njump(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc];
    if (ctx.c.condition_registers[instr.dest] != .bool or !ctx.c.condition_registers[instr.dest].bool) {
        try dispatchFallback(ctx, instr.val.integer);
        return;
    }
}

pub fn execBytecode(ctx: *ExecContext) ExecutionError!void {
    while (ctx.pc < ctx.code.len) : (ctx.pc += 1) {
        const handler = handlers[@intFromEnum(ctx.code[ctx.pc].opcode)];

        try @call(.auto, handler, .{ctx});
    }
}

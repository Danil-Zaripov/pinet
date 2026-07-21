const std = @import("std");

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
    code: [*]DispatchingInstruction,
    lagent: *Agent,
    ragent: *Agent,
    wildcarded: bool,
    pc: usize,
};

const ExecutionError = error{NoFallBack} || std.mem.Allocator.Error;

const InstructionHandler = *const fn (*ExecContext) ExecutionError!void;

pub const DispatchingInstruction = struct {
    handler: InstructionHandler,
    code: Bytecode,
};

pub fn generateDispatch(arena: std.mem.Allocator, code: []Bytecode) ![*]DispatchingInstruction {
    const arr = try arena.alloc(DispatchingInstruction, code.len);
    for (code, 0..) |instr, idx| {
        arr[idx].code = instr;
        arr[idx].handler = switch (instr.opcode) {
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
    return arr.ptr;
}

inline fn dispatchCurrent(ctx: *ExecContext) ExecutionError!void {
    try @call(.always_tail, ctx.code[ctx.pc].handler, .{ctx});
}

inline fn dispatchNext(ctx: *ExecContext) ExecutionError!void {
    ctx.pc += 1;
    try dispatchCurrent(ctx);
}

inline fn dispatchFallback(ctx: *ExecContext, potential_fallback: anytype) ExecutionError!void {
    const fallback: usize =
        if (potential_fallback != -1)
            @intCast(potential_fallback)
        else
            return error.NoFallBack;
    ctx.pc = fallback;
    try dispatchCurrent(ctx);
}

fn begin_block(ctx: *ExecContext) ExecutionError!void {
    try dispatchNext(ctx);
}

fn end(ctx: *ExecContext) ExecutionError!void {
    _ = ctx;
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
    try dispatchNext(ctx);
}

fn load_port(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    ctx.c.registers[instr.dest].agent.ports[instr.val.id] = ctx.c.registers[instr.src];
    try dispatchNext(ctx);
}

fn mk_agent(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    ctx.c.registers[instr.dest] = .{ .agent = try ctx.c.createAgent(instr.val.id) };
    try dispatchNext(ctx);
}

fn mk_name(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    const name = try ctx.c.name_heap.allocOne();
    name.port = null;
    ctx.c.registers[instr.dest] = .{ .name = name };
    try dispatchNext(ctx);
}

fn mk_special_float(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    ctx.c.registers[instr.dest] = .{ .special = .{ .float = instr.val.float } };
    try dispatchNext(ctx);
}

fn mk_special_integer(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    ctx.c.registers[instr.dest] = .{ .special = .{ .integer = instr.val.integer } };
    try dispatchNext(ctx);
}

fn push(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    const eq = EquationUnnormalized{
        .lhs = ctx.c.registers[instr.src],
        .rhs = ctx.c.registers[instr.dest],
    };
    try ctx.c.pushEquation(eq);
    try dispatchNext(ctx);
}

fn c_load_port_lhs(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    const agent = ctx.lagent.ports[instr.src].getAgent() orelse {
        try dispatchFallback(ctx, instr.val.integer);
        return;
    };
    ctx.c.condition_registers[instr.dest] = .{ .agent = agent };
    try dispatchNext(ctx);
}

fn c_load_port_rhs(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    const agent = ctx.ragent.ports[instr.src].getAgent() orelse {
        try dispatchFallback(ctx, instr.val.integer);
        return;
    };
    ctx.c.condition_registers[instr.dest] = .{ .agent = agent };
    try dispatchNext(ctx);
}

fn c_load_wildcard_rhs(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    ctx.c.condition_registers[instr.dest] = .{ .agent = ctx.ragent };
    try dispatchNext(ctx);
}

fn c_assert_id(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    const agent_id = ctx.c.condition_registers[instr.dest].agent.id;
    if (agent_id != @as(usize, @intCast(instr.src))) {
        try dispatchFallback(ctx, instr.val.integer);
        return;
    }
    try dispatchNext(ctx);
}

fn c_put_special_float(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    ctx.c.condition_registers[instr.dest] = .{ .special = Special{ .float = instr.val.float } };
    try dispatchNext(ctx);
}

fn c_put_special_integer(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    ctx.c.condition_registers[instr.dest] = .{ .special = Special{ .integer = instr.val.integer } };
    try dispatchNext(ctx);
}

fn c_get_special(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    ctx.c.condition_registers[instr.dest] = .{ .special = ctx.c.condition_registers[instr.src].agent.ports[0].special };
    try dispatchNext(ctx);
}

fn c_apply_bin(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
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
        try dispatchNext(ctx);
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
        try dispatchNext(ctx);
        return;
    }
    try dispatchFallback(ctx, potential_fallback);
}

fn c_apply_un(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    const potential_fallback = instr.val.unary_operation.fallback;
    if (ctx.c.condition_registers[instr.src] == .bool) {
        ctx.c.condition_registers[instr.dest] = .{ .bool = !ctx.c.condition_registers[instr.src].bool };
        try dispatchNext(ctx);
        return;
    }

    try dispatchFallback(ctx, potential_fallback);
}

fn c_njump(ctx: *ExecContext) ExecutionError!void {
    const instr = ctx.code[ctx.pc].code;
    if (ctx.c.condition_registers[instr.dest] != .bool or !ctx.c.condition_registers[instr.dest].bool) {
        try dispatchFallback(ctx, instr.val.integer);
        return;
    }
    try dispatchNext(ctx);
}

pub fn execBytecode(c: *Core, code: []Bytecode, lagent: *Agent, ragent: *Agent, wildcarded: bool) !void {
    var pc: usize = 0;

    while (pc < code.len) : (pc += 1) {
        const instr = code[pc];
        switch (instr.opcode) {
            .load_arguments => {
                const larity = c.runtime.agent_arities.map.get(lagent.id).?;
                var idx: u16 = 0;
                for (0..larity) |port_idx| {
                    c.registers[idx] = lagent.ports[port_idx];
                    idx += 1;
                }
                if (!wildcarded) {
                    const rarity = c.runtime.agent_arities.map.get(ragent.id).?;
                    for (0..rarity) |port_idx| {
                        c.registers[idx] = ragent.ports[port_idx];
                        idx += 1;
                    }
                } else {
                    c.registers[idx] = .{ .agent = ragent };
                    idx += 1;
                }
            },
            .load_port => {
                c.registers[instr.dest].agent.ports[instr.val.id] = c.registers[instr.src];
            },
            .mk_agent => {
                c.registers[instr.dest] = .{ .agent = try c.createAgent(instr.val.id) };
            },
            .mk_name => {
                const name = try c.name_heap.allocOne();
                name.port = null;
                c.registers[instr.dest] = .{ .name = name };
            },
            .mk_special_float => {
                c.registers[instr.dest] = .{ .special = .{ .float = instr.val.float } };
            },
            .mk_special_integer => {
                c.registers[instr.dest] = .{ .special = .{ .integer = instr.val.integer } };
            },
            .push => {
                const eq = EquationUnnormalized{
                    .lhs = c.registers[instr.src],
                    .rhs = c.registers[instr.dest],
                };
                try c.pushEquation(eq);
            },
            //
            .c_load_port_lhs => {
                c.condition_registers[instr.dest] = .{ .agent = lagent.ports[instr.src].getAgent() orelse {
                    const fallback: usize = if (instr.val.integer != -1) @intCast(instr.val.integer) else return error.NoFallBack;
                    pc = fallback;
                    continue;
                } };
            },
            .c_load_port_rhs => {
                c.condition_registers[instr.dest] = .{ .agent = ragent.ports[instr.src].getAgent() orelse {
                    const fallback: usize = if (instr.val.integer != -1) @intCast(instr.val.integer) else return error.NoFallBack;
                    pc = fallback;
                    continue;
                } };
            },
            .c_load_wildcard_rhs => {
                c.condition_registers[instr.dest] = .{ .agent = ragent };
            },
            .c_put_special_float => {
                c.condition_registers[instr.dest] = .{ .special = Special{ .float = instr.val.float } };
            },
            .c_put_special_integer => {
                c.condition_registers[instr.dest] = .{ .special = Special{ .integer = instr.val.integer } };
            },
            .c_apply_bin => {
                const potential_fallback = instr.val.binary_operation.fallback;

                const lhs = c.condition_registers[instr.src];
                const rhs = c.condition_registers[instr.val.binary_operation.additional_argument];
                if (lhs == .bool and rhs == .bool) {
                    switch (instr.val.binary_operation.tag) {
                        .logic_and => c.condition_registers[instr.dest] = .{ .bool = lhs.bool and rhs.bool },
                        .logic_or => c.condition_registers[instr.dest] = .{ .bool = lhs.bool or rhs.bool },
                        else => {
                            const fallback: usize =
                                if (potential_fallback != -1)
                                    @intCast(potential_fallback)
                                else
                                    return error.NoFallBack;

                            pc = fallback;
                            continue;
                        },
                    }
                    continue;
                }

                if (lhs == .special and rhs == .special) {
                    switch (instr.val.binary_operation.tag) {
                        .eq => c.condition_registers[instr.dest] = .{ .bool = Special.eq(lhs.special, rhs.special) },
                        .geq => c.condition_registers[instr.dest] = .{ .bool = Special.geq(lhs.special, rhs.special) },
                        .greater => c.condition_registers[instr.dest] = .{ .bool = Special.greater(lhs.special, rhs.special) },
                        .leq => c.condition_registers[instr.dest] = .{ .bool = Special.leq(lhs.special, rhs.special) },
                        .less => c.condition_registers[instr.dest] = .{ .bool = Special.less(lhs.special, rhs.special) },
                        else => {
                            const fallback: usize =
                                if (potential_fallback != -1)
                                    @intCast(potential_fallback)
                                else
                                    return error.NoFallBack;

                            pc = fallback;
                            continue;
                        },
                    }
                    continue;
                }
                const fallback: usize =
                    if (potential_fallback != -1)
                        @intCast(potential_fallback)
                    else
                        return error.NoFallBack;

                pc = fallback;
                continue;
            },
            .c_apply_un => {
                const potential_fallback = instr.val.unary_operation.fallback;
                if (c.condition_registers[instr.src] == .bool) {
                    c.condition_registers[instr.dest] = .{ .bool = !c.condition_registers[instr.src].bool };
                } else {
                    const fallback: usize =
                        if (potential_fallback != -1)
                            @intCast(potential_fallback)
                        else
                            return error.NoFallBack;

                    pc = fallback;
                    continue;
                }
            },
            .c_assert_id => {
                const agent_id = c.condition_registers[instr.dest].agent.id;
                if (agent_id != @as(usize, @intCast(instr.src))) {
                    const fallback: usize = if (instr.val.integer != -1) @intCast(instr.val.integer) else return error.NoFallBack;
                    pc = fallback;
                    continue;
                }
            },
            .c_get_special => {
                c.condition_registers[instr.dest] = .{ .special = c.condition_registers[instr.src].agent.ports[0].special };
            },
            .c_njump => {
                if (c.condition_registers[instr.dest] != .bool or !c.condition_registers[instr.dest].bool) {
                    const fallback: usize = if (instr.val.integer != -1) @intCast(instr.val.integer) else return error.NoFallBack;
                    pc = fallback;
                    continue;
                }
            },
            .o_return => {
                return;
            },
            .begin_block => {},
            .end_block => {
                return;
            },
        }
    }
}

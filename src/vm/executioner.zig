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
            .begin_block => {},
            .end_block => {
                return;
            },
        }
    }
}

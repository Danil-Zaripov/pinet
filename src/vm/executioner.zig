const std = @import("std");

const Core = @import("core.zig");

const Compilation = @import("compilation");
const Bytecode = Compilation.Instruction.Bytecode;

const Runtime = @import("shared_runtime");
const Types = Runtime.Types;
const Agent = Types.Agent;
const Name = Types.Name;
const Value = Types.Value;
const EquationUnnormalized = Types.EquationUnnormalized;

pub fn execBytecode(c: *Core, code: []Bytecode, lagent: *Agent, ragent: *Agent, wildcarded: bool) !void {
    for (code) |instr| {
        switch (instr.opcode) {
            .load_arguments => {
                const larity = c.runtime.agent_arities.map.get(lagent.id).?;
                var idx: u16 = 0;
                for (0..larity) |port_idx| {
                    c.registers[idx] = lagent.ports[port_idx].?;
                    idx += 1;
                }
                if (!wildcarded) {
                    const rarity = c.runtime.agent_arities.map.get(ragent.id).?;
                    for (0..rarity) |port_idx| {
                        c.registers[idx] = ragent.ports[port_idx].?;
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
                const ag = try c.agent_heap.allocOne();
                ag.* = .{ .id = instr.val.id, .ports = @splat(null) };
                c.registers[instr.dest] = .{ .agent = ag };
            },
            .mk_name => {
                const name = try c.name_heap.allocOne();
                name.* = .{ .port = null };
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
        }
    }
}

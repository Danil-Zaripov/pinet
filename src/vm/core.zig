//! Core is a thing that executes interactions.
//!
//! Anything shared between cores is in the
//! Runtime module.
const std = @import("std");

pub const Builtin = @import("builtin.zig");
pub const Interaction = @import("interactions.zig");
pub const Importer = @import("importer.zig");

const Runtime = @import("shared_runtime");
const Types = Runtime.Types;
const Memory = Runtime.Memory;
const EquationFetcher = Runtime.EquationFetcher;

const Compilation = @import("compilation");
const Instruction = Compilation.Instruction;
const Condition = Compilation.Condition;

const CoreCommon = @import("core_common.zig");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const EquationUnnormalized = Types.EquationUnnormalized;

const Core = @This();
const Self = Core;

const number_of_registers = 256;

/// Per-core state - the heap and fetcher a given Core exclusively works
/// with, as opposed to CoreCommon which every Core shares.
pub const LocalCtx = struct {
    name_heap: Memory.Heap(Name),
    agent_heap: Memory.Heap(Agent),
    equation_fetcher: EquationFetcher,
};

// the heaps should be in the runtime!
id: u32,
// Execution only ever reads Runtime (rule/arity/id lookups) - everything
// that mutates it (rule registration, imports, associated_names) lives in
// VM's statement handling now, so this can be const.
runtime: *const Runtime,
core_common: *CoreCommon,
local_ctx: LocalCtx,

registers: [number_of_registers]Value,
condition_registers: [number_of_registers]Condition.Register.CondValue,

pub fn createEmptyName(c: *Core) !*Name {
    const name = try c.local_ctx.name_heap.allocOne();
    name.port = null;
    return name;
}

pub fn createAgent(c: *Core, id: Agent.Id) !*Agent {
    const ag = try c.local_ctx.agent_heap.allocOne();
    ag.id = id;
    ag.ports = @splat(null);
    return ag;
}

pub fn createNumberAgent(c: *Core, num: Types.Special) !*Agent {
    const ag = try createAgent(c, Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?);
    ag.ports[0] = Value{ .special = num };
    return ag;
}

const normalizeEquation = @import("normalize.zig").normalizeEquation;

pub fn pushEquation(c: *Core, eq: EquationUnnormalized) !void {
    if (try normalizeEquation(c, eq)) |normalized| {
        try c.local_ctx.equation_fetcher.push(normalized);
    }
}

pub fn pushUrgent(c: *Core, eq: EquationUnnormalized) !void {
    if (try normalizeEquation(c, eq)) |normalized| {
        try c.local_ctx.equation_fetcher.pushUrgent(normalized);
    }
}

/// Core owns none of these by allocation - the runtime, the heaps and the
/// equation fetcher are all created and destroyed by the VM, which is what
/// lets it hand out per-thread heaps in the multithreaded setup. Core just
/// holds onto what it's given.
pub fn init(
    core_id: u32,
    runtime: *const Runtime,
    core_common: *CoreCommon,
    local_ctx: LocalCtx,
) Self {
    return .{
        .id = core_id,
        .runtime = runtime,
        .core_common = core_common,
        .local_ctx = local_ctx,

        // They are not meant to be used when undefiend by the design of compilation.
        .registers = @splat(undefined),
        .condition_registers = @splat(undefined),
    };
}

pub fn execInstructions(
    c: *Core,
    instrs: []Instruction,
    lagent: *Agent,
    ragent: *Agent,
    wildcarded: bool,
) !void {
    for (instrs) |instruction| {
        switch (instruction.tag) {
            .mk_agent => |id| {
                const ag = try c.local_ctx.agent_heap.allocOne();
                ag.* = .{ .id = id, .ports = @splat(null) };
                c.registers[instruction.operand1] = .{ .agent = ag };
            },
            .mk_special => |special| {
                c.registers[instruction.operand1] = .{ .special = special };
            },
            .put_into_port => |port_idx| {
                c.registers[instruction.operand2].agent.ports[port_idx] = c.registers[instruction.operand1];
            },
            .push => {
                const eq = EquationUnnormalized{
                    .lhs = c.registers[instruction.operand1],
                    .rhs = c.registers[instruction.operand2],
                };
                try c.pushEquation(eq);
            },
            .mk_name => {
                const name = try c.local_ctx.name_heap.allocOne();
                name.* = .{ .port = null };
                c.registers[instruction.operand1] = .{ .name = name };
            },
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
        }
    }
}

pub fn runEquations(c: *Core) !void {
    while (c.local_ctx.equation_fetcher.fetch()) |eq| {
        try Interaction.evalEquation(c, eq);
    }
}

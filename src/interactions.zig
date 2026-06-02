const std = @import("std");
const AST = @import("parser.zig");
const Lexer = @import("lexer.zig");
const Types = @import("types.zig");
const Runtime = @import("runtime.zig");
const Instruction = @import("instruction.zig");
const Builtin = @import("builtin.zig");
const VM = @import("vm.zig");

pub const Config = VM.Config;

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

pub fn name_name(vm: *VM, lname: *Name, rname: *Name) !void {
    // I'm sure this is very unintuitive,
    // but fixing would require some cognitive effort.
    // For some reason name-name logic is very error prone.
    // What even is a "name"? A "wire"? No, because it is one way only.
    // But sometimes it is a wire. And when two wires interact?
    // They create cycles. And what happens after cycles?
    // Everything breaks.
    // 31.05 - 2.06.2026 debbuging session is over

    if (Config.debug_printing.print_interactions) {
        std.debug.print("name - name interaction\n", .{});
    }

    // Also can this be rewritten to be more linear?
    if (lname.port) |lport| {
        if (rname.port) |rport| {
            defer VM.Heap(Name).freeOne(lname);
            defer VM.Heap(Name).freeOne(rname);

            const eq = Equation{
                .lhs = lport,
                .rhs = rport,
            };
            try vm.pushEquation(eq);
        } else {
            rname.port = Value{ .name = lname };
        }
    } else {
        lname.port = Value{ .name = rname };
    }
}

pub fn name_agent(vm: *VM, name: *Name, agent: *Agent) !void {
    if (Config.debug_printing.print_interactions) {
        std.debug.print("{s} - name interaction\n", .{vm.runtime.agent_id_map.findKey(agent.id).?});
    }

    if (name.port) |port| {
        defer VM.Heap(Name).freeOne(name);
        const eq = Equation{
            .lhs = port,
            .rhs = Value{ .agent = agent },
        };
        try vm.pushEquation(eq);
    } else {
        name.port = Value{ .agent = agent };
    }
}

pub fn agent_agent(vm: *VM, lagent: *Agent, ragent: *Agent) !void {
    if (Builtin.isBuiltinAgent(lagent.id)) {
        const handler = Builtin.BuiltinTable.get(lagent.id).?;
        if (handler(vm, lagent, ragent)) {
            return;
        } else |err| {
            if (err != Builtin.BuiltinAgentError.NoRuleSpecified) {
                return err;
            }
        }
    }
    if (Builtin.isBuiltinAgent(ragent.id)) {
        const handler = Builtin.BuiltinTable.get(ragent.id).?;
        if (handler(vm, ragent, lagent)) {
            return;
        } else |err| {
            if (err != Builtin.BuiltinAgentError.NoRuleSpecified) {
                return err;
            }
        }
    }

    defer VM.Heap(Agent).freeOne(lagent);
    defer VM.Heap(Agent).freeOne(ragent);

    // Not builtin
    const rule = vm.runtime.rule_table.get(.{ .lhs = lagent.id, .rhs = ragent.id }) catch |err| {
        if (err == error.UnknownRule) {
            std.debug.print("Unknown rule {s} - {s}\n", .{
                vm.runtime.agent_id_map.findKey(lagent.id).?,
                vm.runtime.agent_id_map.findKey(ragent.id).?,
            });
        }
        return err;
    };
    if (Config.debug_printing.print_interactions) {
        std.debug.print("{s} - {s} interaction\n", .{
            vm.runtime.agent_id_map.findKey(lagent.id).?,
            vm.runtime.agent_id_map.findKey(ragent.id).?,
        });
    }
    if (!rule[1]) {
        // Not swapping
        try VM.execInstructions(vm, rule[0], lagent, ragent);
    } else {
        // Swapping
        try VM.execInstructions(vm, rule[0], ragent, lagent);
    }
}

pub fn evalEquation(vm: *VM, eq: Equation) !void {
    switch (eq.lhs) {
        .name => |lname| {
            switch (eq.rhs) {
                .name => |rname| {
                    try name_name(vm, lname, rname);
                },
                .agent => |ragent| {
                    try name_agent(vm, lname, ragent);
                },
            }
        },
        .agent => |lagent| {
            switch (eq.rhs) {
                .name => |rname| {
                    try name_agent(vm, rname, lagent);
                },
                .agent => |ragent| {
                    try agent_agent(vm, lagent, ragent);
                },
            }
        },
    }
}

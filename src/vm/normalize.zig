const std = @import("std");
const Core = @import("core.zig");

const Types = @import("shared_runtime").Types;
const Name = Types.Name;
const Agent = Types.Agent;
const Equation = Types.Equation;
const EquationUnnormalized = Types.EquationUnnormalized;

const Debug = @import("debug");
const Config = @import("config");

fn name_name(c: *Core, lname: *Name, rname: *Name) !?Equation {
    Debug.log(.print_interactions, "name - name interaction\n", .{});

    const ltraversed = lname.traverseFree(c.name_heap);
    const rtraversed = rname.traverseFree(c.name_heap);
    if (ltraversed.port) |lport| {
        defer c.name_heap.freeOne(ltraversed);
        if (rtraversed.port) |rport| {
            defer c.name_heap.freeOne(rtraversed);
            return Equation{ .lhs = lport.agent, .rhs = rport.agent };
        } else {
            rtraversed.port = lport;
        }
    } else {
        ltraversed.port = .{ .name = rtraversed };
    }
    return null;
}

fn name_agent(c: *Core, name: *Name, agent: *Agent) !?Equation {
    // TODO (KoGora): perf analysis
    if (Config.debug_printing.print_interactions) {
        std.debug.print("{s} - name interaction\n", .{c.runtime.agent_id_map.findKey(agent.id).?});
    }

    const traversed = name.traverseFree(c.name_heap);
    if (traversed.port) |port| {
        defer c.name_heap.freeOne(traversed);
        return Equation{ .lhs = port.agent, .rhs = agent };
    } else {
        traversed.port = .{ .agent = agent };
    }
    return null;
}

pub fn normalizeEquation(c: *Core, eq: EquationUnnormalized) !?Equation {
    switch (eq.lhs) {
        .name => |lname| {
            switch (eq.rhs) {
                .name => |rname| {
                    return try name_name(c, lname, rname);
                },
                .agent => |ragent| {
                    return try name_agent(c, lname, ragent);
                },
                else => unreachable,
            }
        },
        .agent => |lagent| {
            switch (eq.rhs) {
                .name => |rname| {
                    return try name_agent(c, rname, lagent);
                },
                .agent => |ragent| {
                    return Equation{ .lhs = lagent, .rhs = ragent };
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

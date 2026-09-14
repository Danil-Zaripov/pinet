const std = @import("std");

const Runtime = @import("shared_runtime");
const Memory = Runtime.Memory;
const EquationFetcher = Runtime.EquationFetcher;
const Types = Runtime.Types;
const Name = Types.Name;
const Agent = Types.Agent;
const Equation = Types.Equation;
const EquationUnnormalized = Types.EquationUnnormalized;

const Debug = @import("debug");
const Config = @import("config");

fn name_name(name_heap: Memory.Heap(Name), lname: *Name, rname: *Name) !?Equation {
    //Debug.log(.print_interactions, "name - name interaction\n", .{});

    const ltraversed = lname.traverseFree(name_heap);
    const rtraversed = rname.traverseFree(name_heap);
    if (ltraversed.port) |lport| {
        defer name_heap.freeOne(ltraversed);
        if (rtraversed.port) |rport| {
            defer name_heap.freeOne(rtraversed);
            return Equation{ .lhs = lport.agent, .rhs = rport.agent };
        } else {
            rtraversed.port = lport;
        }
    } else {
        ltraversed.port = .{ .name = rtraversed };
    }
    return null;
}

fn name_agent(name_heap: Memory.Heap(Name), name: *Name, agent: *Agent) !?Equation {
    // TODO (KoGora): perf analysis
    if (Config.debug_printing.print_interactions) {
        //std.debug.print("{s} - name interaction\n", .{c.runtime.agent_id_map.findKey(agent.id).?});
    }

    const traversed = name.traverseFree(name_heap);
    if (traversed.port) |port| {
        defer name_heap.freeOne(traversed);
        return Equation{ .lhs = port.agent, .rhs = agent };
    } else {
        traversed.port = .{ .agent = agent };
    }
    return null;
}

pub fn pushEquation(name_heap: Memory.Heap(Name), equation_fetcher: EquationFetcher, eq: EquationUnnormalized) !void {
    if (try normalizeEquation(name_heap, eq)) |normalized| {
        try equation_fetcher.push(normalized);
    }
}

pub fn pushUrgentEquation(name_heap: Memory.Heap(Name), equation_fetcher: EquationFetcher, eq: EquationUnnormalized) !void {
    if (try normalizeEquation(name_heap, eq)) |normalized| {
        try equation_fetcher.pushUrgent(normalized);
    }
}

pub fn normalizeEquation(name_heap: Memory.Heap(Name), eq: EquationUnnormalized) !?Equation {
    switch (eq.lhs) {
        .name => |lname| {
            switch (eq.rhs) {
                .name => |rname| {
                    return try name_name(name_heap, lname, rname);
                },
                .agent => |ragent| {
                    return try name_agent(name_heap, lname, ragent);
                },
                else => unreachable,
            }
        },
        .agent => |lagent| {
            switch (eq.rhs) {
                .name => |rname| {
                    return try name_agent(name_heap, rname, lagent);
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

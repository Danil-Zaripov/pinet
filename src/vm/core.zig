//! Core is a thing that executes interactions.
//!
//! Anything shared between cores is in the
//! Runtime module.
const std = @import("std");

pub const Builtin = @import("builtin.zig");
pub const Interaction = @import("interactions.zig");
pub const Importer = @import("importer.zig");

const AST = @import("ast");
const Lexer = AST.Lexer;
const Runtime = @import("shared_runtime");
const Types = Runtime.Types;
const Memory = Runtime.Memory;

const Compilation = @import("compilation");
const Instruction = Compilation.Instruction;
const Condition = Compilation.Condition;

const Printing = @import("printing");

const Config = @import("config");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Special = Types.Special;
const Equation = Types.Equation;

const Core = @This();
const Self = Core;

const number_of_registers = 100;

// the heaps should be in the runtime!
name_heap: Memory.Heap(Name),
agent_heap: Memory.Heap(Agent),
registers: [number_of_registers]Value,
condition_registers: [number_of_registers]Condition.Register.CondValue,

runtime: *Runtime,

pub fn createAgent(c: *Core, id: Agent.Id) !*Agent {
    const ag = try c.agent_heap.allocOne();
    ag.id = id;
    ag.ports = @splat(null);
    return ag;
}

pub fn createNumberAgent(c: *Core, num: Types.Special) !*Agent {
    const ag = try createAgent(c, Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?);
    ag.ports[0] = Value{ .special = num };
    return ag;
}

pub fn pushEquation(c: *Core, eq: Equation) !void {
    try c.runtime.equation_fetcher.push(eq);
}

pub fn pushUrgent(c: *Core, eq: Equation) !void {
    try c.runtime.equation_fetcher.pushUrgent(eq);
}

fn HeapType(comptime T: type) type {
    switch (Config.heap) {
        .basic => return Memory.BasicHeap(T),
        .objpool => return Memory.ObjPool(T),
    }
}

fn heapInit(comptime T: type, heap_size: usize, gpa: std.mem.Allocator) !Memory.Heap(T) {
    const basic_heap = try gpa.create(HeapType(T));

    basic_heap.* = switch (Config.heap) {
        .basic => try Memory.BasicHeap(T).init(gpa, heap_size),
        .objpool => try Memory.ObjPool(T).init(gpa, heap_size),
    };

    return basic_heap.heap();
}

fn heapDeinit(comptime T: type, heap: Memory.Heap(T), gpa: std.mem.Allocator) void {
    const basic_heap: *HeapType(T) = @ptrCast(@alignCast(heap.ptr));

    switch (Config.heap) {
        .basic => {
            basic_heap.deinit(gpa);
        },
        .objpool => {
            basic_heap.deinit(gpa);
        },
    }

    gpa.destroy(basic_heap);
}

pub fn init(runtime: *Runtime, heap_size: usize) !Self {
    return .{
        .runtime = runtime,
        .agent_heap = try heapInit(Agent, heap_size, runtime.gpa),
        .name_heap = try heapInit(Name, heap_size, runtime.gpa),

        // They are not meant to be used when undefiend by the design of compilation.
        .registers = @splat(undefined),
        .condition_registers = @splat(undefined),
    };
}

pub fn deinit(self: *Self) void {
    heapDeinit(Agent, self.agent_heap, self.runtime.gpa);
    heapDeinit(Name, self.name_heap, self.runtime.gpa);
}

pub fn objToValueNumber(c: *Core, num: AST.Object) !Value {
    const numtype = try Special.parse(num.name);
    const agent_id = Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?;
    var agent = try c.createAgent(agent_id);

    agent.ports[0] = Value{
        .special = numtype,
    };

    return .{ .agent = agent };
}

pub fn objToValueAgent(
    c: *Core,
    obj: AST.Object,
) anyerror!Value {
    const portlist = obj.portlist.?;
    const agent_id = try c.runtime.agent_id_map.get(obj.name);
    const arity = try c.runtime.agent_arities.get(agent_id, portlist.len);
    var agent = try c.agent_heap.allocOne();

    agent.* = .{ .id = agent_id, .ports = @splat(null) };
    {
        var idx: u8 = 0;
        while (idx < arity) : (idx += 1) {
            // Temporary names are needed
            agent.ports[idx] = try objToValue(c, portlist[idx].val);
        }
    }

    return Value{ .agent = agent };
}

pub fn objToValueName(c: *Core, obj: AST.Object) !Value {
    const name = try c.name_heap.allocOne();

    name.* = .{ .port = null };
    try c.runtime.associated_names.put(obj.name, name);

    return .{ .name = name };
}

pub fn objToValue(c: *Core, obj: AST.Object) !Value {
    if (obj.isNumber()) {
        const num = obj.portlist.?[0].val;
        return objToValueNumber(c, num);
    }

    if (obj.portlist) |_| {
        return objToValueAgent(c, obj);
    }

    if (c.runtime.associated_names.getPtr(obj.name)) |maybe_name| {
        if (maybe_name.*) |name| {
            if (name.port) |port| {
                defer c.name_heap.freeOne(name);
                // if the names are interconnected, then
                // we have to free from the cyclic crossreference
                if (port == .name) {
                    if (port.name.port) |other_name| {
                        if (other_name == .name and other_name.name == name) {
                            port.name.port = null;
                        }
                    }
                }
                // free name
                maybe_name.* = null;
                return port;
            } else {
                return .{ .name = name };
            }
        }
    }

    return objToValueName(c, obj);
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
                const ag = try c.agent_heap.allocOne();
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
                const eq = Equation{
                    .lhs = c.registers[instruction.operand1],
                    .rhs = c.registers[instruction.operand2],
                };
                try c.pushEquation(eq);
            },
            .mk_name => {
                const name = try c.name_heap.allocOne();
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
    while (c.runtime.equation_fetcher.fetch()) |eq| {
        try Interaction.evalEquation(c, eq);
    }
}

pub fn runProgram(c: *Core, program: AST.Program) !void {
    for (program.statements) |statement| {
        switch (statement.val) {
            .print_stmt => |name_to_print| {
                if (c.runtime.associated_names.get(name_to_print.val)) |maybe_name| {
                    if (maybe_name) |name| {
                        if (name.port) |port| {
                            try Printing.tryPrint(c.runtime, c.runtime.gpa, port);
                        } else {
                            std.debug.print("<MOVED>\n", .{});
                        }
                    } else {
                        std.debug.print("<EMPTY>\n", .{});
                    }
                } else {
                    std.debug.print("<UNDEFINED>\n", .{});
                }
            },
            .free_stmt => |names| {
                for (names) |wrapped_name| {
                    const name = wrapped_name.val;
                    if (c.runtime.associated_names.get(name)) |maybe_wire| {
                        defer _ = c.runtime.associated_names.remove(name);
                        if (maybe_wire) |wire| {
                            wire.unchain(c.name_heap);
                            if (wire.port) |port| {
                                // of course, there shouldn't be anything other than an agent
                                try Builtin.Eraser.erase(c, port.agent);
                            }
                        }
                    } else {
                        std.debug.print("Trying to free non-existent name {s}\n", .{name});
                    }
                }
            },
            .use_stmt => |import_path| {
                const final_import_path = if (std.fs.path.isAbsolute(import_path)) try c.runtime.gpa.dupe(u8, import_path) else blk: {
                    const dirname = std.fs.path.dirname(c.runtime.main_file.path).?;
                    break :blk try std.fs.path.resolve(c.runtime.gpa, &.{ dirname, import_path });
                };
                defer c.runtime.gpa.free(final_import_path);

                try c.runtime.importer.import(final_import_path, c.runtime);
            },
            .active_pair => |ap| {
                const lhs = try objToValue(c, ap.lhs.val);
                const rhs = try objToValue(c, ap.rhs.val);
                const eq = Equation{ .lhs = lhs, .rhs = rhs };
                try c.pushEquation(eq);

                if (Config.debug_printing.benchmark) {
                    const start = std.Io.Clock.awake.now(c.runtime.io);
                    try runEquations(c);
                    const end = std.Io.Clock.awake.now(c.runtime.io);

                    const duration = start.durationTo(end);
                    std.debug.print("Time passed: {}s\n", .{@as(f64, @floatFromInt(duration.toMilliseconds())) / 1000.0});
                } else {
                    try runEquations(c);
                }

                if (Config.debug_printing.print_memory_usage) {
                    c.agent_heap.printUsage();
                    c.name_heap.printUsage();
                }
            },
            .rule => |rule| {
                const Diagnostic = Compilation.Diagnostic;
                var diag: Diagnostic = .{};
                const compiled_rule = Instruction.compileRule(c.runtime, rule, &diag) catch |err| {
                    if (Diagnostic.isHandledError(err)) {
                        const message =
                            try diag.getPrettyMessage(
                                c.runtime.main_file.contents,
                                c.runtime.main_file.tokens,
                                c.runtime.gpa,
                            );
                        defer c.runtime.gpa.free(message);
                        std.debug.print("{s}", .{message});
                        return error.CompilationError;
                    } else {
                        return err;
                    }
                };
                if (Config.debug_printing.print_compiled_instructions) {
                    try Instruction.debugPrintInstruction(c.runtime, compiled_rule[1]);
                    const guard_size = 40;
                    const guard: [guard_size]u8 = comptime @splat('=');
                    std.debug.print("{s}\n", .{&guard});
                }
                if (compiled_rule[0] == .agents) {
                    try c.runtime.rule_table.map.put(compiled_rule[0].agents, compiled_rule[1]);
                } else {
                    try c.runtime.wildcard_table.put(compiled_rule[0].wildcard, compiled_rule[1]);
                }
            },
            else => {
                unreachable;
            },
        }
    }
}

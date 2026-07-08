//! Virtual machine is a thing that executes interactions.
//!
//! Anything shared between virtual machines is in the
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
const Instruction = @import("compilation").Instruction;
const Printing = @import("printing");

const Config = @import("config");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

const VirtualMachine = @This();
const Self = VirtualMachine;

const number_of_registers = 100;

// the heaps should be in the runtime!
name_heap: Memory.Heap(Name),
agent_heap: Memory.Heap(Agent),
registers: [number_of_registers]Value,

runtime: *Runtime,
gpa: std.mem.Allocator,

pub fn createAgent(vm: *VirtualMachine, id: Agent.Id) !*Agent {
    const ag = try vm.agent_heap.allocOne();
    ag.id = id;
    ag.ports = @splat(null);
    return ag;
}

pub fn createNumberAgent(vm: *VirtualMachine, num: Types.Special) !*Agent {
    const ag = try createAgent(vm, Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?);
    ag.ports[0] = Value{ .special = num };
    return ag;
}

pub fn pushEquation(vm: *VirtualMachine, eq: Equation) !void {
    try vm.runtime.equation_deque.pushBack(vm.runtime.allocator, eq);
}

pub fn pushUrgent(vm: *VirtualMachine, eq: Equation) !void {
    try vm.runtime.urgent_deque.pushBack(vm.runtime.allocator, eq);
}

fn HeapType(comptime T: type) type {
    switch (Config.heap) {
        .basic => return Memory.BasicHeap(T),
    }
}

fn heapInit(comptime T: type, default_heap_size: comptime_int, gpa: std.mem.Allocator) !Memory.Heap(T) {
    const basic_heap = try gpa.create(HeapType(T));

    basic_heap.* = switch (Config.heap) {
        .basic => try Memory.BasicHeap(T).init(gpa, default_heap_size),
    };

    return basic_heap.heap();
}

fn heapDeinit(comptime T: type, heap: Memory.Heap(T), gpa: std.mem.Allocator) void {
    const basic_heap: *HeapType(T) = @ptrCast(@alignCast(heap.ptr));

    switch (Config.heap) {
        .basic => {
            basic_heap.deinit(gpa);
        },
    }

    gpa.destroy(basic_heap);
}

pub fn init(gpa: std.mem.Allocator, runtime: *Runtime) !Self {
    const default_heap_size = 1024;

    return .{
        .runtime = runtime,
        .agent_heap = try heapInit(Agent, default_heap_size, gpa),
        .name_heap = try heapInit(Name, default_heap_size, gpa),
        .registers = @splat(undefined),
        .gpa = gpa,
    };
}

pub fn deinit(self: *Self) void {
    heapDeinit(Agent, self.agent_heap, self.gpa);
    heapDeinit(Name, self.name_heap, self.gpa);
}

pub fn getNumberType(str: []const u8) !Types.Special {
    return if (std.mem.findScalar(u8, str, '.')) |_|
        .{ .float = try std.fmt.parseFloat(f32, str) }
    else
        .{ .integer = try std.fmt.parseInt(i32, str, 10) };
}

pub fn objToValueNumber(vm: *VirtualMachine, num: AST.Object) !Value {
    const numtype = try getNumberType(num.name);
    const agent_id = Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?;
    var agent = try vm.createAgent(agent_id);

    agent.ports[0] = Value{
        .special = numtype,
    };

    return .{ .agent = agent };
}

pub fn objToValueAgent(
    vm: *VirtualMachine,
    obj: AST.Object,
) anyerror!Value {
    const portlist = obj.portlist.?;
    const agent_id = try vm.runtime.agent_id_map.get(obj.name);
    const arity = try vm.runtime.agent_arities.get(agent_id, portlist.len);
    var agent = try vm.agent_heap.allocOne();

    agent.* = .{ .id = agent_id, .ports = @splat(null) };
    {
        var idx: u8 = 0;
        while (idx < arity) : (idx += 1) {
            // Temporary names are needed
            agent.ports[idx] = try objToValue(vm, portlist[idx].val);
        }
    }

    return Value{ .agent = agent };
}

pub fn objToValueName(vm: *VirtualMachine, obj: AST.Object) !Value {
    const name = try vm.name_heap.allocOne();

    name.* = .{ .port = null };
    try vm.runtime.associated_names.put(obj.name, name);

    return .{ .name = name };
}

pub fn objToValue(vm: *VirtualMachine, obj: AST.Object) !Value {
    if (obj.isNumber()) {
        const num = obj.portlist.?[0].val;
        return objToValueNumber(vm, num);
    }

    if (obj.portlist) |_| {
        return objToValueAgent(vm, obj);
    }

    if (vm.runtime.associated_names.getPtr(obj.name)) |maybe_name| {
        if (maybe_name.*) |name| {
            if (name.port) |port| {
                defer vm.name_heap.freeOne(name);
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

    return objToValueName(vm, obj);
}

pub fn execInstructions(
    vm: *VirtualMachine,
    instrs: []Instruction,
    lagent: *Agent,
    ragent: *Agent,
    wildcarded: bool,
) !void {
    for (instrs) |instruction| {
        switch (instruction.tag) {
            .mk_agent => |id| {
                const ag = try vm.agent_heap.allocOne();
                ag.* = .{ .id = id, .ports = @splat(null) };
                vm.registers[instruction.operand1] = .{ .agent = ag };
            },
            .mk_special => |special| {
                vm.registers[instruction.operand1] = .{ .special = special };
            },
            .put_into_port => |port_idx| {
                vm.registers[instruction.operand2].agent.ports[port_idx] = vm.registers[instruction.operand1];
            },
            .push => {
                const eq = Equation{
                    .lhs = vm.registers[instruction.operand1],
                    .rhs = vm.registers[instruction.operand2],
                };
                try vm.runtime.equation_deque.pushBack(vm.runtime.allocator, eq);
            },
            .mk_name => {
                const name = try vm.name_heap.allocOne();
                name.* = .{ .port = null };
                vm.registers[instruction.operand1] = .{ .name = name };
            },
            .load_arguments => {
                const larity = vm.runtime.agent_arities.map.get(lagent.id).?;
                var idx: u16 = 0;
                for (0..larity) |port_idx| {
                    // For some reason just assigning register to a port
                    // directly causes some trouble, need to look into that.
                    //
                    vm.registers[idx] = .{ .name = try vm.name_heap.allocOne() };
                    vm.registers[idx].name.port = lagent.ports[port_idx];
                    idx += 1;
                }
                if (!wildcarded) {
                    const rarity = vm.runtime.agent_arities.map.get(ragent.id).?;
                    for (0..rarity) |port_idx| {
                        vm.registers[idx] = .{ .name = try vm.name_heap.allocOne() };
                        vm.registers[idx].name.port = ragent.ports[port_idx];
                        idx += 1;
                    }
                } else {
                    vm.registers[idx] = .{ .name = try vm.name_heap.allocOne() };
                    vm.registers[idx].name.port = .{ .agent = ragent };
                    idx += 1;
                }
            },
        }
    }
}

pub fn runEquations(vm: *VirtualMachine) !void {
    var maybe_eq: ?Equation = vm.runtime.equation_deque.popFront();
    while (maybe_eq) |eq| {
        try Interaction.evalEquation(vm, eq);

        if (vm.runtime.urgent_deque.popFront()) |urgent_eq| {
            maybe_eq = urgent_eq;
            continue;
        }

        maybe_eq = vm.runtime.equation_deque.popFront();
    }
}

pub fn runProgram(vm: *VirtualMachine, program: AST.Program) !void {
    for (program.statements) |statement| {
        switch (statement.val) {
            .print_stmt => |name_to_print| {
                if (vm.runtime.associated_names.get(name_to_print.val)) |maybe_name| {
                    if (maybe_name) |name| {
                        if (name.port) |port| {
                            try Printing.tryPrint(vm.runtime, vm.gpa, port);
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
                    if (vm.runtime.associated_names.get(name)) |maybe_wire| {
                        defer _ = vm.runtime.associated_names.remove(name);
                        if (maybe_wire) |wire| {
                            wire.unchain(vm.name_heap);
                            if (wire.port) |port| {
                                // of course, there shouldn't be anything other than an agent
                                try Builtin.Eraser.erase(vm, port.agent);
                            }
                        }
                    } else {
                        std.debug.print("Trying to free non-existent name {s}\n", .{name});
                    }
                }
            },
            .use_stmt => |import_path| {
                const final_import_path = if (std.fs.path.isAbsolute(import_path)) try vm.gpa.dupe(u8, import_path) else blk: {
                    const dirname = std.fs.path.dirname(vm.runtime.main_file.path).?;
                    break :blk try std.fs.path.resolve(vm.gpa, &.{ dirname, import_path });
                };
                defer vm.gpa.free(final_import_path);

                try vm.runtime.importer.import(final_import_path, vm.runtime);
            },
            .active_pair => |ap| {
                const lhs = try objToValue(vm, ap.lhs.val);
                const rhs = try objToValue(vm, ap.rhs.val);
                const eq = Equation{ .lhs = lhs, .rhs = rhs };
                try vm.runtime.equation_deque.pushBack(vm.runtime.allocator, eq);

                if (Config.debug_printing.benchmark) {
                    const start = std.Io.Clock.awake.now(vm.runtime.io);
                    try runEquations(vm);
                    const end = std.Io.Clock.awake.now(vm.runtime.io);

                    const duration = start.durationTo(end);
                    std.debug.print("Time passed: {}s\n", .{@as(f64, @floatFromInt(duration.toMilliseconds())) / 1000.0});
                } else {
                    try runEquations(vm);
                }

                if (Config.debug_printing.print_memory_usage) {
                    vm.agent_heap.printUsage();
                    vm.name_heap.printUsage();
                }
            },
            .rule => |rule| {
                var diag = Instruction.CompilationError{};
                const compiled_rule = Instruction.compileRule(vm.runtime, rule, &diag) catch |err| {
                    const HandledError = Instruction.HandledError;
                    switch (err) {
                        HandledError.AgentInArgument, HandledError.UnknownName, HandledError.NameUsedTwice => {
                            const message =
                                try diag.getPrettyMessage(
                                    vm.runtime.main_file.contents,
                                    vm.runtime.main_file.tokens,
                                    vm.gpa,
                                );
                            defer vm.gpa.free(message);
                            std.debug.print("{s}", .{message});
                            return error.CompilationError;
                        },
                        else => return err,
                    }
                };
                if (Config.debug_printing.print_compiled_instructions) {
                    try Instruction.debugPrintInstruction(vm.runtime, compiled_rule[1]);
                    const guard_size = 40;
                    const guard: [guard_size]u8 = comptime @splat('=');
                    std.debug.print("{s}\n", .{&guard});
                }
                if (compiled_rule[0] == .agents) {
                    try vm.runtime.rule_table.map.put(compiled_rule[0].agents, compiled_rule[1]);
                } else {
                    try vm.runtime.wildcard_table.put(compiled_rule[0].wildcard, compiled_rule[1]);
                }
            },
            else => {
                unreachable;
            },
        }
    }
}

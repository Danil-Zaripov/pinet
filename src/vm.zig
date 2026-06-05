const std = @import("std");
const AST = @import("parser.zig");
const Lexer = @import("lexer.zig");
const Types = @import("vm/types.zig");
const Runtime = @import("vm/runtime.zig");
const Instruction = @import("vm/instruction.zig");
const Interaction = @import("vm/interactions.zig");
const Builtin = @import("vm/builtin.zig");
const Printing = @import("vm/printing.zig");
const memory = @import("vm/memory.zig");
pub const Heap = memory.Heap;

pub const Config = @import("config");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

const VirtualMachine = @This();
const Self = VirtualMachine;

const number_of_registers = 100;

name_heap: Heap(Name),
agent_heap: Heap(Agent),
registers: [number_of_registers]Value,

runtime: *Runtime,
gpa: std.mem.Allocator,

pub fn createAgent(vm: *VirtualMachine, id: Agent.Id) !*Agent {
    const ag = try vm.agent_heap.getOne();
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

pub fn init(gpa: std.mem.Allocator, runtime: *Runtime) !Self {
    const default_heap_size = 1024;
    return .{
        .runtime = runtime,
        .agent_heap = try Heap(Agent).init(gpa, default_heap_size),
        .name_heap = try Heap(Name).init(gpa, default_heap_size),
        .registers = @splat(undefined),
        .gpa = gpa,
    };
}

pub fn deinit(self: *Self) void {
    self.name_heap.deinit(self.gpa);
    self.agent_heap.deinit(self.gpa);
}

pub fn getNumberType(str: []const u8) !Types.Special {
    const contains = struct {
        pub fn contains(s: []const u8, selected: u8) bool {
            for (s) |char| {
                if (char == selected) return true;
            }
            return false;
        }
    }.contains;

    if (contains(str, '.')) {
        return Types.Special{ .float = try std.fmt.parseFloat(f32, str) };
    } else {
        return Types.Special{ .integer = try std.fmt.parseInt(i32, str, 10) };
    }
}

pub fn createObject(vm: *VirtualMachine, obj: AST.Object) !Value {
    if (obj.name[0] == '#') {
        // is number
        const num = obj.portlist.?[0].val;
        const numtype = try getNumberType(num.name);
        const agent_id = Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?;
        var agent = try vm.createAgent(agent_id);
        agent.ports[0] = Value{
            .special = numtype,
        };

        return .{ .agent = agent };
    }
    if (obj.portlist) |portlist| {
        const agent_id = try vm.runtime.agent_id_map.get(obj.name);
        const arity = try vm.runtime.agent_arities.get(agent_id, obj.portlist.?.len);
        var agent = try vm.agent_heap.getOne();
        agent.* = .{ .id = agent_id, .ports = @splat(null) };
        {
            var idx: u8 = 0;
            while (idx < arity) : (idx += 1) {
                // Temporary names are needed
                agent.ports[idx] = try createObject(vm, portlist[idx].val);
            }
        }
        return Value{ .agent = agent };
    } else {
        if (vm.runtime.associated_names.getPtr(obj.name)) |maybe_name| {
            if (maybe_name.*) |name| {
                if (name.port) |port| {
                    defer Heap(Name).freeOne(name);
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
        } else {
            const name = try vm.name_heap.getOne();
            name.* = .{ .port = null };
            try vm.runtime.associated_names.put(obj.name, name);
            return Value{ .name = name };
        }
    }
    unreachable;
}

pub fn execInstructions(vm: *VirtualMachine, instrs: []Instruction, lagent: *Agent, ragent: *Agent) !void {
    for (instrs) |instruction| {
        switch (instruction.tag) {
            .MkAgent => |id| {
                const ag = try vm.agent_heap.getOne();
                ag.* = .{ .id = id, .ports = @splat(null) };
                vm.registers[instruction.operand1] = .{ .agent = ag };
            },
            .MkSpecial => |special| {
                vm.registers[instruction.operand1] = .{ .special = special };
            },
            .PutIntoPort => |port_idx| {
                vm.registers[instruction.operand2].agent.ports[port_idx] = vm.registers[instruction.operand1];
            },
            .Push => {
                const eq = Equation{
                    .lhs = vm.registers[instruction.operand1],
                    .rhs = vm.registers[instruction.operand2],
                };
                try vm.runtime.equation_deque.pushBack(vm.runtime.allocator, eq);
            },
            .MkName => {
                const name = try vm.name_heap.getOne();
                name.* = .{ .port = null };
                vm.registers[instruction.operand1] = .{ .name = name };
            },
            .PutArgumentPort => |port| {
                const val = if (port.take_lhs) lagent else ragent;
                vm.registers[instruction.operand1].name.port = val.ports[port.port_idx].?;
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
    var index: usize = 0;
    while (index < program.statements.len) : (index += 1) {
        switch (program.statements[index].val) {
            .print_stmt => |name_to_print| {
                if (vm.runtime.associated_names.get(name_to_print.val)) |maybe_name| {
                    if (maybe_name) |name| {
                        if (name.port) |port| {
                            try Printing.tryPrint(vm, port);
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
                _ = names;
            },
            .active_pair => |ap| {
                const lhs = try createObject(vm, ap.lhs.val);
                const rhs = try createObject(vm, ap.rhs.val);
                const eq = Equation{ .lhs = lhs, .rhs = rhs };
                try vm.runtime.equation_deque.pushBack(vm.runtime.allocator, eq);
                try runEquations(vm);

                if (Config.debug_printing.print_memory_usage) {
                    vm.agent_heap.printUsage();
                    vm.name_heap.printUsage();
                }
            },
            .rule => |rule| {
                const compiled_rule = try Instruction.compileRule(vm.runtime, rule);
                if (Config.debug_printing.print_compiled_instructions) {
                    try Instruction.debugPrintInstruction(vm, compiled_rule[1]);
                    std.debug.print("=========================\n", .{});
                }
                try vm.runtime.rule_table.map.put(compiled_rule[0], compiled_rule[1]);
            },
            else => {
                unreachable;
            },
        }
    }
}

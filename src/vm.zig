const std = @import("std");
const AST = @import("parser.zig");
const Lexer = @import("lexer.zig");
const Types = @import("types.zig");
const Runtime = @import("runtime.zig");
const Instruction = @import("instruction.zig");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

const VirtualMachine = @This();
const Self = VirtualMachine;

const number_of_registers = 100;

name_heap: Heap(Name),
agent_heap: Heap(Agent),
registers: [number_of_registers]?Value,

runtime: *Runtime,
gpa: std.mem.Allocator,

pub fn Heap(T: type) type {
    return struct {
        items: []?T,
        free_idx: usize,
        capacity: usize,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) !Heap(T) {
            return .{
                .items = try gpa.alloc(?T, capacity),
                .capacity = capacity,
                .free_idx = 0,
            };
        }

        pub fn deinit(self: *Heap(T), gpa: std.mem.Allocator) void {
            gpa.free(self.items);
        }

        pub fn getOne(self: *Heap(T)) !*T {
            if (self.free_idx < self.capacity) {
                defer self.free_idx += 1;
                return &self.items[self.free_idx].?;
            } else {
                return error.OutOfMemory;
            }
        }
    };
}

pub fn init(gpa: std.mem.Allocator, runtime: *Runtime) !Self {
    const default_heap_size = 1024;
    return .{
        .runtime = runtime,
        .agent_heap = try Heap(Agent).init(gpa, default_heap_size),
        .name_heap = try Heap(Name).init(gpa, default_heap_size),
        .registers = @splat(null),
        .gpa = gpa,
    };
}

pub fn deinit(self: *Self) void {
    self.name_heap.deinit(self.gpa);
    self.agent_heap.deinit(self.gpa);
}

pub fn getAgentSymbolNested(vm: *const VirtualMachine, ag: *const Agent, stream: *Types.BufferedStringStream) !void {
    const name = vm.runtime.agent_id_map.findKey(ag.id);
    try stream.write("{s}(", .{name.?});
    {
        var idx: usize = 0;
        outer: while (ag.ports[idx]) |port| : (idx += 1) {
            if (idx != 0) {
                try stream.write(", ", .{});
            }
            switch (port) {
                .name => |_wire| {
                    var wire = _wire;
                    var cnt: u32 = 0;
                    while (wire.port) |wired_to| {
                        if (wired_to == .agent) {
                            try getAgentSymbolNested(vm, wired_to.agent, stream);
                            continue :outer;
                        } else {
                            wire = wired_to.name;
                        }
                        cnt = cnt + 1;
                        if (cnt > 20) {
                            break;
                        }
                    }
                    try stream.write("<NAME>", .{});
                },
                .agent => |new_ag| {
                    try getAgentSymbolNested(vm, new_ag, stream);
                },
            }
        }
    }
    try stream.write(")", .{});
}

pub fn getAgentSymbol(vm: *const VirtualMachine, ag: *const Agent) ![]const u8 {
    const name = vm.runtime.agent_id_map.findKey(ag.id);
    const max_agent_name_size = 128;
    var stream = try Types.BufferedStringStream.init(vm.gpa, max_agent_name_size);
    try stream.write("{s}(", .{name.?});
    {
        var idx: usize = 0;
        outer: while (ag.ports[idx]) |port| : (idx += 1) {
            if (idx != 0) {
                try stream.write(", ", .{});
            }
            switch (port) {
                .name => |_wire| {
                    var wire = _wire;
                    var cnt: u32 = 0;
                    while (wire.port) |wired_to| {
                        if (wired_to == .agent) {
                            try getAgentSymbolNested(vm, wired_to.agent, &stream);
                            continue :outer;
                        } else {
                            wire = wired_to.name;
                        }
                        cnt = cnt + 1;
                        if (cnt > 20) {
                            break;
                        }
                    }
                    try stream.write("<NAME>", .{});
                },
                .agent => |new_ag| {
                    try getAgentSymbolNested(vm, new_ag, &stream);
                },
            }
        }
    }
    try stream.write(")", .{});
    return stream.buffer;
}

pub fn tryPrint(vm: *const VirtualMachine, val: Value) !void {
    var cur = val;
    var idx: u32 = 0;
    while (cur == .name) : ({
        cur = cur.name.port.?;
        idx += 1;
    }) {
        if (idx > 10) {
            std.debug.print("{any} is cyclic\n", .{val.name.*});
            return;
        }
    }
    const bytes = try getAgentSymbol(vm, cur.agent);
    defer vm.gpa.free(bytes);
    std.debug.print("{s}\n", .{bytes});
}

pub fn createObject(vm: *VirtualMachine, obj: AST.Object) !Value {
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

pub fn execInstructions(vm: *VirtualMachine, instrs: []Instruction, original_eq: Equation) !void {
    for (instrs) |instruction| {
        switch (instruction.tag) {
            .MkAgent => |id| {
                const ag = try vm.agent_heap.getOne();
                ag.* = .{ .id = id, .ports = @splat(null) };
                vm.registers[instruction.operand1.?] = .{ .agent = ag };
            },
            .PutIntoPort => |port_idx| {
                vm.registers[instruction.operand2.?].?.agent.ports[port_idx] = vm.registers[instruction.operand1.?].?;
            },
            .Push => {
                const eq = Equation{
                    .lhs = vm.registers[instruction.operand1.?].?,
                    .rhs = vm.registers[instruction.operand2.?].?,
                };
                try vm.runtime.equation_deque.pushBack(vm.runtime.allocator, eq);
            },
            .MkName => {
                const name = try vm.name_heap.getOne();
                name.* = .{ .port = null };
                vm.registers[instruction.operand1.?] = .{ .name = name };
            },
            .PutArgumentPort => |port| {
                const val = if (port.take_lhs) original_eq.lhs else original_eq.rhs;
                // const eq = Equation{
                //     .lhs = vm.registers[instruction.operand1.?].?,
                //     .rhs = val.agent.ports[port.port_idx].?,
                // };
                // try vm.runtime.equation_deque.pushBack(vm.runtime.allocator, eq);
                vm.registers[instruction.operand1.?].?.name.port = val.agent.ports[port.port_idx].?;
            },
        }
    }
}

pub fn runEquations(vm: *VirtualMachine) !void {
    while (vm.runtime.equation_deque.popFront()) |eq| {
        try evalEquation(vm, eq);
    }
}

pub fn evalEquation(vm: *VirtualMachine, eq: Equation) !void {
    if (eq.lhs == .name and eq.rhs == .name) {
        if (eq.lhs.name.port) |lport| {
            if (eq.rhs.name.port) |rport| {
                if (lport == .name) {
                    if (lport.name == eq.rhs.name) {
                        return;
                    }
                }
                const new_eq = Equation{
                    .lhs = lport,
                    .rhs = rport,
                };
                try vm.runtime.equation_deque.pushBack(vm.runtime.allocator, new_eq);
            } else {
                unreachable;
            }
        } else {
            if (eq.rhs.name.port) |rport| {
                eq.lhs.name.port = rport;
            } else {
                eq.lhs.name.port = eq.rhs;
                eq.rhs.name.port = eq.lhs;
            }
        }
        return;
    }
    blk: {
        var name: *Name = undefined;
        var agent: *Agent = undefined;
        if (eq.lhs == .name and eq.rhs == .agent) {
            name = eq.lhs.name;
            agent = eq.rhs.agent;
        } else if (eq.rhs == .name and eq.lhs == .agent) {
            name = eq.rhs.name;
            agent = eq.lhs.agent;
        } else {
            break :blk;
        }

        std.debug.print("{s} - name interaction\n", .{vm.runtime.agent_id_map.findKey(agent.id).?});

        if (name.port) |port| {
            const new_eq = Equation{
                .lhs = port,
                .rhs = .{ .agent = agent },
            };
            try vm.runtime.equation_deque.pushBack(vm.runtime.allocator, new_eq);
        } else {
            name.port = Value{ .agent = agent };
        }
        return;
    }
    var a1 = eq.lhs.agent;
    var a2 = eq.rhs.agent;
    const rule_key_maybe = vm.runtime.rule_table.get(.{ .lhs = a1.id, .rhs = a2.id });
    std.debug.print("{s} - {s} interaction\n", .{ vm.runtime.agent_id_map.findKey(a1.id).?, vm.runtime.agent_id_map.findKey(a2.id).? });
    if (rule_key_maybe) |rule_key| {
        if (rule_key[1]) {
            a1 = eq.rhs.agent;
            a2 = eq.lhs.agent;
        }
        try vm.execInstructions(rule_key[0], Equation{ .lhs = .{ .agent = a1 }, .rhs = .{ .agent = a2 } });
    } else |err| {
        switch (err) {
            error.UnknownRule => {
                std.debug.print("{s} - {s}\n", .{ vm.runtime.agent_id_map.findKey(a1.id).?, vm.runtime.agent_id_map.findKey(a2.id).? });
                return error.UnknownRule;
            },
            else => unreachable,
        }
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
                            try tryPrint(vm, port);
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
            },
            .rule => |rule| {
                const compiled_rule = try Instruction.compileRule(vm.runtime, rule);
                try Instruction.debugPrintInstruction(vm, compiled_rule.@"1");
                std.debug.print("=========================\n", .{});
                try vm.runtime.rule_table.map.put(compiled_rule[0], compiled_rule[1]);
            },
            else => {
                unreachable;
            },
        }
    }
}

// // This test is redundant, of course
// test "printing" {
//     var dalloc = std.heap.DebugAllocator(.{}).init;
//     defer dalloc.deinitWithoutLeakChecks();
//     const alloc = dalloc.allocator();
//     const contents = "a;";
//     const tokens = try Lexer.tokenize(alloc, contents);

//     var parser = AST.Parser.init(tokens, alloc);
//     defer parser.deinit();

//     const program = try parser.parseProgram();
//     if (parser.err) |err| {
//         std.debug.print("{s}\n", .{try err.messageLine(alloc, &parser)});
//     }

//     try setupRuntime(alloc);

//     const agent = try vm.agent_heap.getOne();
//     const agent2 = try vm.agent_heap.getOne();
//     const agent3 = try vm.agent_heap.getOne();
//     agent2.* = .{ .id = try agent_id_map.get("SecondWeirdAgent"), .ports = @splat(null) };
//     agent3.* = .{ .id = try agent_id_map.get("ThirdWeirdAgent"), .ports = @splat(null) };
//     agent.* = .{ .id = try agent_id_map.get("WeirdAgentName"), .ports = .{ Value{ .agent = agent2 }, Value{ .agent = agent3 } } ++ @as([8]?Value, @splat(null)) };

//     const name = try vm.name_heap.getOne();
//     name.* = .{ .port = .{ .agent = agent } };

//     try associated_names.put("a", name);
//     defer deinitRuntime();

//     _ = program;
//     // try runProgram(program);
//     // return error.ToyError;
// }

test "vm test" {
    try std.testing.expect(true);
}

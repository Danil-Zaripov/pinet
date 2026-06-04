const std = @import("std");
const AST = @import("parser.zig");
const Lexer = @import("lexer.zig");
const Types = @import("types.zig");
const Runtime = @import("runtime.zig");
const Instruction = @import("instruction.zig");
const Interaction = @import("interactions.zig");
const Builtin = @import("builtin.zig");

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

pub fn Heap(T: type) type {
    return struct {
        const Optional = union(enum) {
            free: void,
            item: T,
        };
        items: []Optional,
        free_idx: usize,
        capacity: usize,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) !Heap(T) {
            const items = try gpa.alloc(Optional, capacity);
            @memset(items, .free);
            return .{
                .items = items,
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
                self.items[self.free_idx] = .{ .item = undefined };
                return &self.items[self.free_idx].item;
            } else {
                return error.OutOfMemory;
            }
        }

        pub fn freeOne(elem: *T) void {
            if (Config.debug_printing.print_frees) {
                std.debug.print("Free is called\n", .{});
            }
            const real_elem = @as(*Optional, @fieldParentPtr("item", elem));
            if (!Config.debug_printing.print_frees) {
                real_elem.* = .free;
            } else {
                switch (real_elem.*) {
                    .free => {
                        std.debug.print("Double-free\n", .{});
                    },
                    .item => {
                        //real_elem.* = .free;
                    },
                }
            }
        }

        pub fn printUsage(self: *const Heap(T)) void {
            var used: usize = 0;
            for (self.items) |maybe_elem| {
                if (maybe_elem == .item) {
                    used += 1;
                }
            }
            const free = self.items.len - used;
            std.debug.print("Heap({s}): {} used, {} free, sizeOf(Optional) = {}, sizeOf(T) = {}\n", .{ @typeName(T), used, free, @sizeOf(Optional), @sizeOf(T) });
        }
    };
}

pub fn createAgent(vm: *VirtualMachine, id: Agent.Id) !*Agent {
    const ag = try vm.agent_heap.getOne();
    ag.id = id;
    ag.ports = @splat(null);
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
                        if (Config.debug_printing.print_interactions) {
                            try stream.write("(n)", .{});
                        }
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
                .special => |special| {
                    switch (special) {
                        .float => |float| {
                            try stream.write("{}", .{float});
                        },
                        .integer => |integer| {
                            try stream.write("{}", .{integer});
                        },
                    }
                },
            }
        }
    }
    try stream.write(")", .{});
}

pub fn getAgentSymbol(vm: *const VirtualMachine, ag: *const Agent) ![]const u8 {
    const name = vm.runtime.agent_id_map.findKey(ag.id);
    const max_agent_name_size = 512;
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
                        if (Config.debug_printing.print_interactions) {
                            try stream.write("(n)", .{});
                        }
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
                .special => |special| {
                    switch (special) {
                        .float => |float| {
                            try stream.write("{}", .{float});
                        },
                        .integer => |integer| {
                            try stream.write("{}", .{integer});
                        },
                    }
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
        if (Config.debug_printing.print_interactions) {
            std.debug.print("(n)", .{});
        }
        if (idx > 10) {
            std.debug.print("{any} is cyclic\n", .{val.name.*});
            return;
        }
    }
    const bytes = try getAgentSymbol(vm, cur.agent);
    defer vm.gpa.free(bytes);
    std.debug.print("{s}\n", .{bytes});
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
        const agent_id = Builtin.BuiltinNameMap.get("#number").?;
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

const std = @import("std");
const AST = @import("parser.zig");
const Lexer = @import("lexer.zig");
const Types = @import("types.zig");
const Runtime = @import("runtime.zig");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

const VirtualMachine = @This();
const Self = VirtualMachine;

name_heap: Heap(Name),
agent_heap: Heap(Agent),
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
        while (ag.ports[idx]) |port| : (idx += 1) {
            if (idx != 0) {
                try stream.write(", ", .{});
            }
            switch (port) {
                .name => {
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

pub fn getAgentSymbol(vm: *const VirtualMachine, ag: *const Agent) ![:0]const u8 {
    const name = vm.runtime.agent_id_map.findKey(ag.id);
    const max_agent_name_size = 128;
    var stream = try Types.BufferedStringStream.init(vm.gpa, max_agent_name_size);
    try stream.write("{s}(", .{name.?});
    // TODO: Use custom object for the job
    {
        var idx: usize = 0;
        while (ag.ports[idx]) |port| : (idx += 1) {
            if (idx != 0) {
                try stream.write(", ", .{});
            }
            switch (port) {
                .name => {
                    try stream.write("<NAME>", .{});
                },
                .agent => |new_ag| {
                    try getAgentSymbolNested(vm, new_ag, &stream);
                },
            }
        }
    }
    return @ptrCast(stream.buffer);
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
        const arity = blk: {
            if (vm.runtime.agent_arities.get(agent_id)) |arity| {
                if (portlist.len != arity) {
                    return error.AgentArityMismatch;
                }
                break :blk arity;
            } else {
                const arity: Agent.Arity = @intCast(portlist.len);
                try vm.runtime.agent_arities.put(agent_id, arity);
                break :blk arity;
            }
        };
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
        if (vm.runtime.associated_names.get(obj.name)) |name| {
            if (name.port) |port| {
                // free name
                return port;
            } else {
                return error.UnassociatedName;
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

pub fn runEquations(vm: *VirtualMachine) !void {
    while (vm.runtime.equation_deque.popFront()) |eq| {
        try evalEquation(vm, eq);
    }
}

pub fn evalEquation(vm: *VirtualMachine, eq: Equation) !void {
    if (eq.lhs == .name and eq.rhs == .name) {
        if (eq.lhs.name.port) |lport| {
            if (eq.rhs.name.port) |rport| {
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
                _ = rport;
                unreachable;
            } else {
                eq.lhs.name.port = eq.rhs;
                eq.rhs.name.port = eq.lhs;
            }
        }
    }
    {
        var name: *Name = undefined;
        var agent: *Agent = undefined;
        if (eq.lhs == .name and eq.rhs == .agent) {
            name = eq.lhs.name;
            agent = eq.rhs.agent;
        } else if (eq.rhs == .name and eq.lhs == .agent) {
            name = eq.rhs.name;
            agent = eq.lhs.agent;
        } else {
            return;
        }

        if (name.port) |port| {
            _ = port;
            // agent - agent communication
        } else {
            name.port = Value{ .agent = agent };
        }
    }
}

pub fn runProgram(vm: *VirtualMachine, program: AST.Program) !void {
    var index: usize = 0;
    while (index < program.statements.len) : (index += 1) {
        switch (program.statements[index].val) {
            .print_stmt => |maybe_name| {
                if (vm.runtime.associated_names.get(maybe_name.val)) |name| {
                    try tryPrint(vm, name.port.?);
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

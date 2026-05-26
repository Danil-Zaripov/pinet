const std = @import("std");
const AST = @import("parser.zig");
const Lexer = @import("lexer.zig");

const number_of_ports = 10;

const Agent = struct {
    id: Agent.Id,
    ports: [number_of_ports]?Value,
    pub const Id = u32;
    pub const Arity = u8;
};

const Name = struct {
    port: ?Value,
};

const Value = union(enum) {
    name: *Name,
    agent: *Agent,
};

const Equation = struct {
    lhs: Value,
    rhs: Value,
};

const IdCountingHashMap = struct {
    map: std.StringHashMap(Agent.Id),
    free_id: Agent.Id = 0,

    pub fn findKey(self: *IdCountingHashMap, val: Agent.Id) ?[]const u8 {
        var iterator = self.map.iterator();
        while (iterator.next()) |kv| {
            if (kv.value_ptr.* == val) {
                return kv.key_ptr.*;
            }
        }
        return null;
    }

    pub fn get(self: *IdCountingHashMap, key: []const u8) !Agent.Id {
        if (self.map.get(key)) |val| {
            return val;
        } else {
            try self.map.put(key, self.free_id);
            defer self.free_id += 1;
            return self.free_id;
        }
    }
};

var agent_id_map: IdCountingHashMap = undefined;
var agent_arities: std.AutoHashMap(Agent.Id, Agent.Arity) = undefined;
var associated_names: std.StringHashMap(*Name) = undefined;
var io: std.Io = undefined;
var threaded: std.Io.Threaded = undefined;

var hashmap_arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;

pub fn Heap(T: type) type {
    return struct {
        items: []T,
        free_idx: usize,
        capacity: usize,

        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) !Heap(T) {
            return .{
                .items = try gpa.alloc(T, capacity),
                .capacity = capacity,
                .free_idx = 0,
                .gpa = gpa,
            };
        }

        pub fn getOne(self: *Heap(T)) !*T {
            if (self.free_idx < self.capacity) {
                defer self.free_idx += 1;
                return &self.items[self.free_idx];
            } else {
                return error.OutOfMemory;
            }
        }
    };
}

const VirtualMachine = struct {
    name_heap: Heap(Name),
    agent_heap: Heap(Agent),
};

var vm: VirtualMachine = undefined;

// Potentially for threaded
var equation_queue: std.Io.Queue(Equation) = undefined;
// for singlethreaded prototype
var equation_deque: std.Deque(Equation) = undefined;

pub fn setupRuntime(gpa: std.mem.Allocator) !void {
    hashmap_arena = std.heap.ArenaAllocator.init(gpa);
    allocator = hashmap_arena.allocator();
    agent_id_map = .{ .map = std.StringHashMap(u32).init(hashmap_arena.allocator()) };
    associated_names = std.StringHashMap(*Name).init(hashmap_arena.allocator());
    vm = .{ .name_heap = try Heap(Name).init(hashmap_arena.allocator(), 100), .agent_heap = try Heap(Agent).init(hashmap_arena.allocator(), 100) };
    equation_queue = std.Io.Queue(Equation).init(&.{});
    equation_deque = try std.Deque(Equation).initCapacity(hashmap_arena.allocator(), 10);
    agent_arities = std.AutoHashMap(Agent.Id, Agent.Arity).init(hashmap_arena.allocator());
    threaded = std.Io.Threaded.init(gpa, .{});
    io = threaded.io();
}

pub fn deinitRuntime() void {
    hashmap_arena.deinit();
}

pub fn printAgent(ag: *const Agent) void {
    const name = agent_id_map.findKey(ag.id);
    std.debug.print("{s}(", .{name.?});
    defer std.debug.print(")", .{});
    {
        var idx: usize = 0;
        while (ag.ports[idx]) |port| : (idx += 1) {
            if (idx != 0) {
                std.debug.print(", ", .{});
            }
            switch (port) {
                .name => std.debug.print("<NAME>", .{}),
                .agent => |new_ag| printAgent(new_ag),
            }
        }
    }
}

pub fn tryPrint(val: Value) !void {
    var cur = val;
    var idx: u32 = 0;
    while (cur == .name) : ({
        cur = cur.name.port.?;
        idx += 1;
    }) {
        if (idx > 10) {
            std.debug.print("{any} is cyclic\n", .{val.name.*});
        }
    }
    printAgent(cur.agent);
    std.debug.print("\n", .{});
}

pub fn createObject(obj: AST.Object) !Value {
    if (obj.portlist) |portlist| {
        const agent_id = try agent_id_map.get(obj.name);
        const arity = blk: {
            if (agent_arities.get(agent_id)) |arity| {
                if (portlist.len != arity) {
                    return error.AgentArityMismatch;
                }
                break :blk arity;
            } else {
                const arity: Agent.Arity = @intCast(portlist.len);
                try agent_arities.put(agent_id, arity);
                break :blk arity;
            }
        };
        var agent = try vm.agent_heap.getOne();
        agent.* = .{ .id = agent_id, .ports = @splat(null) };
        {
            var idx: u8 = 0;
            while (idx < arity) : (idx += 1) {
                // Temporary names are needed
                agent.ports[idx] = try createObject(portlist[idx].val);
            }
        }
        return Value{ .agent = agent };
    } else {
        if (associated_names.get(obj.name)) |name| {
            if (name.port) |port| {
                // free name
                return port;
            } else {
                return error.UnassociatedName;
            }
        } else {
            const name = try vm.name_heap.getOne();
            name.* = .{ .port = null };
            try associated_names.put(obj.name, name);
            return Value{ .name = name };
        }
    }
    unreachable;
}

pub fn runEquations() !void {
    while (equation_deque.popFront()) |eq| {
        try evalEquation(eq);
    }
}

pub fn evalEquation(eq: Equation) !void {
    if (eq.lhs == .name and eq.rhs == .name) {
        if (eq.lhs.name.port) |lport| {
            if (eq.rhs.name.port) |rport| {
                const new_eq = Equation{
                    .lhs = lport,
                    .rhs = rport,
                };
                try equation_deque.pushBack(allocator, new_eq);
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
            try tryPrint(eq.lhs);
            try tryPrint(eq.rhs);
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

pub fn runProgram(program: AST.Program) !void {
    var index: usize = 0;
    while (index < program.statements.len) : (index += 1) {
        switch (program.statements[index].val) {
            .print_stmt => |maybe_name| {
                if (associated_names.get(maybe_name.val)) |name| {
                    try tryPrint(name.port.?);
                } else {
                    std.debug.print("<UNDEFINED>\n", .{});
                }
            },
            .free_stmt => |names| {
                _ = names;
            },
            .active_pair => |ap| {
                const lhs = try createObject(ap.lhs.val);
                const rhs = try createObject(ap.rhs.val);
                const eq = Equation{ .lhs = lhs, .rhs = rhs };
                try equation_deque.pushBack(allocator, eq);
                try runEquations();
            },
            else => {
                unreachable;
            },
        }
    }
}

// This test is redundant, of course
test "printing" {
    var dalloc = std.heap.DebugAllocator(.{}).init;
    defer dalloc.deinitWithoutLeakChecks();
    const alloc = dalloc.allocator();
    const contents = "a;";
    const tokens = try Lexer.tokenize(alloc, contents);

    var parser = AST.Parser.init(tokens, alloc);
    defer parser.deinit();

    const program = try parser.parseProgram();
    if (parser.err) |err| {
        std.debug.print("{s}\n", .{try err.messageLine(alloc, &parser)});
    }

    try setupRuntime(alloc);

    const agent = try vm.agent_heap.getOne();
    const agent2 = try vm.agent_heap.getOne();
    const agent3 = try vm.agent_heap.getOne();
    agent2.* = .{ .id = try agent_id_map.get("SecondWeirdAgent"), .ports = @splat(null) };
    agent3.* = .{ .id = try agent_id_map.get("ThirdWeirdAgent"), .ports = @splat(null) };
    agent.* = .{ .id = try agent_id_map.get("WeirdAgentName"), .ports = .{ Value{ .agent = agent2 }, Value{ .agent = agent3 } } ++ @as([8]?Value, @splat(null)) };

    const name = try vm.name_heap.getOne();
    name.* = .{ .port = .{ .agent = agent } };

    try associated_names.put("a", name);
    defer deinitRuntime();

    _ = program;
    // try runProgram(program);
    // return error.ToyError;
}

test "vm test" {
    try std.testing.expect(true);
}

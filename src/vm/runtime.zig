//! VM.Runtime is a fat struct, a pointer to which is passed
//! around anywhere there is something shared in the vm.
//!
//! Replaces ugly(?) global variables.
const std = @import("std");
const Types = @import("types.zig");
const Instruction = @import("../compilation/instruction.zig");
const Builtin = @import("builtin.zig");
const Importer = @import("importer.zig");
const Token = @import("../lexer.zig").Token;

const Config = @import("../vm.zig").Config;

const Self = @This();

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;
const AgentsKey = Instruction.AgentsKey;
const ConditionedRule = Instruction.ConditionedRule;

pub const File = struct {
    path: []const u8,
    contents: [:0]const u8,
    tokens: []Token,
};

pub const IdCountingHashMap = struct {
    map: std.StringHashMap(Agent.Id),
    free_id: Agent.Id = Builtin.user_agent_id_start,

    pub fn init(allocator: std.mem.Allocator) !IdCountingHashMap {
        // Another solution is just bypassing normal search in hashmap in get function
        var map = std.StringHashMap(Agent.Id).init(allocator);

        for (Builtin.builtin_agents) |builtin_ag| {
            try map.put(builtin_ag.name, Builtin.BuiltinNameMap.get(builtin_ag.name).?);
        }

        return .{
            .map = map,
        };
    }

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
            if (Config.debug_printing.print_compiled_instructions) {
                std.debug.print("Getting {} for key: {s}\n", .{ self.free_id, key });
            }
            try self.map.put(key, self.free_id);
            defer self.free_id += 1;
            return self.free_id;
        }
    }
};

pub const ArityMap = struct {
    map: std.AutoHashMap(Agent.Id, Agent.Arity),

    pub fn get(self: *ArityMap, id: Agent.Id, port_count: usize) !Agent.Arity {
        if (self.map.get(id)) |arity| {
            if (arity != @as(u8, @intCast(port_count))) {
                return error.ArityMismatch;
            }
            return arity;
        } else {
            const arity: u8 = @intCast(port_count);
            try self.map.put(id, arity);
            return arity;
        }
    }

    pub fn init(allocator: std.mem.Allocator) !ArityMap {
        var map = std.AutoHashMap(Agent.Id, Agent.Arity).init(allocator);

        for (Builtin.builtin_agents) |builtin_ag| {
            try map.put(Builtin.BuiltinNameMap.get(builtin_ag.name).?, builtin_ag.arity);
        }

        return .{
            .map = map,
        };
    }
};

pub const RuleSearchResult = struct {
    rules: []ConditionedRule,
    tag: Tag,

    const Tag = enum {
        normal,
        swap,

        /// wildcard_lhs means that lhs is defined and rhs is a wildcard
        wildcard_lhs,
        wildcard_rhs,
    };
};

pub const RuleTable = struct {
    map: std.AutoHashMap(AgentsKey, []ConditionedRule),

    pub fn get(self: *RuleTable, ap: AgentsKey) !RuleSearchResult {
        if (self.map.get(ap)) |rules| {
            return .{ .rules = rules, .tag = .normal };
        } else if (self.map.get(.{ .lhs = ap.rhs, .rhs = ap.lhs })) |rules| {
            return .{ .rules = rules, .tag = .swap };
        } else {
            return error.UnknownRule;
        }
    }
    pub fn init(allocator: std.mem.Allocator) RuleTable {
        return .{
            .map = std.AutoHashMap(AgentsKey, []ConditionedRule).init(allocator),
        };
    }
};

agent_id_map: IdCountingHashMap,
agent_arities: ArityMap,
associated_names: std.StringHashMap(?*Name),
io: std.Io,
threaded: *std.Io.Threaded,
arena: *std.heap.ArenaAllocator,
allocator: std.mem.Allocator,

// Potentially for threaded
equation_queue: std.Io.Queue(Equation),
// for singlethreaded prototype
equation_deque: std.Deque(Equation),

// TODO: proper priority queue?
urgent_deque: std.Deque(Equation),
rule_table: RuleTable,
wildcard_table: std.AutoHashMap(Agent.Id, []ConditionedRule),

/// Importer contains the gpa, provided in .init(...)
importer: Importer,

main_file: File,

pub fn init(gpa: std.mem.Allocator, page: std.mem.Allocator, main_file: File) !Self {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(page);

    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(gpa, .{});

    const allocator = arena.allocator();
    try Builtin.init(allocator);

    return .{
        .arena = arena,
        .allocator = allocator,
        .agent_id_map = try IdCountingHashMap.init(allocator),
        .associated_names = std.StringHashMap(?*Name).init(allocator),
        .equation_queue = std.Io.Queue(Equation).init(&.{}),
        .equation_deque = try std.Deque(Equation).initCapacity(allocator, 10),
        .urgent_deque = try std.Deque(Equation).initCapacity(allocator, 10),
        .agent_arities = try ArityMap.init(allocator),
        .rule_table = RuleTable.init(allocator),
        .wildcard_table = std.AutoHashMap(Agent.Id, []ConditionedRule).init(allocator),
        .threaded = threaded,
        .io = threaded.io(),
        .importer = .init(gpa),
        .main_file = main_file,
    };
}
pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    Builtin.deinit();
    self.threaded.deinit();
    gpa.destroy(self.threaded);
    self.arena.deinit();
    gpa.destroy(self.arena);
    self.importer.deinit();
}

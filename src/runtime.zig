const std = @import("std");
const Types = @import("types.zig");
const Instruction = @import("instruction.zig");
const Builtin = @import("builtin.zig");
// Runtime module
// for anything shared in the vm

const Self = @This();

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;
const RuleKey = Instruction.RuleKey;

pub const IdCountingHashMap = struct {
    map: std.StringHashMap(Agent.Id),
    free_id: Agent.Id = Builtin.UserAgentIdStart,

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

pub const RuleTable = struct {
    map: std.AutoHashMap(RuleKey, []Instruction),

    pub fn get(self: *RuleTable, ap: RuleKey) !struct { []Instruction, bool } {
        if (self.map.get(ap)) |instrs| {
            return .{ instrs, false };
        } else if (self.map.get(.{ .lhs = ap.rhs, .rhs = ap.lhs })) |instrs| {
            return .{ instrs, true };
        } else {
            return error.UnknownRule;
        }
    }
    pub fn init(allocator: std.mem.Allocator) RuleTable {
        return .{
            .map = std.AutoHashMap(RuleKey, []Instruction).init(allocator),
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
rule_table: RuleTable,

pub fn init(gpa: std.mem.Allocator) !Self {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);

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
        .agent_arities = try ArityMap.init(allocator),
        .rule_table = RuleTable.init(allocator),
        .threaded = threaded,
        .io = threaded.io(),
    };
}
pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    Builtin.deinit();
    self.threaded.deinit();
    gpa.destroy(self.threaded);
    self.arena.deinit();
    gpa.destroy(self.arena);
}

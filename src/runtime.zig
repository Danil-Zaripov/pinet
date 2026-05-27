const std = @import("std");
const Types = @import("types.zig");

// Runtime module
// for anything shared in the vm

const Self = @This();

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

pub const IdCountingHashMap = struct {
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

agent_id_map: IdCountingHashMap,
agent_arities: std.AutoHashMap(Agent.Id, Agent.Arity),
associated_names: std.StringHashMap(*Name),
io: std.Io,
threaded: *std.Io.Threaded,
arena: *std.heap.ArenaAllocator,
allocator: std.mem.Allocator,
// Potentially for threaded
equation_queue: std.Io.Queue(Equation) = undefined,
// for singlethreaded prototype
equation_deque: std.Deque(Equation) = undefined,

pub fn init(gpa: std.mem.Allocator) !Self {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);

    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(gpa, .{});

    const allocator = arena.allocator();
    return .{
        .arena = arena,
        .allocator = allocator,
        .agent_id_map = .{ .map = std.StringHashMap(u32).init(allocator) },
        .associated_names = std.StringHashMap(*Name).init(allocator),
        .equation_queue = std.Io.Queue(Equation).init(&.{}),
        .equation_deque = try std.Deque(Equation).initCapacity(allocator, 10),
        .agent_arities = std.AutoHashMap(Agent.Id, Agent.Arity).init(allocator),
        .threaded = threaded,
        .io = threaded.io(),
    };
}
pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.threaded.deinit();
    gpa.destroy(self.threaded);
    self.arena.deinit();
    gpa.destroy(self.arena);
}

//! SharedRuntime is a fat struct, a pointer to which is passed
//! around anywhere there is something shared in the vm.
//!
//! Replaces ugly(?) global variables.
const std = @import("std");

pub const Types = @import("types.zig");
pub const Memory = @import("memory.zig");
pub const EquationFetcher = @import("equation_fetcher.zig");

const Instruction = @import("compilation").Instruction;
const VM = @import("vm");
const Builtin = VM.Builtin;
const Importer = VM.Importer;
pub const DispatchingInstruction = VM.Executioner.DispatchingInstruction;
pub const generateDispatch = VM.Executioner.generateDispatch;
const Token = @import("ast").Lexer.Token;
const Debug = @import("debug");

const Config = @import("config");

const Self = @This();

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
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

    pub fn findKey(self: *const IdCountingHashMap, val: Agent.Id) ?[]const u8 {
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
            Debug.log(.print_compiled_instructions, "Getting {} for key: {s}\n", .{ self.free_id, key });

            try self.map.put(key, self.free_id);
            defer self.free_id += 1;
            return self.free_id;
        }
    }
};

pub const ArityMap = struct {
    map: std.ArrayList(Agent.Arity),
    gpa: std.mem.Allocator,

    /// This function should be called when in init state: rule compilation or active pair initialization.
    /// Direct access only when executing instructions.
    pub fn get(self: *ArityMap, id: Agent.Id, port_count: usize) !Agent.Arity {
        if (self.map.items.len > id) {
            const arity = self.map.items[id];
            if (arity != @as(u8, @intCast(port_count))) {
                return error.ArityMismatch;
            }
            return arity;
        } else {
            const arity: u8 = @intCast(port_count);
            if (self.map.items.len == id) {
                try self.map.append(self.gpa, arity);
                return arity;
            } else {
                unreachable;
            }
        }
    }

    pub fn init(gpa: std.mem.Allocator) !ArityMap {
        var map = try std.ArrayList(Agent.Arity).initCapacity(gpa, Builtin.builtin_agents.len);

        for (Builtin.builtin_agents) |builtin_ag| {
            try map.append(gpa, builtin_ag.arity);
        }

        return .{
            .map = map,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *ArityMap) void {
        self.map.deinit(self.gpa);
    }
};

pub const RuleSearchResult = struct {
    rules: [*]DispatchingInstruction,
    tag: Tag,

    const Tag = enum {
        normal,
        swap,

        /// wildcard_lhs means that lhs is defined and rhs is a wildcard
        wildcard_lhs,
        wildcard_rhs,
    };
};

pub const CodeTable = struct {
    map: std.AutoHashMap(AgentsKey, [*]DispatchingInstruction),

    pub fn get(self: *CodeTable, ap: AgentsKey) !RuleSearchResult {
        if (self.map.get(ap)) |rules| {
            return .{ .rules = rules, .tag = .normal };
        } else if (self.map.get(.{ .lhs = ap.rhs, .rhs = ap.lhs })) |rules| {
            return .{ .rules = rules, .tag = .swap };
        } else {
            return error.UnknownRule;
        }
    }
    pub fn init(allocator: std.mem.Allocator) CodeTable {
        return .{
            .map = std.AutoHashMap(AgentsKey, [*]DispatchingInstruction).init(allocator),
        };
    }
};

agent_id_map: IdCountingHashMap,
agent_arities: ArityMap,
associated_names: std.StringHashMap(?*Name),
io: std.Io,
threaded: *std.Io.Threaded,
_arena: *std.heap.ArenaAllocator,
arena: std.mem.Allocator,
gpa: std.mem.Allocator,

equation_fetcher: EquationFetcher,

rule_table: std.AutoHashMap(AgentsKey, []ConditionedRule),
wildcard_table: std.AutoHashMap(Agent.Id, []ConditionedRule),

code_table: CodeTable,
wildcard_code_table: std.AutoHashMap(Agent.Id, [*]DispatchingInstruction),

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

    const two_deque_equation_fetcher = try gpa.create(EquationFetcher.TwoDequeEquationFetcher);
    two_deque_equation_fetcher.* = .init(gpa);

    return .{
        ._arena = arena,
        .arena = allocator,
        .gpa = gpa,
        .agent_id_map = try IdCountingHashMap.init(allocator),
        .associated_names = std.StringHashMap(?*Name).init(allocator),
        .equation_fetcher = two_deque_equation_fetcher.equationFetcher(),
        .agent_arities = try ArityMap.init(allocator),

        .rule_table = .init(allocator),
        .wildcard_table = .init(allocator),

        .code_table = CodeTable.init(allocator),
        .wildcard_code_table = std.AutoHashMap(Agent.Id, [*]DispatchingInstruction).init(allocator),

        .threaded = threaded,
        .io = threaded.io(),
        .importer = .init(gpa),
        .main_file = main_file,
    };
}

pub fn deinit(self: *Self) void {
    Builtin.deinit();

    self.agent_arities.deinit();

    self.threaded.deinit();
    self.gpa.destroy(self.threaded);

    self._arena.deinit();
    self.gpa.destroy(self._arena);

    self.importer.deinit(self.gpa);

    const two_deque_equation_fetcher: *EquationFetcher.TwoDequeEquationFetcher = @ptrCast(@alignCast(self.equation_fetcher.ptr));
    two_deque_equation_fetcher.deinit();
    self.gpa.destroy(two_deque_equation_fetcher);
}

test {
    _ = .{
        Memory,
        Types,
    };
}

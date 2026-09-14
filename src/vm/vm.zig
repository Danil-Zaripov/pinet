const std = @import("std");

const AST = @import("ast");
const Runtime = @import("shared_runtime");
const Memory = Runtime.Memory;
const EquationFetcher = Runtime.EquationFetcher;
const Types = Runtime.Types;
const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Special = Types.Special;
const EquationUnnormalized = Types.EquationUnnormalized;

const Compilation = @import("compilation");
const Instruction = Compilation.Instruction;
const Diagnostic = Compilation.Diagnostic;

const Printing = @import("printing");

const BuildConfig = @import("config");

pub const Core = @import("core.zig");
pub const CoreCommon = @import("core_common.zig");
pub const Builtin = @import("builtin.zig");
pub const Interaction = @import("interactions.zig");
pub const Importer = @import("importer.zig");
const Normalize = @import("normalize.zig");
pub const normalizeEquation = Normalize.normalizeEquation;

const VM = @This();
const Self = VM;

const getUser = "getUser";

cores: []Core,
core_common: *CoreCommon,
global_ctx: GlobalCtx,
config: Config,
runtime: *Runtime,

pub const Config = struct {
    pub const Error = error{
        NotSupported,
    };

    cores_num: usize,
    heap_size: usize,

    pub fn isValid(cfg: *const Config) Error!void {
        // TODO:(kogora): multithread version
        if (cfg.cores_num != 1) {
            return Error.NotSupported;
        }
    }
};

pub const GlobalCtx = struct {
    agent_heap: Memory.Heap(Agent),
    name_heap: Memory.Heap(Name),
    equation_fetcher: EquationFetcher,

    fn HeapType(comptime T: type) type {
        switch (BuildConfig.heap) {
            .basic => return Memory.BasicHeap(T),
            .objpool => return Memory.ObjPool(T),
        }
    }

    fn heapInit(comptime T: type, heap_size: usize, gpa: std.mem.Allocator) !Memory.Heap(T) {
        const basic_heap = try gpa.create(HeapType(T));

        basic_heap.* = switch (BuildConfig.heap) {
            .basic => try Memory.BasicHeap(T).init(gpa, heap_size),
            .objpool => try Memory.ObjPool(T).init(gpa, heap_size),
        };

        return basic_heap.heap();
    }

    fn heapDeinit(comptime T: type, heap: Memory.Heap(T), gpa: std.mem.Allocator) void {
        const basic_heap: *HeapType(T) = @ptrCast(@alignCast(heap.ptr));

        basic_heap.deinit(gpa);
        gpa.destroy(basic_heap);
    }

    fn equationFetcherInit(gpa: std.mem.Allocator) !EquationFetcher {
        const FetcherType = EquationFetcher.TwoDequeEquationFetcher;
        const two_deque_equation_fetcher = try gpa.create(FetcherType);
        two_deque_equation_fetcher.* = .init(gpa);

        return two_deque_equation_fetcher.equationFetcher();
    }

    fn equationFetcherDeinit(equation_fetcher: EquationFetcher, gpa: std.mem.Allocator) void {
        const FetcherType = EquationFetcher.TwoDequeEquationFetcher;
        const two_deque_equation_fetcher: *FetcherType = @ptrCast(@alignCast(equation_fetcher.ptr));
        two_deque_equation_fetcher.deinit();
        gpa.destroy(two_deque_equation_fetcher);
    }

    fn getHeapUser(comptime T: type, heap: Memory.Heap(T), gpa: std.mem.Allocator) Memory.Heap(T) {
        _ = gpa;
        const Concrete = HeapType(T);
        if (@hasDecl(Concrete, getUser)) {
            const concrete: *Concrete = @ptrCast(@alignCast(heap.ptr));
            return concrete.getUser();
        }
        return heap;
    }

    fn getFetcherUser(fetcher: EquationFetcher, gpa: std.mem.Allocator) EquationFetcher {
        _ = gpa;
        const Concrete = EquationFetcher.TwoDequeEquationFetcher;
        if (@hasDecl(Concrete, getUser)) {
            const concrete: *Concrete = @ptrCast(@alignCast(fetcher.ptr));
            return concrete.getUser();
        }
        return fetcher;
    }

    pub fn init(runtime: *Runtime, config: Config) !GlobalCtx {
        const agent_heap = try heapInit(Agent, config.heap_size, runtime.gpa);
        errdefer heapDeinit(Agent, agent_heap, runtime.gpa);

        const name_heap = try heapInit(Name, config.heap_size, runtime.gpa);
        errdefer heapDeinit(Name, name_heap, runtime.gpa);

        const equation_fetcher = try equationFetcherInit(runtime.gpa);
        errdefer equationFetcherDeinit(equation_fetcher, runtime.gpa);

        return .{
            .agent_heap = agent_heap,
            .name_heap = name_heap,
            .equation_fetcher = equation_fetcher,
        };
    }

    pub fn deinit(self: *GlobalCtx, gpa: std.mem.Allocator) void {
        equationFetcherDeinit(self.equation_fetcher, gpa);
        heapDeinit(Name, self.name_heap, gpa);
        heapDeinit(Agent, self.agent_heap, gpa);
    }

    pub fn createLocal(self: GlobalCtx, gpa: std.mem.Allocator) Core.LocalCtx {
        return .{
            .agent_heap = getHeapUser(Agent, self.agent_heap, gpa),
            .name_heap = getHeapUser(Name, self.name_heap, gpa),
            .equation_fetcher = getFetcherUser(self.equation_fetcher, gpa),
        };
    }

    pub fn destroyLocal(self: *GlobalCtx, local_ctx: Core.LocalCtx, gpa: std.mem.Allocator) void {
        _ = self;
        _ = local_ctx;
        _ = gpa;
    }

    pub fn pushEquation(self: GlobalCtx, eq: EquationUnnormalized) !void {
        try Normalize.pushEquation(self.name_heap, self.equation_fetcher, eq);
    }

    pub fn pushUrgentEquation(self: GlobalCtx, eq: EquationUnnormalized) !void {
        try Normalize.pushUrgentEquation(self.name_heap, self.equation_fetcher, eq);
    }
};

pub fn init(runtime: *Runtime, config: Config) !Self {
    try config.isValid();

    // TODO:(kogora): multithread version
    std.debug.assert(config.cores_num == 1);

    const core_common = try runtime.gpa.create(CoreCommon);
    core_common.* = CoreCommon.init();
    errdefer runtime.gpa.destroy(core_common);

    var global_ctx = try GlobalCtx.init(runtime, config);
    errdefer global_ctx.deinit(runtime.gpa);

    const cores: []Core = try runtime.gpa.alloc(Core, config.cores_num);
    errdefer runtime.gpa.free(cores);

    for (cores, 0..) |*c, core_id| {
        c.* = Core.init(
            @intCast(core_id),
            runtime,
            core_common,
            global_ctx.createLocal(runtime.gpa),
        );
    }

    return .{
        .cores = cores,
        .core_common = core_common,
        .global_ctx = global_ctx,
        .runtime = runtime,
        .config = config,
    };
}

pub fn deinit(self: *Self) void {
    for (self.cores) |*c| self.global_ctx.destroyLocal(c.local_ctx, self.runtime.gpa);
    self.runtime.gpa.free(self.cores);
    self.global_ctx.deinit(self.runtime.gpa);
    self.runtime.gpa.destroy(self.core_common);
}

fn objToValueNumber(agent_heap: Memory.Heap(Agent), num: AST.Object) !Value {
    const numtype = try Special.parse(num.name);
    const agent_id = Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?;
    const agent = try agent_heap.allocOne();

    agent.* = .{ .id = agent_id, .ports = @splat(null) };
    agent.ports[0] = Value{ .special = numtype };

    return .{ .agent = agent };
}

fn objToValueAgent(
    runtime: *Runtime,
    agent_heap: Memory.Heap(Agent),
    name_heap: Memory.Heap(Name),
    obj: AST.Object,
) anyerror!Value {
    const portlist = obj.portlist.?;
    const agent_id = try runtime.agent_id_map.get(obj.name);
    const arity = try runtime.agent_arities.get(agent_id, portlist.len);
    const agent = try agent_heap.allocOne();

    agent.* = .{ .id = agent_id, .ports = @splat(null) };
    {
        var idx: u8 = 0;
        while (idx < arity) : (idx += 1) {
            // Temporary names are needed
            agent.ports[idx] = try objToValue(runtime, agent_heap, name_heap, portlist[idx].val);
        }
    }

    return Value{ .agent = agent };
}

fn objToValueName(runtime: *Runtime, name_heap: Memory.Heap(Name), obj: AST.Object) !Value {
    const name = try name_heap.allocOne();

    name.* = .{ .port = null };
    try runtime.associated_names.put(obj.name, name);

    return .{ .name = name };
}

fn objToValue(
    runtime: *Runtime,
    agent_heap: Memory.Heap(Agent),
    name_heap: Memory.Heap(Name),
    obj: AST.Object,
) anyerror!Value {
    if (obj.isNumber()) {
        const num = obj.portlist.?[0].val;
        return objToValueNumber(agent_heap, num);
    }

    if (obj.portlist != null) {
        return objToValueAgent(runtime, agent_heap, name_heap, obj);
    }

    if (runtime.associated_names.getPtr(obj.name)) |maybe_name| {
        if (maybe_name.*) |name| {
            maybe_name.* = null;
            if (name.port) |port| {
                defer name_heap.freeOne(name);

                return port;
            } else {
                return .{ .name = name };
            }
        } else {
            // Implicitly reusing
        }
    }

    return objToValueName(runtime, name_heap, obj);
}

inline fn printStmt(self: *Self, name_to_print: AST.Name) !void {
    if (self.runtime.associated_names.get(name_to_print.val)) |maybe_name| {
        if (maybe_name) |name| {
            if (name.port) |port| {
                try Printing.tryPrint(self.runtime, self.runtime.gpa, port);
            } else {
                std.debug.print("<MOVED>\n", .{});
            }
        } else {
            std.debug.print("<EMPTY>\n", .{});
        }
    } else {
        std.debug.print("<UNDEFINED>\n", .{});
    }
}

inline fn freeStmt(self: *Self, names: []const AST.Name) !void {
    for (names) |wrapped_name| {
        const name = wrapped_name.val;
        if (self.runtime.associated_names.get(name)) |maybe_wire| {
            defer _ = self.runtime.associated_names.remove(name);
            if (maybe_wire) |wire| {
                const traversed = wire.traverseFree(self.global_ctx.name_heap);
                defer self.global_ctx.name_heap.freeOne(traversed);
                if (traversed.port) |port| {
                    // of course, there shouldn't be anything other than an agent
                    try Builtin.Eraser.erase(&self.cores[0], port.agent);
                }
            }
        } else {
            std.debug.print("Trying to free non-existent name {s}\n", .{name});
        }
    }
}

inline fn useStmt(self: *Self, import_path: []const u8) !void {
    const final_import_path = if (std.fs.path.isAbsolute(import_path)) try self.runtime.gpa.dupe(u8, import_path) else blk: {
        const dirname = std.fs.path.dirname(self.runtime.main_file.path).?;
        break :blk try std.fs.path.resolve(self.runtime.gpa, &.{ dirname, import_path });
    };
    defer self.runtime.gpa.free(final_import_path);

    try self.runtime.importer.import(final_import_path, self.runtime);
}

inline fn ruleStmt(self: *Self, rule: AST.Rule) !void {
    var diag: Diagnostic = .{};
    const compiled_rule = Instruction.compileRule(self.runtime, rule, &diag) catch |err| {
        if (Diagnostic.isHandledError(err)) {
            const message =
                try diag.getPrettyMessage(
                    self.runtime.main_file.contents,
                    self.runtime.main_file.tokens,
                    self.runtime.gpa,
                );
            defer self.runtime.gpa.free(message);
            std.debug.print("{s}", .{message});
            return error.CompilationError;
        } else {
            return err;
        }
    };
    if (BuildConfig.debug_printing.print_compiled_instructions) {
        try Instruction.debugPrintInstruction(self.runtime, compiled_rule[1]);
        const guard_size = 40;
        const guard: [guard_size]u8 = comptime @splat('=');
        std.debug.print("{s}\n", .{&guard});
    }
    if (compiled_rule[0] == .agents) {
        try self.runtime.rule_table.map.put(compiled_rule[0].agents, compiled_rule[1]);
    } else {
        try self.runtime.wildcard_table.put(compiled_rule[0].wildcard, compiled_rule[1]);
    }
}

inline fn prepareActivePair(self: *Self, ap: AST.ActivePair) !void {
    const lhs = try objToValue(self.runtime, self.global_ctx.agent_heap, self.global_ctx.name_heap, ap.lhs.val);
    const rhs = try objToValue(self.runtime, self.global_ctx.agent_heap, self.global_ctx.name_heap, ap.rhs.val);
    const eq = EquationUnnormalized{ .lhs = lhs, .rhs = rhs };

    try self.global_ctx.pushEquation(eq);
}

// TODO:(kogora): multithread version
inline fn executeActivePair(self: *Self) !void {
    if (BuildConfig.debug_printing.benchmark) {
        const start = std.Io.Clock.awake.now(self.runtime.io);
        try self.cores[0].runEquations();
        const end = std.Io.Clock.awake.now(self.runtime.io);

        const duration = start.durationTo(end);
        std.debug.print("Time passed: {}s\n", .{@as(f64, @floatFromInt(duration.toMilliseconds())) / 1000.0});
    } else {
        try self.cores[0].runEquations();
    }

    if (BuildConfig.debug_printing.print_memory_usage) {
        self.global_ctx.agent_heap.printUsage();
        self.global_ctx.name_heap.printUsage();
    }
}

pub fn runProgram(self: *Self, program: AST.Program) !void {
    for (program.statements) |statement| {
        switch (statement.val) {
            .print_stmt => |name_to_print| try self.printStmt(name_to_print),
            .free_stmt => |names| try self.freeStmt(names),
            .use_stmt => |import_path| try self.useStmt(import_path),
            .active_pair => |ap| {
                try self.prepareActivePair(ap);
                try self.executeActivePair();
            },
            .rule => |rule| try self.ruleStmt(rule),
            else => {
                unreachable;
            },
        }
    }
}

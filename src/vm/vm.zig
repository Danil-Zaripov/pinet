const std = @import("std");

const AST = @import("ast");
const Runtime = @import("shared_runtime");

pub const Core = @import("core.zig");
pub const Builtin = @import("builtin.zig");
pub const Interaction = @import("interactions.zig");
pub const Importer = @import("importer.zig");

const VM = @This();
const Self = VM;

cores: []Core,
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

pub fn init(runtime: *Runtime, config: Config) !Self {
    try config.isValid();

    const core: []Core = try runtime.gpa.alloc(Core, config.cores_num);

    // TODO:(kogora): multithread version
    std.debug.assert(core.len == 1);

    core[0] = try Core.init(runtime, config.heap_size);

    return .{ .cores = core, .runtime = runtime, .config = config };
}

pub fn deinit(self: *Self) void {
    self.cores[0].deinit();
    self.runtime.gpa.free(self.cores);
}

pub fn runProgram(self: *Self, program: AST.Program) !void {
    try self.cores[0].runProgram(program);
}

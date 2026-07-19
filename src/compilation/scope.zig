//! A struct that has the information, that we possess at each point of compilation.
const std = @import("std");

const AST = @import("ast");
const TokenSlice = AST.TokenSlice;

const Diagnostic = @import("compilation.zig").Diagnostic;

const Scope = @This();

pub const RegisterId = u8;

pub const NameInfo = struct {
    location: RegisterId,
    is_on_port: bool = false,
    used: bool = false,
    token_slice: TokenSlice,
};

map: std.StringHashMap(NameInfo),
free_idx: RegisterId,

pub fn getFree(self: *Scope) RegisterId {
    defer self.free_idx += 1;
    return self.free_idx;
}

pub fn associate(self: *Scope, name: []const u8, tslice: TokenSlice) !*NameInfo {
    if (self.map.get(name)) |_| {
        return error.ValueExists;
    } else {
        const val = self.getFree();
        const info = NameInfo{ .location = val, .token_slice = tslice };
        const result = try self.map.getOrPutValue(name, info);
        return result.value_ptr;
    }
}

pub fn init(gpa: std.mem.Allocator) Scope {
    return .{
        .free_idx = 0,
        .map = std.StringHashMap(NameInfo).init(gpa),
    };
}

const HandledError = Diagnostic.HandledError;

pub fn checkNameUsage(self: *Scope, diag: *Diagnostic) HandledError!void {
    var iter = self.map.valueIterator();
    while (iter.next()) |val| {
        if (!val.used) {
            diag.* = .{ .tag = .{ .name_used_once = val.token_slice } };
            return HandledError.NameUsedOnce;
        }
    }
}

pub fn deinit(self: *Scope) void {
    self.map.deinit();
}

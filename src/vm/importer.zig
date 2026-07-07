//! Struct that handles importing logic through "use" statements.
const std = @import("std");

const Runtime = @import("runtime.zig");
const Lexer = @import("../lexer.zig");
const Parser = @import("../parser.zig");
const Instruction = @import("../compilation/instruction.zig");
const Config = @import("../vm.zig").Config;

const Self = @This();
const Importer = Self;

imported: std.StringHashMap([:0]const u8),
gpa: std.mem.Allocator,

pub const Error = error{
    ImportedExtensionNotIn,
};

pub fn import(self: *Self, path: []const u8, runtime: *Runtime) !void {
    const resolved_path = try std.fs.path.resolve(self.gpa, &.{path});
    // shouldn't use "path" ever again
    defer self.gpa.free(resolved_path);

    if (!std.mem.eql(u8, std.fs.path.extension(resolved_path), ".in")) {
        return Error.ImportedExtensionNotIn;
    }

    if (self.imported.contains(resolved_path)) {
        self.gpa.free(resolved_path);
        return;
    }

    const contents = try std.Io.Dir.readFileAllocOptions(
        std.Io.Dir.cwd(),
        runtime.io,
        resolved_path,
        self.gpa,
        .unlimited,
        .of(u8),
        0,
    );
    try self.imported.put(resolved_path, contents);

    const tokens = try Lexer.tokenize(self.gpa, contents);
    defer self.gpa.free(tokens);
    const file = Runtime.File{
        .contents = contents,
        .path = resolved_path,
        .tokens = tokens,
    };

    var parser = try Parser.init(tokens, self.gpa, self.gpa);
    defer parser.deinit(self.gpa);

    const program = parser.parseProgram() catch |err| {
        if (err == Parser.Error.ErrorDuringParsing) {
            const message = try parser.err.?.messageLine(&parser);
            std.debug.print("{s}", .{message});
            return;
        }
        return err;
    };
    for (program.statements) |statement| {
        switch (statement.val) {
            .rule => |rule| {
                var diag = Instruction.CompilationError{};
                const compiled_rule = Instruction.compileRule(runtime, rule, &diag) catch |err| {
                    const HandledError = Instruction.HandledError;
                    switch (err) {
                        HandledError.AgentInArgument, HandledError.UnknownName, HandledError.NameUsedTwice => {
                            const message =
                                try diag.getPrettyMessage(
                                    file.contents,
                                    file.tokens,
                                    self.gpa,
                                );
                            defer self.gpa.free(message);
                            std.debug.print("Imported file {s}\n{s}", .{ file.path, message });
                            return error.CompilationError;
                        },
                        else => return err,
                    }
                };
                if (Config.debug_printing.print_compiled_instructions) {
                    try Instruction.debugPrintInstruction(runtime, compiled_rule[1]);
                    const guard_size = 40;
                    const guard: [guard_size]u8 = comptime @splat('=');
                    std.debug.print("{s}\n", .{&guard});
                }
                if (compiled_rule[0] == .agents) {
                    try runtime.rule_table.map.put(compiled_rule[0].agents, compiled_rule[1]);
                } else {
                    try runtime.wildcard_table.put(compiled_rule[0].wildcard, compiled_rule[1]);
                }
            },
            .use_stmt => |import_path| {
                const final_import_path = if (std.fs.path.isAbsolute(import_path)) try self.gpa.dupe(u8, import_path) else blk: {
                    const dirname = std.fs.path.dirname(resolved_path).?;
                    break :blk try std.fs.path.resolve(self.gpa, &.{ dirname, import_path });
                };
                defer self.gpa.free(final_import_path);

                try import(self, final_import_path, runtime);
            },
            else => {
                std.debug.print("Found non-rule statement when importing {s}. It will not be executed.", .{resolved_path});
            },
        }
    }
}

pub fn init(gpa: std.mem.Allocator) Importer {
    return .{
        .gpa = gpa,
        .imported = .init(gpa),
    };
}

pub fn deinit(self: *Self) void {
    var iter = self.imported.valueIterator();
    while (iter.next()) |contents| {
        self.gpa.free(contents.*);
    }
    self.imported.deinit();
}

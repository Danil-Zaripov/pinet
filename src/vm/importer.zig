//! Struct that handles importing logic through "use" statements.
const std = @import("std");

const Runtime = @import("shared_runtime");
const AST = @import("ast");
const Lexer = AST.Lexer;
const Parser = AST.Parser;

const Compilation = @import("compilation");
const Instruction = Compilation.Instruction;

const Config = @import("config");

const Self = @This();
const Importer = Self;

imported: std.StringHashMap([:0]const u8),

pub const Error = error{
    ImportedExtensionNotIn,
};

pub fn import(self: *Self, path: []const u8, runtime: *Runtime) !void {
    const gpa = runtime.gpa;
    const resolved_path = try std.fs.path.resolve(gpa, &.{path});
    // shouldn't use "path" ever again
    defer gpa.free(resolved_path);

    if (!std.mem.eql(u8, std.fs.path.extension(resolved_path), ".in")) {
        return Error.ImportedExtensionNotIn;
    }

    if (self.imported.contains(resolved_path)) {
        gpa.free(resolved_path);
        return;
    }

    const contents = try std.Io.Dir.readFileAllocOptions(
        std.Io.Dir.cwd(),
        runtime.io,
        resolved_path,
        gpa,
        .unlimited,
        .of(u8),
        0,
    );
    try self.imported.put(resolved_path, contents);

    const tokens = try Lexer.tokenize(gpa, contents);
    defer gpa.free(tokens);
    const file = Runtime.File{
        .contents = contents,
        .path = resolved_path,
        .tokens = tokens,
    };

    var parser = try Parser.init(tokens, gpa, gpa);
    defer parser.deinit(gpa);

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
                const Diagnostic = Compilation.Diagnostic;
                var diag: Diagnostic = .{};
                Instruction.compileRule(runtime, rule, &diag) catch |err| {
                    if (Diagnostic.isHandledError(err)) {
                        const message =
                            try diag.getPrettyMessage(
                                file.contents,
                                file.tokens,
                                gpa,
                            );
                        defer gpa.free(message);
                        std.debug.print("Imported file {s}\n{s}", .{ file.path, message });
                        return error.CompilationError;
                    } else {
                        return err;
                    }
                };
            },
            .use_stmt => |import_path| {
                const final_import_path = if (std.fs.path.isAbsolute(import_path)) try gpa.dupe(u8, import_path) else blk: {
                    const dirname = std.fs.path.dirname(resolved_path).?;
                    break :blk try std.fs.path.resolve(gpa, &.{ dirname, import_path });
                };
                defer gpa.free(final_import_path);

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
        .imported = .init(gpa),
    };
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    var iter = self.imported.valueIterator();
    while (iter.next()) |contents| {
        gpa.free(contents.*);
    }
    self.imported.deinit();
}

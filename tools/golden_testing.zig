const std = @import("std");

const assert = std.debug.assert;

const stdout_tests_path = "./tests";
const stderr_tests_path = "./tests_errors";

/// Copied from pinet.
pub const Lines = struct {
    lines: [][]const u8,
    gpa: std.mem.Allocator,

    /// 4 on line index, 2 on additional characters
    pub const enumeration_padding = 6;

    pub fn init(gpa: std.mem.Allocator, contents: [:0]const u8) !Lines {
        var list = std.ArrayList([]const u8).empty;
        var st: usize = 0;
        var idx: usize = 0;
        while (true) : (idx += 1) {
            const c = contents[idx];
            if (c == '\n' or c == 0) {
                try list.append(gpa, contents[st..idx]);
                st = idx + 1;
                if (c == 0) break;
            }
        }
        return .{
            .lines = try list.toOwnedSlice(gpa),
            .gpa = gpa,
        };
    }

    /// Caller owns the string.
    pub fn getEnumerated(self: *const Lines, arena: std.mem.Allocator, idx: usize) ![]const u8 {
        // self.enumeration_padding = 4 + "| ".len
        return std.fmt.allocPrint(arena, "{: >4}| {s}", .{ idx + 1, self.lines[idx] });
    }

    pub fn deinit(self: *Lines) void {
        self.gpa.free(self.lines);
    }

    test "single line" {
        const gpa = std.testing.allocator;
        const file = "hello world";

        var lines = try Lines.init(gpa, file);
        defer lines.deinit();

        try std.testing.expectEqualStrings("hello world", lines.lines[0]);
    }

    test "multiple lines" {
        const gpa = std.testing.allocator;
        const file = "hello\nworld\n";

        var lines = try Lines.init(gpa, file);
        defer lines.deinit();

        try std.testing.expectEqualStrings("hello", lines.lines[0]);
        try std.testing.expectEqualStrings("world", lines.lines[1]);
        try std.testing.expectEqualStrings("", lines.lines[2]);
    }
};

/// Gets command name and its arguments as an array and
/// tries to launch. The caller owns the memory.
pub fn invokeAndCollectStdout(command: []const []const u8, gpa: std.mem.Allocator, io: std.Io) ![:0]u8 {
    assert(command.len > 1);
    const result = std.process.run(gpa, io, .{
        .argv = command,
    }) catch return error.RunningFailed;

    gpa.free(result.stderr);
    return ret: {
        const duped = gpa.dupeSentinel(u8, result.stdout, 0);
        gpa.free(result.stdout);
        break :ret duped;
    };
}

pub fn invokeAndCollectStderr(command: []const []const u8, gpa: std.mem.Allocator, io: std.Io) ![:0]u8 {
    assert(command.len > 1);
    const result = std.process.run(gpa, io, .{
        .argv = command,
    }) catch return error.RunningFailed;

    gpa.free(result.stdout);
    return ret: {
        const duped = try gpa.dupeSentinel(u8, result.stderr, 0);
        gpa.free(result.stderr);
        break :ret duped;
    };
}

const Mode = enum {
    Generate,
    Compare,
};

const WhatAreWeGetting = enum {
    stderr,
    stdout,
};

const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    program_path: []const u8,
    mode: Mode,
};

/// Null means eof.
const LineDiff = struct {
    number: usize,
    expected: ?[]const u8,
    actual: ?[]const u8,
};

const eof_marker = "<EOF>";

const ComparisonResult = union(enum) {
    file_does_not_exist,
    correct,
    /// The lines are duped. The caller owns the memory.
    line_diff: LineDiff,

    pub fn deinit(self: *ComparisonResult, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .correct, .file_does_not_exist => {},
            .line_diff => |line_diff| {
                if (line_diff.actual) |actual| {
                    gpa.free(actual);
                }
                if (line_diff.expected) |expected| {
                    gpa.free(expected);
                }
            },
        }
    }
};

const Query = struct {
    filepath: []const u8,
    goldenpath: []const u8,
    what_are_we_getting: WhatAreWeGetting,
};

fn compare(ctx: Context, query: Query) !ComparisonResult {
    const cwd = std.Io.Dir.cwd();
    const golden = cwd.readFileAllocOptions(ctx.io, query.goldenpath, ctx.gpa, .unlimited, .@"1", 0) catch |err| {
        if (err == error.FileNotFound) {
            return ComparisonResult.file_does_not_exist;
        } else {
            return err;
        }
    };
    defer ctx.gpa.free(golden);

    const output = try switch (query.what_are_we_getting) {
        .stdout => invokeAndCollectStdout(&.{ ctx.program_path, "-f", query.filepath }, ctx.gpa, ctx.io),
        .stderr => invokeAndCollectStderr(&.{ ctx.program_path, "-f", query.filepath, "--no-handled-error-trace" }, ctx.gpa, ctx.io),
    };
    defer ctx.gpa.free(output);

    var golden_lines = try Lines.init(ctx.gpa, golden);
    defer golden_lines.deinit();
    var output_lines = try Lines.init(ctx.gpa, output);
    defer output_lines.deinit();

    for (0..@min(golden_lines.lines.len, output_lines.lines.len)) |idx| {
        if (!std.mem.eql(u8, output_lines.lines[idx], golden_lines.lines[idx])) {
            return ComparisonResult{
                .line_diff = .{
                    .number = idx,
                    .actual = try ctx.gpa.dupe(u8, output_lines.lines[idx]),
                    .expected = try ctx.gpa.dupe(u8, golden_lines.lines[idx]),
                },
            };
        }
    }

    if (golden_lines.lines.len < output_lines.lines.len) {
        return ComparisonResult{
            .line_diff = .{
                .number = golden_lines.lines.len,
                .actual = try ctx.gpa.dupe(u8, output_lines.lines[golden_lines.lines.len]),
                .expected = null,
            },
        };
    } else if (output_lines.lines.len < golden_lines.lines.len) {
        return ComparisonResult{
            .line_diff = .{
                .number = output_lines.lines.len,
                .actual = null,
                .expected = try ctx.gpa.dupe(u8, golden_lines.lines[output_lines.lines.len]),
            },
        };
    } else {
        return ComparisonResult.correct;
    }
}

const GenerateResult = enum {
    created,
    updated,
    unchanged,

    pub fn symbol(self: GenerateResult) []const u8 {
        return @tagName(self);
    }
};

pub fn generate(ctx: Context, query: Query) !GenerateResult {
    const cwd = std.Io.Dir.cwd();

    var compare_result = try compare(ctx, query);
    defer compare_result.deinit(ctx.gpa);
    const result: GenerateResult = switch (compare_result) {
        .correct => .unchanged,
        .file_does_not_exist => .created,
        .line_diff => .updated,
    };
    if (result != .unchanged) {
        const output = try switch (query.what_are_we_getting) {
            .stdout => invokeAndCollectStdout(&.{ ctx.program_path, "-f", query.filepath }, ctx.gpa, ctx.io),
            .stderr => invokeAndCollectStderr(&.{ ctx.program_path, "-f", query.filepath, "--no-handled-error-trace" }, ctx.gpa, ctx.io),
        };
        defer ctx.gpa.free(output);

        try cwd.writeFile(ctx.io, .{
            .data = std.mem.span(output.ptr),
            .sub_path = query.goldenpath,
            .flags = .{},
        });
    }

    return result;
}

const ComparisonSummary = struct {
    failed: u32 = 0,
    succeeded: u32 = 0,
};

const GeneratedSummary = struct {
    created: u32 = 0,
    updated: u32 = 0,
    unchanged: u32 = 0,
};

const Summary = union(enum) {
    generated: GeneratedSummary,
    comparison: ComparisonSummary,

    pub fn getText(self: Summary, gpa: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .generated => |generated| try std.fmt.allocPrint(
                gpa,
                "CREATED: {}; UPDATED: {}; UNCHANGED: {}; TOTAL: {};\n",
                .{
                    generated.created,
                    generated.updated,
                    generated.unchanged,
                    generated.created + generated.updated + generated.unchanged,
                },
            ),
            .comparison => |comparison| try std.fmt.allocPrint(
                gpa,
                "SUCCESS: {}; FAILED: {}; TOTAL: {};\n",
                .{
                    comparison.succeeded,
                    comparison.failed,
                    comparison.succeeded + comparison.failed,
                },
            ),
        };
    }
};

pub fn processDirectory(ctx: Context, path_to_dir: []const u8, what_are_we_getting: WhatAreWeGetting) !Summary {
    var _arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer _arena.deinit();
    const arena = _arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const path_to_dir_resolved = try std.fs.path.resolve(ctx.gpa, &.{path_to_dir});
    defer ctx.gpa.free(path_to_dir_resolved);
    const dir = try cwd.openDir(ctx.io, path_to_dir_resolved, .{ .access_sub_paths = false, .iterate = true });
    defer dir.close(ctx.io);

    const golden_dir_path = try std.fs.path.resolve(arena, &.{ path_to_dir_resolved, "golden" });

    const golden_dir = dir.openDir(ctx.io, "golden", .{}) catch |err| err_blk: {
        if (err == error.FileNotFound) {
            std.debug.print("{s} directory not found. Trying to create.\n", .{golden_dir_path});
            try dir.createDir(ctx.io, "golden", std.Io.Dir.Permissions.default_dir);
            break :err_blk try dir.openDir(ctx.io, "golden", .{});
        } else {
            std.debug.print("Error when opening {s}: {s}\n", .{ golden_dir_path, @errorName(err) });
            return err;
        }
    };
    defer golden_dir.close(ctx.io);

    var iter = dir.iterate();

    var summary: Summary = switch (ctx.mode) {
        .Compare => .{ .comparison = .{} },
        .Generate => .{ .generated = .{} },
    };

    var did_not_exist = false;
    while (try iter.next(ctx.io)) |entry| {
        if (std.mem.eql(u8, std.fs.path.extension(entry.name), ".in")) {
            const golden_path = blk: {
                const basename_without_extension = std.fs.path.stem(entry.name);
                const golden_basename = try std.fmt.allocPrint(arena, "{s}.golden", .{basename_without_extension});
                break :blk try std.fs.path.resolve(arena, &.{ path_to_dir_resolved, "golden", golden_basename });
            };
            const query: Query = .{
                .filepath = try std.fs.path.resolve(arena, &.{ path_to_dir_resolved, entry.name }),
                .goldenpath = golden_path,
                .what_are_we_getting = what_are_we_getting,
            };
            switch (ctx.mode) {
                .Compare => {
                    var result = try compare(ctx, query);
                    defer result.deinit(ctx.gpa);
                    switch (result) {
                        .correct => {
                            summary.comparison.succeeded += 1;
                        },
                        .file_does_not_exist => {
                            did_not_exist = true;
                            summary.comparison.failed += 1;
                            std.debug.print("{s} does not exist\n", .{query.goldenpath});
                        },
                        .line_diff => |line_diff| {
                            summary.comparison.failed += 1;
                            std.debug.print(
                                "Difference on line {}:\nExpected: {s}\n  Actual: {s}\n",
                                .{
                                    line_diff.number,
                                    line_diff.expected orelse eof_marker,
                                    line_diff.actual orelse eof_marker,
                                },
                            );
                        },
                    }
                },
                .Generate => {
                    const result = try generate(ctx, query);
                    switch (result) {
                        .created => summary.generated.created += 1,
                        .updated => summary.generated.updated += 1,
                        .unchanged => summary.generated.unchanged += 1,
                    }
                },
            }
        }
    }
    if (did_not_exist) {
        std.debug.print("Consider `zig build golden-test -Dgenerate`\n", .{});
    }
    return summary;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const args = init.minimal.args.vector;
    if (args.len < 2) {
        std.debug.print("Golden test runner should be provided with a path to the executable.", .{});
        return error.NoArgumentsProvided;
    }
    const program_path = args[1];

    const mode = blk: {
        if (args.len > 2) {
            if (std.mem.eql(u8, std.mem.span(args[2]), "generate")) {
                std.debug.print("Generating new golden tests\n", .{});
                break :blk Mode.Generate;
            }
        }
        break :blk Mode.Compare;
    };

    const ctx: Context = .{
        .io = init.io,
        .gpa = gpa,
        .program_path = std.mem.span(program_path),
        .mode = mode,
    };
    const stdout_summary = try processDirectory(ctx, stdout_tests_path, .stdout);
    const stdout_summary_text = try stdout_summary.getText(ctx.gpa);
    defer ctx.gpa.free(stdout_summary_text);
    const stderr_summary = try processDirectory(ctx, stderr_tests_path, .stderr);
    const stderr_summary_text = try stderr_summary.getText(ctx.gpa);
    defer ctx.gpa.free(stderr_summary_text);
    std.debug.print("STDOUT: {s}STDERR: {s}", .{ stdout_summary_text, stderr_summary_text });
    if (ctx.mode == .Compare) {
        try std.testing.expect(stdout_summary.comparison.failed == 0 and stderr_summary.comparison.failed == 0);
    }
}

test {
    try std.testing.expect(true);
}

test "sub-modules" {
    _ = .{
        Lines,
    };
}

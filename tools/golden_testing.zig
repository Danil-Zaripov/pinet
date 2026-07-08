const std = @import("std");

const assert = std.debug.assert;

const stdout_tests_path = "tests";
const stderr_tests_path = "tests_errors";

pub const Lines = struct {
    lines: [][]const u8,

    pub fn init(gpa: std.mem.Allocator, contents: [:0]const u8) !Lines {
        var list = std.ArrayList([]const u8).empty;
        errdefer list.deinit(gpa);

        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            try list.append(gpa, line);
        }

        return .{
            .lines = try list.toOwnedSlice(gpa),
        };
    }

    pub fn deinit(self: Lines, gpa: std.mem.Allocator) void {
        gpa.free(self.lines);
    }

    test "single line" {
        const gpa = std.testing.allocator;
        const file = "hello world";

        var lines = try Lines.init(gpa, file);
        defer lines.deinit(gpa);

        try std.testing.expectEqualStrings("hello world", lines.lines[0]);
    }

    test "multiple lines" {
        const gpa = std.testing.allocator;
        const file = "hello\nworld\n";

        var lines = try Lines.init(gpa, file);
        defer lines.deinit(gpa);

        try std.testing.expectEqualStrings("hello", lines.lines[0]);
        try std.testing.expectEqualStrings("world", lines.lines[1]);
        try std.testing.expectEqualStrings("", lines.lines[2]);
    }
};

/// Gets command name and its arguments as an array and
/// tries to launch. The caller owns the memory.
pub fn invokeAndCollectStdout(command: []const []const u8, gpa: std.mem.Allocator, io: std.Io) ![:0]u8 {
    assert(command.len > 0);
    const result = std.process.run(gpa, io, .{
        .argv = command,
    }) catch |err| {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        try stderr.interface.print("Failed to run command: ", .{});
        try printCommand(&stderr.interface, command);
        try stderr.interface.print("\nReason: {s}\n", .{@errorName(err)});
        return error.HandledError;
    };

    if (!terminationSuccessful(result.term)) {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        try stderr.interface.print("Command failed: ", .{});
        try printCommand(&stderr.interface, command);
        try stderr.interface.print("\nTermination: ", .{});
        try printTermination(&stderr.interface, result.term);
        if (result.stderr.len != 0) {
            try stderr.interface.print("\nCaptured stderr:\n{s}\n", .{result.stderr});
        } else {
            try stderr.interface.print("\n", .{});
        }

        gpa.free(result.stderr);
        gpa.free(result.stdout);
        return error.HandledError;
    }

    gpa.free(result.stderr);
    return ret: {
        const duped = gpa.dupeSentinel(u8, result.stdout, 0);
        gpa.free(result.stdout);
        break :ret duped;
    };
}

pub fn invokeAndCollectStderr(command: []const []const u8, gpa: std.mem.Allocator, io: std.Io) ![:0]u8 {
    assert(command.len > 0);
    const result = std.process.run(gpa, io, .{
        .argv = command,
    }) catch |err| {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        try stderr.interface.print("Failed to run command: ", .{});
        try printCommand(&stderr.interface, command);
        try stderr.interface.print("\nReason: {s}\n", .{@errorName(err)});
        return error.HandledError;
    };

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

    pub fn writeMessage(self: LineDiff, writer: *std.Io.Writer, input_path: []const u8, golden_path: []const u8) !void {
        try writer.print(
            \\|{s} <> {s}| line {} difference:
            \\
            \\Expected: {s}
            \\  Actual: {s}
            \\
            \\
        ,
            .{ input_path, golden_path, self.number + 1, self.expected orelse eof_marker, self.actual orelse eof_marker },
        );
    }
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
    input_path: []const u8,
    goldenpath: []const u8,
    program_output: [:0]const u8,

    pub fn init(ctx: Context, filepath: []const u8, goldenpath: []const u8, what_are_we_getting: WhatAreWeGetting) !Query {
        const output = try switch (what_are_we_getting) {
            .stdout => invokeAndCollectStdout(&.{ ctx.program_path, "-f", filepath }, ctx.gpa, ctx.io),
            .stderr => invokeAndCollectStderr(&.{ ctx.program_path, "-f", filepath }, ctx.gpa, ctx.io),
        };
        return .{
            .input_path = filepath,
            .goldenpath = goldenpath,
            .program_output = output,
        };
    }

    pub fn deinit(self: Query, gpa: std.mem.Allocator) void {
        gpa.free(self.program_output);
    }
};

fn compare(ctx: Context, query: Query) !ComparisonResult {
    const cwd = std.Io.Dir.cwd();
    const golden = cwd.readFileAllocOptions(ctx.io, query.goldenpath, ctx.gpa, .unlimited, .of(u8), 0) catch |err| {
        if (err == error.FileNotFound) {
            return ComparisonResult.file_does_not_exist;
        } else {
            return err;
        }
    };
    defer ctx.gpa.free(golden);

    const output = query.program_output;

    const golden_lines = try Lines.init(ctx.gpa, golden);
    defer golden_lines.deinit(ctx.gpa);
    const output_lines = try Lines.init(ctx.gpa, output);
    defer output_lines.deinit(ctx.gpa);
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
        const output = query.program_output;

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
                "created: {}; updated: {}; unchanged: {}; total: {}\n",
                .{
                    generated.created,
                    generated.updated,
                    generated.unchanged,
                    generated.created + generated.updated + generated.unchanged,
                },
            ),
            .comparison => |comparison| try std.fmt.allocPrint(
                gpa,
                "passed: {}; failed: {}; total: {}\n",
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

    const path_to_dir_resolved = try std.fs.path.resolve(ctx.gpa, &.{path_to_dir});
    defer ctx.gpa.free(path_to_dir_resolved);

    const cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(ctx.io, path_to_dir_resolved, .{ .access_sub_paths = false, .iterate = true });
    defer dir.close(ctx.io);

    var stderr = std.Io.File.stderr().writer(ctx.io, &.{});

    const golden_dir_path = try std.fs.path.resolve(arena, &.{ path_to_dir_resolved, "golden" });
    if (ctx.mode == .Generate) {
        const golden_dir = dir.openDir(ctx.io, "golden", .{}) catch |err| err_blk: {
            if (err == error.FileNotFound) {
                try stderr.interface.print("{s} directory not found. Creating it.\n", .{golden_dir_path});
                try dir.createDir(ctx.io, "golden", std.Io.Dir.Permissions.default_dir);
                break :err_blk try dir.openDir(ctx.io, "golden", .{});
            }
            try stderr.interface.print("Error when opening {s}: {s}\n", .{ golden_dir_path, @errorName(err) });
            return err;
        };
        golden_dir.close(ctx.io);
    }

    var iter = dir.iterate();

    var summary: Summary = switch (ctx.mode) {
        .Compare => .{ .comparison = .{} },
        .Generate => .{ .generated = .{} },
    };

    while (try iter.next(ctx.io)) |entry| {
        if (std.mem.eql(u8, std.fs.path.extension(entry.name), ".in")) {
            const golden_path = blk: {
                const basename_without_extension = std.fs.path.stem(entry.name);
                const golden_basename = try std.fmt.allocPrint(arena, "{s}.golden", .{basename_without_extension});
                break :blk try std.fs.path.resolve(arena, &.{ path_to_dir_resolved, "golden", golden_basename });
            };
            const filepath = try std.fs.path.resolve(arena, &.{ path_to_dir_resolved, entry.name });
            const query = Query.init(ctx, filepath, golden_path, what_are_we_getting) catch |err|
                if (err == error.HandledError) continue else return err;

            defer query.deinit(ctx.gpa);
            switch (ctx.mode) {
                .Compare => {
                    var result = try compare(ctx, query);
                    defer result.deinit(ctx.gpa);
                    switch (result) {
                        .correct => {
                            summary.comparison.succeeded += 1;
                        },
                        .file_does_not_exist => {
                            summary.comparison.failed += 1;
                            try stderr.interface.print("Missing golden file for {s}: {s}\n", .{ query.input_path, query.goldenpath });
                        },
                        .line_diff => |line_diff| {
                            summary.comparison.failed += 1;
                            try line_diff.writeMessage(&stderr.interface, query.input_path, query.goldenpath);
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
    if (summary == .comparison and summary.comparison.failed != 0) {
        try stderr.interface.print("Consider `zig build golden-test -Dgenerate` or fix your code.\n\n", .{});
    }
    return summary;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var stderr = std.Io.File.stderr().writer(init.io, &.{});
    var stdout = std.Io.File.stdout().writer(init.io, &.{});

    const args = init.minimal.args.vector;
    if (args.len < 2) {
        try stderr.interface.print("Golden test runner requires a path to the executable.\n", .{});
        std.process.exit(1);
    }
    const program_path = args[1];

    const mode = mode: {
        if (args.len > 2) {
            const arg = std.mem.span(args[2]);
            if (std.mem.eql(u8, arg, "generate")) {
                try stderr.interface.print("Generating new golden tests\n", .{});
                break :mode Mode.Generate;
            } else if (std.mem.eql(u8, arg, "compare")) {
                break :mode Mode.Compare;
            }
            try stderr.interface.print("Unknown mode: {s}. Expected `compare` or `generate`.\n", .{arg});
            std.process.exit(1);
        }
        break :mode Mode.Compare;
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

    try stdout.interface.print(
        "{s: <12}| {s}{s: <12}| {s}",
        .{
            stdout_tests_path,
            stdout_summary_text,
            stderr_tests_path,
            stderr_summary_text,
        },
    );
    if (ctx.mode == .Compare) {
        if (stdout_summary.comparison.failed != 0 or stderr_summary.comparison.failed != 0) {
            std.process.exit(1);
        }
    }
}

fn printCommand(writer: *std.Io.Writer, command: []const []const u8) !void {
    for (command, 0..) |arg, idx| {
        if (idx != 0) try writer.print(" ", .{});
        try writer.print("{s}", .{arg});
    }
}

fn printTermination(writer: *std.Io.Writer, termination: std.process.Child.Term) !void {
    switch (termination) {
        .exited => |code| try writer.print("exited with code {}", .{code}),
        .signal => |signal| try writer.print("terminated by signal {}", .{signal}),
        .stopped => |signal| try writer.print("stopped by signal {}", .{signal}),
        .unknown => |code| try writer.print("terminated for unknown reason ({})", .{code}),
    }
}

fn terminationSuccessful(termination: std.process.Child.Term) bool {
    return switch (termination) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "sub-modules" {
    _ = .{
        Lines,
    };
}

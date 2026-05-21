const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lexer_mod = b.addModule("lexer", .{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
    });

    const parser_mod = b.addModule("parser", .{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
    });

    const mod = b.addModule("pinet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "lexer", .module = lexer_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "pinet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pinet", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const lexer_tests = b.addTest(.{
        .root_module = lexer_mod,
    });
    const parser_tests = b.addTest(.{
        .root_module = parser_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_lexer_tests = b.addRunArtifact(lexer_tests);
    const run_parser_tests = b.addRunArtifact(parser_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_lexer_tests.step);
    test_step.dependOn(&run_parser_tests.step);
}

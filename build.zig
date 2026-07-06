const std = @import("std");
const HeapKind = @import("src/vm/memory.zig").HeapKind;

pub const DebugPrintConfig = struct {
    print_compiled_instructions: bool = false,
    print_interactions: bool = false,
    print_memory_usage: bool = false,
    print_frees: bool = false,
    benchmark: bool = false,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("pinet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
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
        // To use llvm debugger:
        // .use_llvm = true,
    });

    const clap = b.dependency("clap", .{});
    exe.root_module.addImport("clap", clap.module("clap"));

    const debug_printing = DebugPrintConfig{
        .print_compiled_instructions = b.option(bool, "print-compiled-instructions", "print compiled instructions") orelse false,
        .print_interactions = b.option(bool, "print-interactions", "print interaction points when they happen") orelse false,
        .print_memory_usage = b.option(bool, "print-memory-usage", "print memory usage after top-level interactions") orelse false,
        .print_frees = b.option(bool, "print-frees", "print message when a agent/name free happens") orelse false,
        .benchmark = b.option(bool, "benchmark", "print time spent in interactions") orelse false,
    };

    const options = b.addOptions();
    options.addOption(DebugPrintConfig, "debug_printing", debug_printing);

    const heap_kind = b.option(HeapKind, "heap", "which heap implementation to use") orelse .basic;
    options.addOption(HeapKind, "heap", heap_kind);

    mod.addOptions("config", options);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run pinet");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

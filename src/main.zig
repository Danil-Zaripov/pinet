const std = @import("std");
const Io = std.Io;

const pinet = @import("pinet");

const clap = @import("clap");

const help =
    \\-h, --help                     Display this help and exit.
    \\-t, --threads <usize>          Specify number of threads to be run on (this does not work yet).
    \\-f, --filepath <str>           Specify file to be interpreted. Default: ./tests/list_sorting.in
    \\
;
const params = clap.parseParamsComptime(help);

// TODO: make it less cramped
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var sthreaded = Io.Threaded.init_single_threaded;
    defer sthreaded.deinit();
    const io = sthreaded.io();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        // Report useful error and exit.
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    var filepath: []const u8 = "./tests/list_sorting.in";

    if (res.args.help != 0) {
        var stdio = std.Io.File.stdin().writer(io, &.{});
        try stdio.interface.print("{s}", .{help});
        return;
    }
    if (res.args.threads) |n|
        std.debug.print("you specified -t {}, but it is not yet developed.\n", .{n});
    if (res.args.filepath) |fp| {
        filepath = fp;
    } else {
        std.debug.print("File not specified, executing {s}\nConsider using \"--help\"\n", .{filepath});
    }

    const contents = try Io.Dir.readFileAllocOptions(
        Io.Dir.cwd(),
        io,
        filepath,
        gpa,
        .unlimited,
        .of(u8),
        0,
    );
    defer gpa.free(contents);

    const tokens = try pinet.Lexer.tokenize(gpa, contents);

    const main_file = pinet.Runtime.File{
        .path = filepath,
        .contents = contents,
        .tokens = tokens,
    };

    defer gpa.free(tokens);
    var parser = try pinet.Parser.init(tokens, gpa, std.heap.page_allocator);
    defer parser.deinit(gpa);
    const program = parser.parseProgram() catch |err| {
        if (err == error.ErrorDuringParsing) {
            const prettyLines = try parser.err.?.getPrettyLine(&parser, contents);
            const messageLine = try parser.err.?.messageLine(&parser);
            std.debug.print("{s}\n\n{s}\n{s}\n", .{ messageLine, prettyLines[0], prettyLines[1] });
            std.process.exit(1);
        }
        return err;
    };
    var runtime = try pinet.Runtime.init(gpa, std.heap.page_allocator, main_file);
    defer runtime.deinit(gpa);
    var vm = try pinet.VM.init(gpa, &runtime);
    defer vm.deinit();
    vm.runProgram(program) catch |err| {
        if (err == error.CompilationError) {
            std.process.exit(1);
        }
        return err;
    };
}

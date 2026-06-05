const std = @import("std");
const Io = std.Io;

const pinet = @import("pinet");

// TODO: normal args parsing using clap
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = init.minimal.args.vector;
    const filepath: []const u8 = if (args.len < 2) "./tests/list_sorting.in" else std.mem.span(args[1]);
    var sthreaded = Io.Threaded.init_single_threaded;
    defer sthreaded.deinit();
    const io = sthreaded.io();

    const max_file_bytes = 10 * 1024 * 1024;
    const contents = try Io.Dir.readFileAllocOptions(
        Io.Dir.cwd(),
        io,
        filepath,
        gpa,
        .limited(max_file_bytes),
        .of(u8),
        0,
    );
    defer gpa.free(contents);

    const tokens = try pinet.Lexer.tokenize(gpa, contents);
    defer gpa.free(tokens);
    var parser = try pinet.Parser.Parser.init(tokens, gpa);
    defer parser.deinit(gpa);
    const program = parser.parseProgram() catch |err| {
        if (err == error.ErrorDuringParsing) {
            const messageLine = try parser.err.?.messageLine(gpa, &parser);
            std.debug.print("{s}\n", .{messageLine});
            gpa.free(messageLine);
        }
        return err;
    };
    var runtime = try pinet.Runtime.init(gpa);
    defer runtime.deinit(gpa);
    var vm = try pinet.VM.init(gpa, &runtime);
    defer vm.deinit();
    try vm.runProgram(program);
}

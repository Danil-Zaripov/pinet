const std = @import("std");
const Io = std.Io;

const pinet = @import("pinet");

// TODO: normal args parsing using clap
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = init.minimal.args.vector;
    const filepath: []const u8 = if (args.len < 2) "./tests/numbers.in" else if_stmt: {
        const data: [*:0]const u8 = args[1];
        const len: usize = loop: for (0..128) |idx| {
            if (data[idx] == 0) break :loop idx;
        } else unreachable;
        break :if_stmt data[0..len];
    };
    var sthreaded = Io.Threaded.init_single_threaded;
    defer sthreaded.deinit();
    const io = sthreaded.io();

    const buffer: []u8 = try gpa.alloc(u8, 1024);
    defer gpa.free(buffer);
    @memset(buffer, 0);
    const contents = try Io.Dir.readFile(Io.Dir.cwd(), io, filepath, buffer);

    const tokens = try pinet.Lexer.tokenize(gpa, @ptrCast(contents));
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

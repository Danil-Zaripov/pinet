const std = @import("std");
const Io = std.Io;

const pinet = @import("pinet");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const filepath = "./tests/rules.in";
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
    const program = try parser.parseProgram();
    var runtime = try pinet.Runtime.init(gpa);
    defer runtime.deinit(gpa);
    var vm = try pinet.VM.init(gpa, &runtime);
    defer vm.deinit();
    try vm.runProgram(program);
}

const std = @import("std");
const Io = std.Io;

const pinet = @import("pinet");

pub fn main(init: std.process.Init) !void {
    var gpa = init.arena.allocator();
    const filepath = "./test.in";
    var sthreaded = Io.Threaded.init_single_threaded;
    defer sthreaded.deinit();
    const io = sthreaded.io();

    const buffer: []u8 = try gpa.alloc(u8, 1024);
    defer gpa.free(buffer);
    {
        var i: usize = 0;
        while (i < buffer.len) : (i += 1) {
            buffer[i] = 0;
        }
    }
    const contents = try Io.Dir.readFile(Io.Dir.cwd(), io, filepath, buffer);

    const tokens = try pinet.Lexer.tokenize(gpa, @ptrCast(contents));
    var parser = pinet.Parser.Parser.init(tokens, gpa);
    defer parser.deinit();
    const program = try parser.parseProgram();
    var runtime = try pinet.Runtime.init(gpa);
    defer runtime.deinit(gpa);
    var vm = try pinet.VM.init(gpa, &runtime);
    defer vm.deinit();
    try vm.runProgram(program);
}

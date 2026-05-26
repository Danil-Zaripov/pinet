const std = @import("std");
const Lexer = @import("lexer.zig");

const Token = Lexer.Token;

const TokenSlice = struct {
    start: u32,
    end: u32,
};

pub fn Node(comptime T: type) type {
    return struct {
        val: T,
        tslice: TokenSlice,
    };
}

const Name = struct {
    val: []const u8,
};

const ObjList = struct {
    obj: Node(Object),
    node: std.SinglyLinkedList.Node = .{},
};

// (Name or Agent) or Agent(...)
// Think whether all agents should be in form Z(...)
// or to allow Z without ()
const Object = struct {
    name: []const u8,
    objlist: ?std.SinglyLinkedList,
};

const ActivePair = struct { lhs: Object };

const NameList = struct {
    name: Name,
    node: std.SinglyLinkedList.Node = .{},
};

const Statement = union(enum) {
    free_stmt: std.SinglyLinkedList,
    active_pair,
};

const ParserError = struct {
    tag: Tag,
    pos: usize,

    const Tag = union(enum) {
        UnexpectedEof: void,
        ExpectedStatement: struct { found: Token.Tag },
        UnexpectedToken: struct { expected: Token.Tag, actual: Token.Tag },
    };
    pub fn message(self: *ParserError, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self.tag) {
            .UnexpectedEof => "Unexpected end of file",
            .ExpectedStatement => |val| (try std.fmt.allocPrint(alloc, "Expected statement, found token: {s}", .{val.found.symbol()})),
            .UnexpectedToken => |val| try std.fmt.allocPrint(alloc, "Expected {s}, found {s}", .{ val.expected.symbol(), val.actual.symbol() }),
        };
    }
    pub fn messageLine(self: *ParserError, alloc: std.mem.Allocator, parser_data: *const Parser) ![]const u8 {
        const loc = parser_data.tokens[self.pos].loc.start;
        return std.fmt.allocPrint(alloc, "{}:{} {s}", .{ loc.line, loc.ch, try self.message(alloc) });
    }
};

const Error = error{
    ErrorDuringParsing,
};

const Parser = struct {
    tokens: []const Token,
    index: usize,
    _arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    err: ?ParserError,

    pub fn init(tokens: []const Token, gpa: std.mem.Allocator) Parser {
        var arena = std.heap.ArenaAllocator.init(gpa);
        return .{
            .tokens = tokens,
            .index = 0,
            ._arena = arena,
            .allocator = arena.allocator(),
            .err = null,
        };
    }

    fn unexpected_token(self: *Parser, expected: Token.Tag, actual: Token.Tag) void {
        self.err = .{
            .tag = .{ .UnexpectedToken = .{ .actual = actual, .expected = expected } },
            .pos = self.index - 1,
        };
    }

    pub fn deinit(self: *Parser) void {
        self._arena.deinit();
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.index];
    }

    fn advance(self: *Parser) Token {
        self.index += 1;
        return self.tokens[self.index - 1];
    }

    fn parseObject(self: *Parser) !*Node(Object) {
        _ = self;
        return Error.ErrorDuringParsing;
    }

    pub fn parseStmt(self: *Parser) !?*Node(Statement) {
        const tentry = self.advance();
        var ret = try self.allocator.create(Node(Statement));
        ret.* = .{ .val = undefined, .tslice = .{ .start = @intCast(self.index - 1), .end = undefined } };
        switch (tentry.tag) {
            .eof, .semicolon => {
                self.allocator.destroy(ret);
                return null;
            },
            .keyword_free => {
                const names = try self.parseNameList();
                ret.val = .{ .free_stmt = names };
            },
            else => {
                self.err = .{
                    .pos = self.index - 1,
                    .tag = .{ .ExpectedStatement = .{ .found = tentry.tag } },
                };
            },
        }
        if (self.advance().tag != .semicolon) {
            self.unexpected_token(.semicolon, self.tokens[self.index - 1].tag);
        }
        if (self.err != null) {
            return Error.ErrorDuringParsing;
        }

        ret.tslice.end = @intCast(self.index - 1);
        return ret;
    }

    fn parseNameList(self: *Parser) !std.SinglyLinkedList {
        const tentry = self.advance();

        if (tentry.tag != .identifier) {
            self.unexpected_token(.identifier, tentry.tag);
        }
        const namelist = try self.allocator.create(NameList);
        namelist.* = .{ .name = .{ .val = tentry.content.? } };
        var list: std.SinglyLinkedList = .{};
        list.prepend(&namelist.node);
        while (self.peek().tag == .identifier) {
            const t = self.advance();
            const new_namelist = try self.allocator.create(NameList);
            new_namelist.* = .{ .name = .{ .val = t.content.? } };
            // we don't care about the placement
            list.prepend(&new_namelist.node);
        }

        std.SinglyLinkedList.Node.reverse(&list.first);
        return list;
    }
};

test "free stmt" {
    var dalloc = std.heap.DebugAllocator(.{}).init;
    defer dalloc.deinitWithoutLeakChecks();
    const alloc = dalloc.allocator();
    const program = "free a b c;";
    const tokens = try Lexer.tokenize(alloc, program);

    var parser = Parser.init(tokens, alloc);
    defer parser.deinit();

    const stmt = parser.parseStmt();
    switch ((try stmt).?.val) {
        .free_stmt => |list| {
            try std.testing.expectEqualStrings(@as(*NameList, @fieldParentPtr("node", list.first.?)).name.val, "a");
        },
        else => unreachable,
    }
}

test "parser test" {
    try std.testing.expect(true);
}

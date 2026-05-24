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

const Statement = union(enum) {
    free_stmt: std.SinglyLinkedList(*Node(Name)),
};

const ParserError = error{
    UnexpectedToken,
    UnexpectedEof,
};

const Parser = struct {
    tokens: []const Token,
    index: usize,
    _arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(tokens: []const Token, gpa: std.mem.Allocator) Parser {
        var arena = std.heap.ArenaAllocator.init(gpa);
        return .{
            .tokens = tokens,
            .index = 0,
            ._arena = arena,
            .allocator = arena.allocator(),
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

    fn parseStmt(self: *Parser) !?*Node(Statement) {
        const tentry = self.advance();
        var ret = try self.allocator.create(Node(Statement));

        switch (tentry.tag) {
            .eof => {
                self.allocator.free(ret);
                return null;
            },
            .keyword_free => {
                const names = try self.parseNamesList();
                ret.val = .{ .free_stmt = names };
            },
            else => return ParserError.UnexpectedToken,
        }
    }
};

test "parser test" {
    try std.testing.expect(true);
}

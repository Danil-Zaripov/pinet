const std = @import("std");
const Lexer = @import("lexer.zig");

const Token = Lexer.Token;

pub const number_special_ident = "#number";

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

pub const Name = struct {
    val: []const u8,
};

// (Name or Agent) or Agent(...)
// Think whether all agents should be in form Z(...)
// or to allow Z without ()
pub const Object = struct {
    name: []const u8,
    portlist: ?[]Node(Object),
};

pub const ActivePair = struct {
    lhs: Node(Object),
    rhs: Node(Object),
};

pub const Rule = struct {
    lhs: Node(Object),
    rhs: Node(Object),
    pairs: []Node(ActivePair),
};

pub const Statement = union(enum) {
    free_stmt: []const Name,
    active_pair: ActivePair,
    rule: Rule,
    print_stmt: Name,
    use_stmt, // TODO
    const_stmt,
};

pub const Program = struct {
    statements: []Node(Statement),
};

const ParserError = struct {
    tag: Tag,
    pos: usize,

    const Tag = union(enum) {
        UnexpectedEof: void,
        ExpectedObject: struct { found: Token.Tag },
        ExpectedStatement: struct { found: Token.Tag },
        UnexpectedToken: struct { expected: Token.Tag, actual: Token.Tag },
    };
    pub fn message(self: *const ParserError, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self.tag) {
            .UnexpectedEof => "Unexpected end of file",
            .ExpectedObject => |val| try std.fmt.allocPrint(alloc, "Expected object, found token: {s}", .{val.found.symbol()}),
            .ExpectedStatement => |val| (try std.fmt.allocPrint(alloc, "Expected statement, found token: {s}", .{val.found.symbol()})),
            .UnexpectedToken => |val| try std.fmt.allocPrint(alloc, "Expected {s}, found {s}", .{ val.expected.symbol(), val.actual.symbol() }),
        };
    }
    pub fn messageLine(self: *const ParserError, alloc: std.mem.Allocator, parser_data: *const Parser) ![]const u8 {
        const loc = parser_data.tokens[self.pos].loc.start;
        const msg = try self.message(alloc);
        defer alloc.free(msg);
        return std.fmt.allocPrint(alloc, "{}:{} {s}", .{ loc.line, loc.ch, msg });
    }
};

const Error = error{
    ErrorDuringParsing,
};

pub const Parser = struct {
    tokens: []const Token,
    index: usize,
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    err: ?ParserError,

    reached_eof: bool,

    pub fn init(tokens: []const Token, gpa: std.mem.Allocator) !Parser {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        return .{
            .tokens = tokens,
            .index = 0,
            .arena = arena,
            .allocator = arena.allocator(),
            .reached_eof = false,
            .err = null,
        };
    }

    fn unexpected_token(self: *Parser, expected: Token.Tag, actual: Token.Tag) void {
        self.err = .{
            .tag = .{ .UnexpectedToken = .{ .actual = actual, .expected = expected } },
            .pos = self.index - 1,
        };
    }

    pub fn deinit(self: *Parser, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.index];
    }

    fn advance(self: *Parser) Token {
        self.index += 1;
        return self.tokens[self.index - 1];
    }

    fn parseObjList(self: *Parser) error{ NoSpaceLeft, OutOfMemory, ErrorDuringParsing }![]Node(Object) {
        var list = std.ArrayList(Node(Object)).empty;
        const objt = self.peek();
        objtoken: switch (objt.tag) {
            .rparen => {
                return list.items;
            },
            .identifier, .lparen, .numeric_literal => {
                const obj = try self.parseObject();
                try list.append(self.allocator, obj);
                if (self.peek().tag == .comma) {
                    _ = self.advance();
                    continue :objtoken self.peek().tag;
                }
            },
            else => {
                self.err = .{
                    .pos = self.index,
                    .tag = .{ .ExpectedObject = .{ .found = self.peek().tag } },
                };
                return Error.ErrorDuringParsing;
            },
        }
        return try list.toOwnedSlice(self.allocator);
    }

    fn parseObject(self: *Parser) !Node(Object) {
        const tentry = self.peek();
        var ret: Node(Object) = .{
            .val = Object{
                .name = undefined,
                .portlist = undefined,
            },
            .tslice = .{
                .start = @intCast(self.index),
                .end = undefined,
            },
        };
        var tuple = false;
        defer ret.tslice.end = @intCast(self.index - 1);

        switch (tentry.tag) {
            .identifier => {
                ret.val.name = tentry.content.?;
                _ = self.advance();
            },
            .numeric_literal => {
                ret.val.name = number_special_ident;
                const objlist = try self.allocator.alloc(Node(Object), 1);
                objlist[0] = Node(Object){
                    .val = Object{
                        .name = tentry.content.?,
                        .portlist = null,
                    },
                    .tslice = .{
                        .start = @intCast(self.index),
                        .end = @intCast(self.index),
                    },
                };
                ret.val.portlist = objlist;
                _ = self.advance();
                return ret;
            },
            .lparen => {
                tuple = true;
            },
            else => {
                self.err = ParserError{
                    .tag = .{ .ExpectedObject = .{ .found = tentry.tag } },
                    .pos = self.index,
                };
                return Error.ErrorDuringParsing;
            },
        }

        switch (self.peek().tag) {
            .lparen => {
                _ = self.advance();
                const lst = try self.parseObjList();
                ret.val.portlist = lst;
                const closing = self.advance();
                try self.expectTag(.rparen, closing.tag);
            },
            else => {
                ret.val.portlist = null;
            },
        }

        if (tuple) {
            ret.val.name = try self.getTupleName(ret.val.portlist.?.len);
        }
        return ret;
    }

    fn getTupleName(self: *Parser, size: usize) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "Tuple{}", .{size});
    }

    fn expectTag(self: *Parser, expected: Token.Tag, actual: Token.Tag) Error!void {
        if (expected != actual) {
            self.unexpected_token(expected, actual);
            return Error.ErrorDuringParsing;
        }
    }

    fn parsePairs(self: *Parser) ![]Node(ActivePair) {
        var list = std.ArrayList(Node(ActivePair)).empty;
        if (self.peek().tag == .semicolon) {
            return list.items;
        }

        objtoken: switch (self.peek().tag) {
            .identifier => {
                const lhs = try self.parseObject();
                const tilde = self.advance();
                try self.expectTag(.tilde, tilde.tag);
                const rhs = try self.parseObject();
                const pair = ActivePair{ .lhs = lhs, .rhs = rhs };
                const tslice = TokenSlice{ .start = lhs.tslice.start, .end = rhs.tslice.end };
                try list.append(self.allocator, .{ .val = pair, .tslice = tslice });
                if (self.peek().tag == .comma) {
                    _ = self.advance();
                    continue :objtoken self.peek().tag;
                }
            },
            else => {
                self.unexpected_token(.identifier, self.peek().tag);
                return Error.ErrorDuringParsing;
            },
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn parseStmt(self: *Parser) !?Node(Statement) {
        const tentry = self.peek();
        var ret: Node(Statement) = .{ .val = undefined, .tslice = .{ .start = @intCast(self.index), .end = undefined } };
        switch (tentry.tag) {
            .eof, .semicolon => {
                if (tentry.tag == .eof) {
                    self.reached_eof = true;
                }
                _ = self.advance();
                return null;
            },
            .keyword_free => {
                _ = self.advance();
                const names = try self.parseNameList();
                ret.val = .{ .free_stmt = names };
            },
            .identifier, .numeric_literal, .lparen => {
                const lhs = try self.parseObject();
                const connection = self.peek();
                switch (connection.tag) {
                    .rule_symbol => {
                        _ = self.advance();
                        const rhs = try self.parseObject();
                        try self.expectTag(.fatrightarrow, self.advance().tag);
                        const pairs = try self.parsePairs();
                        ret.val = .{ .rule = .{ .lhs = lhs, .rhs = rhs, .pairs = pairs } };
                    },
                    .tilde => {
                        _ = self.advance();
                        const rhs = try self.parseObject();
                        ret.val = .{ .active_pair = .{ .lhs = lhs, .rhs = rhs } };
                    },
                    .semicolon => {
                        ret.val = .{ .print_stmt = .{ .val = lhs.val.name } };
                    },
                    else => {
                        self.err = .{ .pos = self.index - 1, .tag = .{ .ExpectedStatement = .{ .found = connection.tag } } };
                        return Error.ErrorDuringParsing;
                    },
                }
            },
            else => {
                self.err = .{
                    .pos = self.index - 1,
                    .tag = .{ .ExpectedStatement = .{ .found = tentry.tag } },
                };
                return Error.ErrorDuringParsing;
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

    pub fn parseProgram(self: *Parser) !Program {
        var list = try std.ArrayList(Node(Statement)).initCapacity(self.allocator, 20);
        var maybe_stmt = try self.parseStmt();
        while (!self.reached_eof) : (maybe_stmt = try self.parseStmt()) {
            if (maybe_stmt) |stmt| {
                try list.append(self.allocator, stmt);
            }
        }
        return .{ .statements = try list.toOwnedSlice(self.allocator) };
    }

    fn parseNameList(self: *Parser) ![]Name {
        const tentry = self.advance();

        if (tentry.tag != .identifier) {
            self.unexpected_token(.identifier, tentry.tag);
        }
        var list = std.ArrayList(Name).empty;
        try list.append(self.allocator, .{ .val = tentry.content.? });
        while (self.peek().tag == .identifier) {
            const t = self.advance();
            try list.append(self.allocator, .{ .val = t.content.? });
        }
        return list.toOwnedSlice(self.allocator);
    }
};

test "rule stmt" {
    var dalloc = std.heap.DebugAllocator(.{}).init;
    defer dalloc.deinitWithoutLeakChecks();
    const alloc = dalloc.allocator();
    const program =
        \\ Add(r, x) >< S(y) =>
        \\   Add(w, x) ~ y,
        \\   r ~ S(w);
    ;
    const tokens = try Lexer.tokenize(alloc, program);

    var parser = try Parser.init(tokens, alloc);
    defer parser.deinit(alloc);

    const stmt = parser.parseStmt();
    if (parser.err) |err| {
        std.debug.print("{s}\n", .{try err.messageLine(alloc, &parser)});
    }

    switch ((try stmt).?.val) {
        .rule => |rule| {
            try std.testing.expectEqualStrings("Add", rule.lhs.val.name);
            try std.testing.expectEqualStrings("S", rule.rhs.val.name);
            try std.testing.expectEqualStrings("y", rule.rhs.val.portlist.?[0].val.name);
            try std.testing.expectEqualStrings("w", rule.pairs[0].val.lhs.val.portlist.?[0].val.name);
            try std.testing.expectEqualStrings("w", rule.pairs[1].val.rhs.val.portlist.?[0].val.name);
        },
        else => unreachable,
    }
}

test "active pair stmt" {
    var dalloc = std.heap.DebugAllocator(.{}).init;
    defer dalloc.deinitWithoutLeakChecks();
    const alloc = dalloc.allocator();
    const program = "A(b,c) ~ Z;";
    const tokens = try Lexer.tokenize(alloc, program);

    var parser = try Parser.init(tokens, alloc);
    defer parser.deinit(alloc);

    const stmt = parser.parseStmt();
    if (parser.err) |err| {
        std.debug.print("{s}\n", .{try err.messageLine(alloc, &parser)});
    }

    switch ((try stmt).?.val) {
        .active_pair => |ap| {
            try std.testing.expectEqualStrings("A", ap.lhs.val.name);
            try std.testing.expectEqualStrings("Z", ap.rhs.val.name);
            try std.testing.expectEqualStrings("b", ap.lhs.val.portlist.?[0].val.name);
            try std.testing.expectEqualStrings("c", ap.lhs.val.portlist.?[1].val.name);
        },
        else => unreachable,
    }
}

test "free stmt" {
    var dalloc = std.heap.DebugAllocator(.{}).init;
    defer dalloc.deinitWithoutLeakChecks();
    const alloc = dalloc.allocator();
    const program = "free a b longname'''';";
    const tokens = try Lexer.tokenize(alloc, program);

    var parser = try Parser.init(tokens, alloc);
    defer parser.deinit(alloc);

    const stmt = parser.parseStmt();
    if (parser.err) |err| {
        std.debug.print("{s}\n", .{try err.messageLine(alloc, &parser)});
    }
    switch ((try stmt).?.val) {
        .free_stmt => |list| {
            try std.testing.expectEqualStrings("a", list[0].val);
            try std.testing.expectEqualStrings("b", list[1].val);
            try std.testing.expectEqualStrings("longname''''", list[2].val);
        },
        else => unreachable,
    }
}

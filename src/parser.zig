const std = @import("std");
const Lexer = @import("lexer.zig");
const AST = @import("ast.zig");

const Token = Lexer.Token;

pub const Parser = @This();

const ParserError = struct {
    tag: Tag,
    pos: usize,

    const Tag = union(enum) {
        UnexpectedEof: void,
        ExpectedObject: struct { found: Token.Tag },
        ExpectedStatement: struct { found: Token.Tag },
        ExpectedExpression: struct { found: Token.Tag },
        UnexpectedToken: struct { expected: Token.Tag, actual: Token.Tag },
    };

    pub fn message(self: *const ParserError, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self.tag) {
            .UnexpectedEof => "Unexpected end of file",
            .ExpectedObject => |val| try std.fmt.allocPrint(alloc, "Expected object, found token: {s}", .{val.found.symbol()}),
            .ExpectedStatement => |val| try std.fmt.allocPrint(alloc, "Expected statement, found token: {s}", .{val.found.symbol()}),
            .ExpectedExpression => |val| try std.fmt.allocPrint(alloc, "Expected expression, found token: {s}", .{val.found.symbol()}),
            .UnexpectedToken => |val| try std.fmt.allocPrint(alloc, "Expected {s}, found {s}", .{ val.expected.symbol(), val.actual.symbol() }),
        };
    }

    /// Parser's arena owns the message.
    pub fn messageLine(self: *const ParserError, parser: *Parser) ![]const u8 {
        const loc = parser.tokens[self.pos].loc.start;
        const msg = try self.message(parser.allocator);
        defer parser.allocator.free(msg);

        return std.fmt.allocPrint(parser.allocator, "{}:{} {s}", .{ loc.line, loc.ch, msg });
    }
};

pub const Error = error{
    ErrorDuringParsing,
};

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

fn getTokenInfixBP(self: *Parser, tag: Token.Tag) !struct { i32, i32 } {
    return switch (tag) {
        .logic_or => .{ 10, 11 },
        .logic_and => .{ 20, 21 },
        .eq => .{ 30, 31 },
        .greater, .geq, .less, .leq => .{ 40, 41 },
        else => {
            self.err = .{
                .pos = self.index,
                .tag = .{
                    .ExpectedExpression = .{ .found = tag },
                },
            };
            return Error.ErrorDuringParsing;
        },
    };
}

fn parseUnary(self: *Parser) !*AST.Node(AST.Expression) {
    const expr = try self.allocator.create(AST.Node(AST.Expression));
    expr.tslice.start = @intCast(self.index);
    defer expr.tslice.end = @intCast(self.index);
    expr.val = switch (self.peek().tag) {
        .exclamation_mark => AST.Expression{ .unary_op = .{ .tag = .not, .item = try self.parseUnary() } },
        else => AST.Expression{ .atom = try self.parseObject() },
    };
    return expr;
}

fn parseExpression(self: *Parser, min_bp: i32) !*AST.Node(AST.Expression) {
    var lhs = try self.parseUnary();
    while (true) {
        const token = self.peek().tag;
        const op: AST.Expression.BinaryExpr.Tag = switch (token) {
            .fatrightarrow => break,
            .eq => .eq,
            .logic_and => .logic_and,
            .logic_or => .logic_or,
            .greater => .greater,
            .geq => .geq,
            .less => .less,
            .leq => .leq,
            else => {
                self.err = .{
                    .pos = self.index,
                    .tag = .{ .ExpectedExpression = .{ .found = token } },
                };
                return Error.ErrorDuringParsing;
            },
        };

        const lbp, const rbp = try self.getTokenInfixBP(token);
        if (lbp < min_bp) {
            break;
        }
        _ = self.advance();
        const rhs = try self.parseExpression(rbp);
        const new_lhs = try self.allocator.create(AST.Node(AST.Expression));
        new_lhs.* = .{
            .tslice = .{
                .start = lhs.tslice.start,
                .end = @intCast(self.index),
            },
            .val = .{
                .binary_op = .{
                    .lhs = lhs,
                    .rhs = rhs,
                    .tag = op,
                },
            },
        };
        lhs = new_lhs;
    }
    return lhs;
}

fn parseObjList(self: *Parser) error{ NoSpaceLeft, OutOfMemory, ErrorDuringParsing }![]AST.Node(AST.Object) {
    var list = std.ArrayList(AST.Node(AST.Object)).empty;

    while (self.peek().tag != .rparen) {
        switch (self.peek().tag) {
            .identifier, .lparen, .numeric_literal => {
                const obj = try self.parseObject();
                try list.append(self.allocator, obj);
                if (self.peek().tag == .comma) {
                    _ = self.advance();
                } else if (self.peek().tag != .rparen) {
                    self.err = .{
                        .pos = self.index,
                        .tag = .{ .ExpectedObject = .{ .found = self.peek().tag } },
                    };
                    return Error.ErrorDuringParsing;
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
    }
    return try list.toOwnedSlice(self.allocator);
}

fn parseConsList(self: *Parser) error{ NoSpaceLeft, OutOfMemory, ErrorDuringParsing }!AST.Node(AST.Object) {
    const tentry = self.peek();
    var ret: AST.Node(AST.Object) = .{
        .val = AST.Object{
            .name = undefined,
            .portlist = undefined,
        },
        .tslice = .{
            .start = @intCast(self.index),
            .end = undefined,
        },
    };
    defer ret.tslice.end = @intCast(self.index - 1);
    if (tentry.tag == .rbracket) {
        ret.val.name = AST.nil_list_ident;
        ret.val.portlist = try self.allocator.alloc(AST.Node(AST.Object), 0);
        _ = self.advance();
        return ret;
    }
    ret.val = .{
        .name = AST.cons_list_ident,
        .portlist = try self.allocator.alloc(AST.Node(AST.Object), 2),
    };
    ret.val.portlist.?[0] = try self.parseObject();
    var node = ret;
    while (self.peek().tag == .comma) {
        _ = self.advance();
        var new_node: AST.Node(AST.Object) = .{
            .val = AST.Object{
                .name = AST.cons_list_ident,
                .portlist = try self.allocator.alloc(AST.Node(AST.Object), 2),
            },
            .tslice = .{
                .start = @intCast(self.index),
                .end = undefined,
            },
        };
        new_node.val.portlist.?[0] = try self.parseObject();
        new_node.tslice.end = @intCast(self.index);
        node.val.portlist.?[1] = new_node;
        node = new_node;
    }
    try self.expectTag(.rbracket, self.advance().tag);
    node.val.portlist.?[1] = AST.Node(AST.Object){
        .val = .{
            .name = AST.nil_list_ident,
            .portlist = try self.allocator.alloc(AST.Node(AST.Object), 0),
        },
        .tslice = .{
            .start = @intCast(self.index),
            .end = @intCast(self.index),
        },
    };
    return ret;
}

fn parseObject(self: *Parser) !AST.Node(AST.Object) {
    const tentry = self.peek();
    var ret: AST.Node(AST.Object) = .{
        .val = AST.Object{
            .name = undefined,
            .portlist = undefined,
        },
        .tslice = .{
            .start = @intCast(self.index),
            .end = undefined,
        },
    };
    var tuple = false;
    var list = false;
    defer ret.tslice.end = @intCast(self.index - 1);

    switch (tentry.tag) {
        .identifier => {
            ret.val.name = tentry.content.?;
            _ = self.advance();
        },
        .numeric_literal => {
            ret.val.name = AST.number_special_ident;
            const objlist = try self.allocator.alloc(AST.Node(AST.Object), 1);
            objlist[0] = AST.Node(AST.Object){
                .val = AST.Object{
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
        .lbracket => {
            list = true;
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

    if (list) {
        _ = self.advance();
        return self.parseConsList();
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

/// Should be invoked when checking the peeking token, not advanced.
fn expectTag(self: *Parser, expected: Token.Tag, actual: Token.Tag) Error!void {
    if (expected != actual) {
        self.unexpected_token(expected, actual);
        return Error.ErrorDuringParsing;
    }
}

fn parsePairs(self: *Parser) ![]AST.Node(AST.ActivePair) {
    var list = std.ArrayList(AST.Node(AST.ActivePair)).empty;
    if (self.peek().tag == .semicolon or self.peek().tag == .pipe) {
        return list.items;
    }

    objtoken: switch (self.peek().tag) {
        .identifier => {
            const lhs = try self.parseObject();
            const tilde = self.advance();
            try self.expectTag(.tilde, tilde.tag);
            const rhs = try self.parseObject();
            const pair = AST.ActivePair{ .lhs = lhs, .rhs = rhs };
            const tslice = AST.TokenSlice{ .start = lhs.tslice.start, .end = rhs.tslice.end };
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

pub fn parseRule(self: *Parser, lhs: AST.Node(AST.Object)) !AST.Rule {
    var ret = AST.Rule{
        .lhs = lhs,
        .rhs = try self.parseObject(),
        .rule_exprs = undefined,
    };
    const tentry = self.peek().tag;

    var lst = try std.ArrayList(AST.RuleExpression).initCapacity(self.allocator, 1);

    switch (tentry) {
        .fatrightarrow => {
            _ = self.advance();
            const rule_expr: AST.RuleExpression = .{
                .expr = null,
                .pairs = try self.parsePairs(),
            };
            try lst.append(self.allocator, rule_expr);
        },
        .pipe => {
            while (self.peek().tag == .pipe) {
                _ = self.advance();
                const expr = if (self.peek().tag == .keyword_otherwise) blk: {
                    _ = self.advance();
                    break :blk null;
                } else try self.parseExpression(0);
                try self.expectTag(.fatrightarrow, self.advance().tag);
                const rule_expr: AST.RuleExpression = .{
                    .expr = expr,
                    .pairs = try self.parsePairs(),
                };
                try lst.append(self.allocator, rule_expr);
            }
        },
        else => {
            self.err = .{
                .pos = @intCast(self.index),
                .tag = .{ .ExpectedStatement = .{ .found = tentry } },
            };
            return Error.ErrorDuringParsing;
        },
    }
    ret.rule_exprs = try lst.toOwnedSlice(self.allocator);
    return ret;
}

pub fn parseStmt(self: *Parser) !?AST.Node(AST.Statement) {
    const tentry = self.peek();
    var ret: AST.Node(AST.Statement) = .{ .val = undefined, .tslice = .{ .start = @intCast(self.index), .end = undefined } };
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
                    ret.val = .{ .rule = try self.parseRule(lhs) };
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
        .keyword_use => {
            _ = self.advance();
            try self.expectTag(.string_literal, self.peek().tag);
            const str = self.advance();
            ret.val = .{ .use_stmt = str.content.? };
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

pub fn parseProgram(self: *Parser) !AST.Program {
    var list = try std.ArrayList(AST.Node(AST.Statement)).initCapacity(self.allocator, 20);
    var maybe_stmt = try self.parseStmt();
    while (!self.reached_eof) : (maybe_stmt = try self.parseStmt()) {
        if (maybe_stmt) |stmt| {
            try list.append(self.allocator, stmt);
        }
    }
    return .{ .statements = try list.toOwnedSlice(self.allocator) };
}

fn parseNameList(self: *Parser) ![]AST.Name {
    const tentry = self.advance();

    if (tentry.tag != .identifier) {
        self.unexpected_token(.identifier, tentry.tag);
    }
    var list = std.ArrayList(AST.Name).empty;
    try list.append(self.allocator, .{ .val = tentry.content.? });
    while (self.peek().tag == .identifier) {
        const t = self.advance();
        try list.append(self.allocator, .{ .val = t.content.? });
    }
    return list.toOwnedSlice(self.allocator);
}

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
        std.debug.print("{s}\n", .{try err.messageLine(&parser)});
    }

    switch ((try stmt).?.val) {
        .rule => |rule| {
            try std.testing.expectEqualStrings("Add", rule.lhs.val.name);
            try std.testing.expectEqualStrings("S", rule.rhs.val.name);
            try std.testing.expectEqualStrings("y", rule.rhs.val.portlist.?[0].val.name);
            try std.testing.expectEqualStrings("w", rule.rule_exprs[0].pairs[0].val.lhs.val.portlist.?[0].val.name);
            try std.testing.expectEqualStrings("w", rule.rule_exprs[0].pairs[1].val.rhs.val.portlist.?[0].val.name);
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
        std.debug.print("{s}\n", .{try err.messageLine(&parser)});
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
        std.debug.print("{s}\n", .{try err.messageLine(&parser)});
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

// Maybe another way is hidden somewhere in std?
const BufferedStringStream = @import("vm/printing.zig").BufferedStringStream;

fn writeObject(stream: *BufferedStringStream, obj: AST.Object) !void {
    try stream.write("{s}", .{obj.name});
    if (obj.portlist) |portlist| {
        try stream.write("(", .{});
        for (portlist) |port| {
            try writeObject(stream, port.val);
        }
        try stream.write(")", .{});
    }
}

fn toS_Expression_nested(expr: AST.Expression, stream: *BufferedStringStream) !void {
    switch (expr) {
        .atom => |obj| {
            try writeObject(stream, obj.val);
        },
        .binary_op => |binary_op| {
            try stream.write("({s} ", .{binary_op.tag.symbol()});
            try toS_Expression_nested(binary_op.lhs.val, stream);
            try stream.write(" ", .{});
            try toS_Expression_nested(binary_op.rhs.val, stream);
            try stream.write(")", .{});
        },
        .unary_op => {},
    }
}

// Returns a buffer that is bigger than the actual data
fn toS_Expression(gpa: std.mem.Allocator, expr: AST.Expression) ![:0]const u8 {
    const max_buffer_size = 512;
    var stream = try BufferedStringStream.init(gpa, max_buffer_size);
    try toS_Expression_nested(expr, &stream);

    defer gpa.free(stream.buffer);
    return try gpa.dupeSentinel(u8, stream.buffer[0..stream.offset], 0);
}

test "hand-written expr to s-expr" {
    const gpa = std.testing.allocator;

    const a_expr = try gpa.create(AST.Node(AST.Expression));
    defer gpa.destroy(a_expr);
    const b_expr = try gpa.create(AST.Node(AST.Expression));
    defer gpa.destroy(b_expr);

    a_expr.* = .{ .tslice = undefined, .val = .{ .atom = .{ .tslice = undefined, .val = .{ .name = "a", .portlist = null } } } };
    b_expr.* = .{ .tslice = undefined, .val = .{ .atom = .{ .tslice = undefined, .val = .{ .name = "b", .portlist = null } } } };

    const expr = AST.Expression{ .binary_op = .{
        .lhs = a_expr,
        .rhs = b_expr,
        .tag = .eq,
    } };

    const actual = try toS_Expression(gpa, expr);
    defer gpa.free(actual);
    const expected = "(== a b)";
    try std.testing.expectEqualSentinel(u8, 0, expected, actual);
}

test "parsing an expression" {
    const gpa = std.testing.allocator;

    const contents = "a || b == c && d             \n=>";

    const tokens = try Lexer.tokenize(gpa, contents);
    defer gpa.free(tokens);

    var parser = try Parser.init(tokens, gpa);
    defer parser.deinit(gpa);

    const expr = parser.parseExpression(0) catch |err| {
        if (err == Error.ErrorDuringParsing) {
            std.debug.print("{s}\n", .{try parser.err.?.messageLine(&parser)});
        }
        return err;
    };

    const sexpr = try toS_Expression(gpa, expr.val);
    defer gpa.free(sexpr);
    try std.testing.expectEqualSentinel(u8, 0, "(|| a (&& (== b c) d))", sexpr);
}

test "rule with conditionals" {
    var dalloc = std.heap.DebugAllocator(.{}).init;
    defer dalloc.deinitWithoutLeakChecks();
    var arena = std.heap.ArenaAllocator.init(dalloc.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();
    const program =
        \\ Fib(r) >< n
        \\    | n == 0 => r ~ 0
        \\    | n == 1 => r ~ 1
        \\    | otherwise =>
        \\       Dup(n1, n2) ~ n,
        \\       Sub(n', 1) ~ n1,
        \\       Sub(n'', 2) ~ n2,
        \\       Fib(w) ~ n1,
        \\       Fib(w') ~ n2,
        \\       Add(r, w) ~ w';
    ;
    const tokens = try Lexer.tokenize(alloc, program);

    var parser = try Parser.init(tokens, alloc);
    defer parser.deinit(alloc);

    const stmt = parser.parseStmt();
    if (parser.err) |err| {
        std.debug.print("{s}\n", .{try err.messageLine(&parser)});
    }

    switch ((try stmt).?.val) {
        .rule => |rule| {
            try std.testing.expectEqualSentinel(u8, 0, "(== n #number(0))", try toS_Expression(alloc, rule.rule_exprs[0].expr.?.val));
            try std.testing.expectEqualStrings("r", rule.rule_exprs[1].pairs[0].val.lhs.val.name);
        },
        else => unreachable,
    }
}

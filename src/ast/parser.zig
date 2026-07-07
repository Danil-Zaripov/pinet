//! Struct containing parser implementation.
//! It owns all the ast nodes created inside its arena.
const std = @import("std");
const Lexer = @import("lexer.zig");
const AST = @import("ast.zig");

const Token = Lexer.Token;

pub const Parser = @This();

const Printing = @import("printing");

/// Basically a diagnostic tool. Has context of the error in case
/// Error.ErrorDuringParsing is returned.
pub const ParserError = struct {
    token: Token,
    tag: Tag,

    const Tag = union(enum) {
        unexpected_eof: void,
        expected_object: void,
        expected_statement: void,
        expected_expression: void,
        unexpected_token: struct { expected: Token.Tag },
    };

    pub fn message(self: *const ParserError, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self.tag) {
            .unexpected_eof => "Unexpected end of file",
            .expected_object => try std.fmt.allocPrint(alloc, "Expected object, found token: {s}", .{self.token.tag.symbol()}),
            .expected_statement => try std.fmt.allocPrint(alloc, "Expected statement, found token: {s}", .{self.token.tag.symbol()}),
            .expected_expression => try std.fmt.allocPrint(alloc, "Expected expression, found token: {s}", .{self.token.tag.symbol()}),
            .unexpected_token => |val| try std.fmt.allocPrint(alloc, "Expected {s}, found {s}", .{ val.expected.symbol(), self.token.tag.symbol() }),
        };
    }

    pub fn getPrettyLine(self: *const ParserError, parser: *Parser, file: [:0]const u8) !struct { []const u8, []const u8 } {
        const token = self.token;
        const line = token.loc.start.line;

        var lines = try Printing.Lines.init(parser.intermediate_list_allocator, file);
        defer lines.deinit();

        const marker_line = try parser.arena.alloc(u8, token.loc.end.ch);
        @memset(marker_line, ' ');

        marker_line[token.loc.start.ch] = '^';
        for (token.loc.start.ch + 1..token.loc.end.ch) |idx| {
            marker_line[idx] = '~';
        }

        return .{
            lines.lines[line],
            marker_line,
        };
    }

    /// Parser's arena owns the message.
    pub fn messageLine(self: *const ParserError, parser: *Parser) ![]const u8 {
        const loc = self.token.loc.start;
        const msg = try self.message(parser.arena);
        defer parser.arena.free(msg);

        return std.fmt.allocPrint(parser.arena, "Syntax error on line {} index {}: {s}", .{ loc.line + 1, loc.ch + 1, msg });
    }
};

pub const Error = error{
    ErrorDuringParsing,
};

tokens: []const Token,
index: usize,
_arena: *std.heap.ArenaAllocator,
/// Arena should not be used for containing intermediate
/// lists. Use gpa for intermediate, then remap the date with arena.
arena: std.mem.Allocator,
/// Should not be used to allocate nodes. Only for intermediate lists
/// (performance reasons).
intermediate_list_allocator: std.mem.Allocator,
err: ?ParserError,

reached_eof: bool,

/// Page allocator is preferred for the arenas. Gpa is used to create the arena in the
/// heap and as a intermediate_list_allocator for performance.
pub fn init(tokens: []const Token, gpa: std.mem.Allocator, page: std.mem.Allocator) !Parser {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(page);
    return .{
        .tokens = tokens,
        .index = 0,
        ._arena = arena,
        .arena = arena.allocator(),
        .intermediate_list_allocator = gpa,
        .reached_eof = false,
        .err = null,
    };
}

fn unexpected_token(self: *Parser, expected: Token.Tag, actual: *const Token) void {
    self.err = .{
        .tag = .{ .unexpected_token = .{ .expected = expected } },
        .token = actual.*,
    };
}

pub fn deinit(self: *Parser, gpa: std.mem.Allocator) void {
    self._arena.deinit();
    gpa.destroy(self._arena);
}

fn peek(self: *Parser) Token {
    return self.tokens[self.index];
}

fn advance(self: *Parser) Token {
    self.index += 1;
    return self.tokens[self.index - 1];
}

fn getTokenInfixBP(self: *Parser, token: *const Token) !struct { i32, i32 } {
    return switch (token.tag) {
        .logic_or => .{ 10, 11 },
        .logic_and => .{ 20, 21 },
        .eq => .{ 30, 31 },
        .greater, .geq, .less, .leq => .{ 40, 41 },
        else => {
            self.err = .{
                .token = token.*,
                .tag = .expected_expression,
            };
            return Error.ErrorDuringParsing;
        },
    };
}

fn parseUnary(self: *Parser) !*AST.Node(AST.Expression) {
    const expr = try self.arena.create(AST.Node(AST.Expression));
    expr.tslice.start = @intCast(self.index);
    expr.val = switch (self.peek().tag) {
        .exclamation_mark => AST.Expression{ .unary_op = .{ .tag = .not, .item = try self.parseUnary() } },
        else => AST.Expression{ .atom = try self.parseObject() },
    };
    expr.tslice.end = @intCast(self.index - 1);
    return expr;
}

fn parseExpression(self: *Parser, min_bp: i32) !*AST.Node(AST.Expression) {
    var lhs = try self.parseUnary();
    while (true) {
        const token = self.peek();
        const op: AST.Expression.BinaryExpr.Tag = switch (token.tag) {
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
                    .token = self.peek(),
                    .tag = .expected_expression,
                };
                return Error.ErrorDuringParsing;
            },
        };

        const lbp, const rbp = try self.getTokenInfixBP(&token);
        if (lbp < min_bp) {
            break;
        }
        _ = self.advance();
        const rhs = try self.parseExpression(rbp);
        const new_lhs = try self.arena.create(AST.Node(AST.Expression));
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

fn parseObjList(self: *Parser) error{ NoSpaceLeft, OutOfMemory, ErrorDuringParsing, TupleTooBig }![]AST.Node(AST.Object) {
    var list = std.ArrayList(AST.Node(AST.Object)).empty;
    errdefer list.deinit(self.intermediate_list_allocator);

    while (self.peek().tag != .rparen) {
        switch (self.peek().tag) {
            .identifier, .lparen, .numeric_literal => {
                const obj = try self.parseObject();
                try list.append(self.intermediate_list_allocator, obj);
                if (self.peek().tag == .comma) {
                    _ = self.advance();
                } else if (self.peek().tag != .rparen) {
                    self.err = .{
                        .token = self.peek(),
                        .tag = .expected_object,
                    };
                    return Error.ErrorDuringParsing;
                }
            },
            else => {
                self.err = .{
                    .token = self.peek(),
                    .tag = .expected_object,
                };
                return Error.ErrorDuringParsing;
            },
        }
    }
    const owned = try list.toOwnedSlice(self.intermediate_list_allocator);
    defer self.intermediate_list_allocator.free(owned);
    const result = try self.arena.dupe(AST.Node(AST.Object), owned);
    return result;
}

fn parseConsList(self: *Parser) error{ NoSpaceLeft, OutOfMemory, ErrorDuringParsing, TupleTooBig }!AST.Node(AST.Object) {
    const cons_arity = 2;

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

    tslice_end: {
        if (tentry.tag == .rbracket) {
            ret.val.name = AST.nil_list_ident;
            ret.val.portlist = &.{};
            _ = self.advance();
            break :tslice_end;
        }
        ret.val = .{
            .name = AST.cons_list_ident,
            .portlist = try self.arena.alloc(AST.Node(AST.Object), cons_arity),
        };
        ret.val.portlist.?[0] = try self.parseObject();
        var node = ret;
        while (self.peek().tag == .comma) {
            _ = self.advance();
            var new_node: AST.Node(AST.Object) = .{
                .val = AST.Object{
                    .name = AST.cons_list_ident,
                    .portlist = try self.arena.alloc(AST.Node(AST.Object), cons_arity),
                },
                .tslice = .{
                    .start = @intCast(self.index),
                    .end = undefined,
                },
            };
            new_node.val.portlist.?[0] = try self.parseObject();
            node.val.portlist.?[1] = new_node;
            new_node.tslice.end = @intCast(self.index);
            node = new_node;
        }
        try self.expectTag(.rbracket, &self.advance());
        node.val.portlist.?[1] = AST.Node(AST.Object){
            .val = .{
                .name = AST.nil_list_ident,
                .portlist = &.{},
            },
            .tslice = .{
                .start = @intCast(self.index),
                .end = @intCast(self.index),
            },
        };
    }
    ret.tslice.end = @intCast(self.index - 1);
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

    // that's bad! But it is somewhat necessary for the tslice to be consistent.
    ret_blk: {
        switch (tentry.tag) {
            .identifier => {
                ret.val.name = tentry.content.?;
                _ = self.advance();
            },
            .numeric_literal => {
                ret.val.name = AST.number_special_ident;
                const objlist = try self.arena.alloc(AST.Node(AST.Object), 1);
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
                // only here!
                break :ret_blk;
            },
            .lbracket => {
                list = true;
            },
            .lparen => {
                tuple = true;
            },
            else => {
                self.err = ParserError{
                    .tag = .expected_object,
                    .token = tentry,
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
                try self.expectTag(.rparen, &closing);
            },
            else => {
                ret.val.portlist = null;
            },
        }

        if (tuple) {
            ret.val.name = try self.getTupleName(ret.val.portlist.?.len);
        }
    }
    ret.tslice.end = @intCast(self.index - 1);
    return ret;
}

fn getTupleName(self: *Parser, size: usize) ![]const u8 {
    _ = self;
    const max_tuple: usize = 10;
    const kvs = comptime kvs: {
        var list: [max_tuple + 1][]const u8 = undefined;
        for (&list, 0..) |*val, idx| {
            val.* = std.fmt.comptimePrint("Tuple{}", .{idx});
        }
        break :kvs list;
    };
    return if (size < max_tuple + 1) kvs[size] else error.TupleTooBig;
}

/// Should be invoked when checking the peeking token, not advanced.
fn expectTag(self: *Parser, expected: Token.Tag, actual: *const Token) Error!void {
    if (expected != actual.tag) {
        self.unexpected_token(expected, actual);
        return Error.ErrorDuringParsing;
    }
}

fn parsePairs(self: *Parser) ![]AST.Node(AST.ActivePair) {
    var list = std.ArrayList(AST.Node(AST.ActivePair)).empty;
    errdefer list.deinit(self.intermediate_list_allocator);
    if (self.peek().tag == .semicolon or self.peek().tag == .pipe) {
        return &.{};
    }

    objtoken: switch (self.peek().tag) {
        .identifier => {
            const lhs = try self.parseObject();
            const tilde = self.advance();
            try self.expectTag(.tilde, &tilde);
            const rhs = try self.parseObject();
            const pair = AST.ActivePair{ .lhs = lhs, .rhs = rhs };
            const tslice = AST.TokenSlice{ .start = lhs.tslice.start, .end = rhs.tslice.end };
            try list.append(self.intermediate_list_allocator, .{ .val = pair, .tslice = tslice });
            if (self.peek().tag == .comma) {
                _ = self.advance();
                continue :objtoken self.peek().tag;
            }
        },
        else => {
            self.unexpected_token(.identifier, &self.peek());
            return Error.ErrorDuringParsing;
        },
    }
    const owned = try list.toOwnedSlice(self.intermediate_list_allocator);
    defer self.intermediate_list_allocator.free(owned);
    const result = try self.arena.dupe(AST.Node(AST.ActivePair), owned);
    return result;
}

pub fn parseRule(self: *Parser, lhs: AST.Node(AST.Object)) !AST.Rule {
    var ret = AST.Rule{
        .lhs = lhs,
        .rhs = try self.parseObject(),
        .rule_exprs = undefined,
    };
    const tentry = self.peek().tag;

    var list = try std.ArrayList(AST.RuleExpression).initCapacity(self.intermediate_list_allocator, 1);
    errdefer list.deinit(self.intermediate_list_allocator);

    switch (tentry) {
        .fatrightarrow => {
            _ = self.advance();
            const rule_expr: AST.RuleExpression = .{
                .expr = null,
                .pairs = try self.parsePairs(),
            };
            try list.append(self.intermediate_list_allocator, rule_expr);
        },
        .pipe => {
            while (self.peek().tag == .pipe) {
                _ = self.advance();
                const expr = if (self.peek().tag == .keyword_otherwise) blk: {
                    _ = self.advance();
                    break :blk null;
                } else try self.parseExpression(0);
                try self.expectTag(.fatrightarrow, &self.advance());
                const rule_expr: AST.RuleExpression = .{
                    .expr = expr,
                    .pairs = try self.parsePairs(),
                };
                try list.append(self.intermediate_list_allocator, rule_expr);
            }
        },
        else => {
            self.err = .{
                .token = self.peek(),
                .tag = .expected_statement,
            };
            return Error.ErrorDuringParsing;
        },
    }
    const owned = try list.toOwnedSlice(self.intermediate_list_allocator);
    defer self.intermediate_list_allocator.free(owned);
    const result = try self.arena.dupe(AST.RuleExpression, owned);
    ret.rule_exprs = result;
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
                    self.err = .{
                        .token = self.peek(),
                        .tag = .expected_statement,
                    };
                    return Error.ErrorDuringParsing;
                },
            }
        },
        .keyword_use => {
            _ = self.advance();
            try self.expectTag(.string_literal, &self.peek());
            const str = self.advance();
            ret.val = .{ .use_stmt = str.content.? };
        },
        else => {
            self.err = .{
                .token = self.peek(),
                .tag = .expected_statement,
            };
            return Error.ErrorDuringParsing;
        },
    }
    try self.expectTag(.semicolon, &self.advance());
    if (self.err != null) {
        unreachable;
    }

    ret.tslice.end = @intCast(self.index - 1);
    return ret;
}

pub fn parseProgram(self: *Parser) !AST.Program {
    var list = std.ArrayList(AST.Node(AST.Statement)).empty;
    errdefer list.deinit(self.intermediate_list_allocator);

    var maybe_stmt = try self.parseStmt();
    while (!self.reached_eof) : (maybe_stmt = try self.parseStmt()) {
        if (maybe_stmt) |stmt| {
            try list.append(self.intermediate_list_allocator, stmt);
        }
    }
    const owned = try list.toOwnedSlice(self.intermediate_list_allocator);
    defer self.intermediate_list_allocator.free(owned);
    const result = try self.arena.dupe(AST.Node(AST.Statement), owned);
    return .{ .statements = result };
}

fn parseNameList(self: *Parser) ![]AST.Name {
    const tentry = self.advance();

    if (tentry.tag != .identifier) {
        self.unexpected_token(.identifier, &tentry);
    }
    var list = std.ArrayList(AST.Name).empty;
    errdefer list.deinit(self.intermediate_list_allocator);

    try list.append(self.intermediate_list_allocator, .{ .val = tentry.content.? });
    while (self.peek().tag == .identifier) {
        const t = self.advance();
        try list.append(self.intermediate_list_allocator, .{ .val = t.content.? });
    }
    const owned = try list.toOwnedSlice(self.intermediate_list_allocator);
    defer self.intermediate_list_allocator.free(owned);
    const result = try self.arena.dupe(AST.Name, owned);
    return result;
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

    var parser = try Parser.init(tokens, alloc, alloc);
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

    var parser = try Parser.init(tokens, alloc, alloc);
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

    var parser = try Parser.init(tokens, alloc, alloc);
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

const BufferedStringStream = Printing.BufferedStringStream;

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

    var parser = try Parser.init(tokens, gpa, gpa);
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

    var parser = try Parser.init(tokens, alloc, alloc);
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

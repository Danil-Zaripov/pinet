//! Module that encapsulates compiling conditions into a stream of condition instructions.
//! Conditions are not a part of interaction nets, but rather a heuristic mechanism.
//! They may fail even when the interaction net is valid, therefore we need some better way to abstract that.
//! But for now this will do.

const std = @import("std");

const Scope = @import("scope.zig");
const AST = @import("ast");
const Types = @import("shared_runtime").Types;

const Agent = Types.Agent;
const Special = Types.Special;
const Name = Types.Name;
const Value = Types.Value;
const Equation = Types.Equation;

const Register = struct {
    const Id = usize;
    const CondValue = union(enum) {
        bool: bool,
        special: Special,
    };
};

const ConditionScope = struct {};

const Op = struct {
    const Binary = AST.Expression.BinaryExpr.Tag;
    const Unary = AST.Expression.UnaryExpr.Tag;
};

const Instruction = struct {
    /// lhs is used as the main argument in unary operations
    lhs: Register.Id = undefined,
    rhs: Register.Id = undefined,
    result: Register.Id = undefined,
    tag: Tag,

    const Tag = union(enum) {
        assert_id: Types.Agent.Id,
        apply_bin: Op.Binary,
        apply_un: Op.Unary,
    };
};

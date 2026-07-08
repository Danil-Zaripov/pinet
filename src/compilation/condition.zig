//! Module that encapsulates compiling conditions into a stream of condition instructions.
//! Conditions are not a part of interaction nets, but rather a heuristic mechanism.
//! They may fail even when the interaction net is valid, therefore we need some better way to abstract that.
//! But for now this will do.

const std = @import("std");

const Scope = @import("scope.zig");
const Types = @import("shared_runtime").Types;

const Agent = Types.Agent;
const Special = Types.Special;
const Name = Types.Name;
const Value = Types.Value;
const Equation = Types.Equation;

const Instruction = union(enum) {};

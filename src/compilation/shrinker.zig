const std = @import("std");

const Instruction = @import("instruction.zig");
const Condition = @import("condition.zig");

pub const Bytecode = packed struct(u64) {
    opcode: Opcode = undefined,
    src: u8 = undefined,
    dest: u8 = undefined,
    _unused: u8 = undefined,

    val: packed union {
        id: u32,
        integer: i32,
        float: f32,
        binary_operation: packed struct {
            additional_argument: u8,
            fallback: i16,
            tag: Condition.Op.Binary,
        },
        unary_operation: packed struct {
            fallback: i24,
            tag: Condition.Op.Unary,
        },
    } = undefined,

    pub const Opcode = enum(u8) {
        begin_block,
        end_block,
        o_return,

        load_arguments,
        mk_agent,
        mk_name,
        mk_special_float,
        mk_special_integer,
        push,
        load_port,

        // conditions
        c_load_port_lhs,
        c_load_port_rhs,
        c_load_wildcard_rhs,
        c_assert_id,
        c_put_special_float,
        c_put_special_integer,
        c_get_special,
        c_apply_bin,
        c_apply_un,

        /// Jump if condition is not met.
        c_njump,
    };
};

pub fn shrinkInstructions(gpa: std.mem.Allocator, rules: []Instruction.ConditionedRule) ![]Bytecode {
    var list = std.ArrayList(Bytecode).empty;
    try list.append(gpa, .{ .opcode = .load_arguments });

    for (rules) |rule| {
        const maybe_cond = rule.condition;
        const instrs = rule.instructions;
        try list.append(gpa, .{ .opcode = .begin_block });

        if (maybe_cond) |cond_instrs| {
            for (cond_instrs) |instr| {
                var shrinked: Bytecode = .{};
                switch (instr.tag) {
                    .put_port => |port| {
                        shrinked.dest = instr.result;
                        if (port.owner == .lhs) {
                            shrinked.opcode = .c_load_port_lhs;
                            shrinked.src = port.idx.?;
                        } else if (port.owner == .rhs) {
                            if (port.idx) |idx| {
                                shrinked.opcode = .c_load_port_rhs;
                                shrinked.src = idx;
                            } else {
                                shrinked.opcode = .c_load_wildcard_rhs;
                            }
                        }
                    },
                    .assert_id => |id| {
                        shrinked.opcode = .c_assert_id;
                        shrinked.src = @intCast(id);
                        shrinked.dest = instr.result;
                    },
                    .put_constant => |special| {
                        shrinked.dest = instr.result;
                        switch (special) {
                            .float => |float| {
                                shrinked.opcode = .c_put_special_float;
                                shrinked.val = .{ .float = float };
                            },
                            .integer => |integer| {
                                shrinked.opcode = .c_put_special_integer;
                                shrinked.val = .{ .integer = integer };
                            },
                        }
                    },
                    .get_special => {
                        shrinked.src = instr.lhs;
                        shrinked.dest = instr.result;
                        shrinked.opcode = .c_get_special;
                    },
                    .apply_bin => |binary| {
                        shrinked.src = instr.lhs;
                        shrinked.dest = instr.result;
                        shrinked.opcode = .c_apply_bin;
                        shrinked.val = .{ .binary_operation = .{
                            .tag = binary,
                            .additional_argument = instr.rhs,
                            .fallback = undefined,
                        } };
                    },
                    .apply_un => |unary| {
                        shrinked.src = instr.lhs;
                        shrinked.dest = instr.result;
                        shrinked.opcode = .c_apply_un;
                        shrinked.val = .{ .unary_operation = .{
                            .tag = unary,
                            .fallback = undefined,
                        } };
                    },
                    .get_result => {
                        shrinked.dest = instr.result;
                        shrinked.opcode = .c_njump;
                        shrinked.val = .{ .integer = -1 };
                    },
                }

                try list.append(gpa, shrinked);
            }
        }

        for (instrs) |instr| {
            var shrinked: Bytecode = .{
                .opcode = undefined,
                .src = undefined,
                .dest = undefined,
                .val = undefined,
            };

            switch (instr.tag) {
                .load_arguments => {
                    continue;
                },
                .mk_agent => |agent_id| {
                    shrinked.opcode = .mk_agent;
                    shrinked.dest = instr.operand1;
                    shrinked.val = .{ .id = agent_id };
                },
                .mk_special => |special| {
                    switch (special) {
                        .float => |float| {
                            shrinked.opcode = .mk_special_float;
                            shrinked.dest = instr.operand1;
                            shrinked.val = .{ .float = float };
                        },
                        .integer => |integer| {
                            shrinked.opcode = .mk_special_integer;
                            shrinked.dest = instr.operand1;
                            shrinked.val = .{ .integer = integer };
                        },
                    }
                },
                .mk_name => {
                    shrinked.opcode = .mk_name;
                    shrinked.dest = instr.operand1;
                },
                .push => {
                    shrinked.opcode = .push;
                    shrinked.src = instr.operand1;
                    shrinked.dest = instr.operand2;
                },
                .put_into_port => |port| {
                    shrinked.opcode = .load_port;
                    shrinked.src = instr.operand1;
                    shrinked.dest = instr.operand2;
                    shrinked.val = .{ .id = port };
                },
            }
            try list.append(gpa, shrinked);
        }
        try list.append(gpa, .{ .opcode = .end_block });
    }

    try list.append(gpa, .{ .opcode = .o_return });
    // fallbacks:
    {
        var idx: i32 = @as(i32, @intCast(list.items.len)) - 1;
        // -1 means there is no fallback and we fail the function
        var last_fallback: i32 = -1;
        while (idx >= 0) : (idx -= 1) {
            const instr = &list.items[@intCast(idx)];
            switch (instr.opcode) {
                .begin_block => last_fallback = idx,

                .c_load_port_lhs,
                .c_load_port_rhs,
                .c_load_wildcard_rhs,
                .c_njump,
                .c_assert_id,
                => instr.val = .{ .integer = last_fallback },
                .c_apply_bin => instr.val.binary_operation.fallback = @intCast(last_fallback),
                .c_apply_un => instr.val.unary_operation.fallback = @intCast(last_fallback),
                else => {},
            }
        }
    }

    return try list.toOwnedSlice(gpa);
}

const std = @import("std");

const Instruction = @import("instruction.zig");

pub const Bytecode = packed struct(u64) {
    opcode: Opcode,
    src: u8,
    dest: u8,

    val: packed union {
        id: u32,
        integer: i32,
        float: f32,
    },

    _unused: u8 = undefined,

    pub const Opcode = enum(u8) {
        load_arguments,
        mk_agent,
        mk_name,
        mk_special_float,
        mk_special_integer,
        push,
        load_port,
    };
};

pub fn shrinkInstructions(gpa: std.mem.Allocator, instrs: []Instruction) ![]Bytecode {
    var list = std.ArrayList(Bytecode).empty;
    for (instrs) |instr| {
        var shrinked: Bytecode = .{
            .opcode = undefined,
            .src = undefined,
            .dest = undefined,
            .val = undefined,
        };

        switch (instr.tag) {
            .load_arguments => {
                shrinked.opcode = .load_arguments;
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
    return try list.toOwnedSlice(gpa);
}

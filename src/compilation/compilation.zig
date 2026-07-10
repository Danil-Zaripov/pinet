const std = @import("std");

pub const Instruction = @import("instruction.zig");
pub const Condition = @import("condition.zig");

const Types = @import("shared_runtime").Types;

pub fn getNumberType(str: []const u8) !Types.Special {
    const contains = struct {
        pub fn contains(s: []const u8, selected: u8) bool {
            for (s) |char| {
                if (char == selected) return true;
            }
            return false;
        }
    }.contains;

    if (contains(str, '.')) {
        return Types.Special{ .float = try std.fmt.parseFloat(f32, str) };
    } else {
        return Types.Special{ .integer = try std.fmt.parseInt(i32, str, 10) };
    }
}

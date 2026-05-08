const std = @import("std");

pub const answer: u32 = 42;

pub fn greet() void {
    std.debug.print("hello\n", .{});
}

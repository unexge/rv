const std = @import("std");
const treez = @import("treez");
const rv = @import("rv");
const Io = std.Io;

pub fn main() !void {
    const ziglang = try treez.Language.get("zig");

    var parser = try treez.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(ziglang);

    const allocator = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const source = try std.Io.Dir.cwd().readFileAlloc(io, "build.zig", allocator, .unlimited);
    defer allocator.free(source);

    const tree = try parser.parseString(null, source);
    defer tree.destroy();

    printTree(tree.getRootNode(), source, 0);
}

fn printTree(node: treez.Node, source: []const u8, depth: usize) void {
    for (0..depth) |_| std.debug.print("  ", .{});
    std.debug.print("{s} [{d}..{d}]", .{
        node.getType(),
        node.getStartByte(),
        node.getEndByte(),
    });

    const n = node.getNamedChildCount();
    if (n == 0) {
        std.debug.print(" ", .{});
        printLeafText(source[node.getStartByte()..node.getEndByte()]);
    }
    std.debug.print("\n", .{});

    var i: u32 = 0;
    while (i < n) : (i += 1) printTree(node.getNamedChild(i), source, depth + 1);
}

fn printLeafText(text: []const u8) void {
    const max_len = 60;
    std.debug.print("\"", .{});
    var count: usize = 0;
    for (text) |c| {
        if (count >= max_len) {
            std.debug.print("...", .{});
            break;
        }
        switch (c) {
            '\n' => std.debug.print("\\n", .{}),
            '\r' => std.debug.print("\\r", .{}),
            '\t' => std.debug.print("\\t", .{}),
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            else => std.debug.print("{c}", .{c}),
        }
        count += 1;
    }
    std.debug.print("\"", .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}

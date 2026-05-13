//! Entry point: parse two source files, run the diff engine, render the
//! structured result in a libvaxis TUI. See `src/ui/app.zig` for rendering.

const std = @import("std");
const rv = @import("rv");

const ui = @import("ui/app.zig");

// Ensure the ui module's inline tests are visible to `zig build test`.
comptime {
    _ = @import("ui/line.zig");
    _ = @import("ui/state.zig");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // skip argv[0]

    const before_path = args.next() orelse return usage();
    const after_path = args.next() orelse return usage();

    const lang = rv.languageFromPath(before_path) orelse {
        std.debug.print("rv: unknown language for path '{s}'\n", .{before_path});
        return error.UnknownLanguage;
    };

    const before = try std.Io.Dir.cwd().readFileAlloc(io, before_path, gpa, .unlimited);
    defer gpa.free(before);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, after_path, gpa, .unlimited);
    defer gpa.free(after);

    var diff = try rv.diffSources(gpa, lang, before, after);
    defer diff.deinit();

    try ui.run(gpa, io, init.environ_map, &diff, before_path, after_path);
}

fn usage() error{BadUsage} {
    std.debug.print("usage: rv <before> <after>\n", .{});
    return error.BadUsage;
}

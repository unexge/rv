//! Entry point.
//!
//! - `rv`                 → repo mode: sidebar + diff pane over `git diff`.
//! - `rv <before> <after>`→ path mode: diff two files directly (see `src/ui/app.zig`).

const std = @import("std");
const rv = @import("rv");

const ui = @import("ui/app.zig");
const session_mod = @import("ui/session.zig");

// Ensure the ui + vcs modules' inline tests are visible to `zig build test`.
comptime {
    _ = @import("ui/app.zig");
    _ = @import("ui/file_list.zig");
    _ = @import("ui/hunk.zig");
    _ = @import("ui/line.zig");
    _ = @import("ui/search.zig");
    _ = @import("ui/session.zig");
    _ = @import("ui/state.zig");
    _ = @import("ui/theme.zig");
    _ = @import("vcs/mod.zig");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // skip argv[0]

    const first = args.next();
    const second = args.next();

    if (first == null) {
        return runRepoMode(gpa, io, init.environ_map);
    }
    if (second == null) return usage();
    if (args.next() != null) return usage();

    return runPathMode(gpa, io, init.environ_map, first.?, second.?);
}

fn runRepoMode(
    gpa: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
) !void {
    var session = session_mod.Session.init(gpa, io) catch |err| switch (err) {
        error.NotARepository => {
            std.debug.print("rv: not inside a git repository\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer session.deinit();

    if (session.entries.len == 0) {
        std.debug.print("no changes\n", .{});
        return;
    }

    try session_mod.run(gpa, io, env_map, &session);
}

fn runPathMode(
    gpa: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    before_path: []const u8,
    after_path: []const u8,
) !void {
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

    try ui.run(gpa, io, env_map, &diff, before_path, after_path);
}

fn usage() error{BadUsage} {
    std.debug.print(
        \\usage: rv                   run inside a git repo for sidebar + diff pane
        \\       rv <before> <after>  diff two files directly
        \\
    , .{});
    return error.BadUsage;
}

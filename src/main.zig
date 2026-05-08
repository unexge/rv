//! Minimal demo of the rv diff engine.
//!
//! Usage: rv <before> <after>
//!
//! Language is inferred from the first path's extension. Prints a one-line
//! header plus a tree view of the structured diff to stderr. See
//! `src/root.zig` for the full public API surface.

const std = @import("std");
const rv = @import("rv");

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

    printSummary(&diff);
}

fn usage() error{BadUsage} {
    std.debug.print("usage: rv <before> <after>\n", .{});
    return error.BadUsage;
}

fn printSummary(diff: *const rv.FileDiff) void {
    std.debug.print("rv: {d} top-level entries, {d} parse errors\n", .{
        diff.entries.len,
        diff.parse_errors.len,
    });
    printEntries(diff.entries, 0);
}

fn printEntries(entries: []const rv.DeclDiff, depth: usize) void {
    for (entries) |entry| {
        indent(depth);
        switch (entry) {
            .unchanged => |u| {
                if (u.moved) |m| {
                    std.debug.print("= {s} (moved {d} -> {d})\n", .{
                        u.decl.name orelse "<anon>",
                        m.from_idx,
                        m.to_idx,
                    });
                } else {
                    std.debug.print("= {s}\n", .{u.decl.name orelse "<anon>"});
                }
            },
            .added => |a| {
                std.debug.print("+ {s}\n", .{a.decl.name orelse "<anon>"});
            },
            .removed => |r| {
                std.debug.print("- {s}\n", .{r.decl.name orelse "<anon>"});
            },
            .changed => |c| {
                const move_tag: []const u8 = if (c.moved != null) " (moved)" else "";
                std.debug.print("~ {s}{s}\n", .{ c.new.name orelse "<anon>", move_tag });
                switch (c.body) {
                    .leaf => |script| {
                        indent(depth + 1);
                        if (script.isCommentOnly()) {
                            std.debug.print("(comment-only, {d} edits, cost {d})\n", .{ script.edits.len, script.total_cost });
                        } else {
                            std.debug.print("({d} edits, cost {d})\n", .{ script.edits.len, script.total_cost });
                        }
                    },
                    .container => |children| printEntries(children, depth + 1),
                }
            },
        }
    }
}

fn indent(depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) std.debug.print("  ", .{});
}

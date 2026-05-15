//! Decl-level English summary for the diff-pane header.
//!
//! Shared by `session.zig` (modified-file header for repo mode and the
//! existing whole-file `.added` / `.removed` summary panes) and
//! `app.zig` (path mode header). Lives in its own module so both
//! callers can import without forming a cycle.
//!
//! Output shape:
//!
//!   `"2 fns added, 1 fn modified, 1 const removed"`
//!
//! Empty per-direction categories collapse out. A file with only
//! unchanged decls falls back to `"no decl-level changes"`.

const std = @import("std");

const rv = @import("rv");

const Allocator = std.mem.Allocator;

pub const SummaryDirection = enum { added, removed, modified };

/// Counts of top-level `DeclDiff` entries grouped by `Decl.kind`.
/// Only the three most common kinds get their own slot; everything else
/// (imports, test cases, containers, language-specific `other`) is
/// folded into `other`.
pub const DeclKindCounts = struct {
    function: u32 = 0,
    binding: u32 = 0,
    type_alias: u32 = 0,
    other: u32 = 0,

    pub fn isEmpty(self: DeclKindCounts) bool {
        return self.function == 0 and self.binding == 0 and
            self.type_alias == 0 and self.other == 0;
    }
};

/// Walk top-level `DeclDiff` entries and tally them by `Decl.kind`.
/// Only entries matching `direction` contribute: `.added` counts
/// `.added` variants, `.removed` counts `.removed` variants,
/// `.modified` counts `.changed` variants (using the right-side decl).
/// Nested containers aren't recursed - the summary reflects the
/// file-level change, not a full decl tree.
pub fn countDeclKinds(
    entries: []const rv.DeclDiff,
    direction: SummaryDirection,
) DeclKindCounts {
    var c: DeclKindCounts = .{};
    for (entries) |e| {
        const decl: ?rv.Decl = switch (e) {
            .added => |a| if (direction == .added) a.decl else null,
            .removed => |r| if (direction == .removed) r.decl else null,
            .changed => |ch| if (direction == .modified) ch.new else null,
            .unchanged => null,
        };
        const d = decl orelse continue;
        switch (d.kind) {
            .function => c.function += 1,
            .binding => c.binding += 1,
            .type_alias => c.type_alias += 1,
            else => c.other += 1,
        }
    }
    return c;
}

/// Format a count string like `"3 fns, 2 consts added"` or
/// `"1 type removed"`. Zero-count categories are collapsed; if every
/// category is zero (e.g. an added file with no recognised decls) the
/// output falls back to just the direction word
/// (`"added"` / `"removed"` / `"modified"`).
pub fn formatSummaryHeader(
    arena: Allocator,
    counts: DeclKindCounts,
    direction: SummaryDirection,
) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;

    const entries = [_]struct { count: u32, singular: []const u8, plural: []const u8 }{
        .{ .count = counts.function, .singular = "fn", .plural = "fns" },
        .{ .count = counts.binding, .singular = "const", .plural = "consts" },
        .{ .count = counts.type_alias, .singular = "type", .plural = "types" },
        .{ .count = counts.other, .singular = "other", .plural = "others" },
    };
    for (entries) |e| {
        if (e.count == 0) continue;
        const word = if (e.count == 1) e.singular else e.plural;
        try parts.append(arena, try std.fmt.allocPrint(arena, "{d} {s}", .{ e.count, word }));
    }

    const dir_word: []const u8 = switch (direction) {
        .added => "added",
        .removed => "removed",
        .modified => "modified",
    };

    if (parts.items.len == 0) return arena.dupe(u8, dir_word);

    const joined = try std.mem.join(arena, ", ", parts.items);
    return std.fmt.allocPrint(arena, "{s} {s}", .{ joined, dir_word });
}

/// English summary for a modified file's diff-pane header. Combines the
/// per-direction kind counts: `"2 fns added, 1 fn modified, 1 const
/// removed"`. Empty categories collapse out. A file with only unchanged
/// decls falls back to `"no decl-level changes"`.
pub fn formatModifiedHeader(arena: Allocator, entries: []const rv.DeclDiff) ![]const u8 {
    const added_counts = countDeclKinds(entries, .added);
    const modified_counts = countDeclKinds(entries, .modified);
    const removed_counts = countDeclKinds(entries, .removed);

    if (added_counts.isEmpty() and modified_counts.isEmpty() and removed_counts.isEmpty()) {
        return arena.dupe(u8, "no decl-level changes");
    }

    var parts: std.ArrayList([]const u8) = .empty;
    if (!added_counts.isEmpty()) {
        try parts.append(arena, try formatSummaryHeader(arena, added_counts, .added));
    }
    if (!modified_counts.isEmpty()) {
        try parts.append(arena, try formatSummaryHeader(arena, modified_counts, .modified));
    }
    if (!removed_counts.isEmpty()) {
        try parts.append(arena, try formatSummaryHeader(arena, removed_counts, .removed));
    }
    return std.mem.join(arena, ", ", parts.items);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "formatSummaryHeader: plural and singular words, comma separated" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "3 fns, 2 consts added",
        try formatSummaryHeader(a, .{ .function = 3, .binding = 2 }, .added),
    );
    try testing.expectEqualStrings(
        "1 type removed",
        try formatSummaryHeader(a, .{ .type_alias = 1 }, .removed),
    );
    try testing.expectEqualStrings(
        "1 fn, 1 const, 1 type added",
        try formatSummaryHeader(
            a,
            .{ .function = 1, .binding = 1, .type_alias = 1 },
            .added,
        ),
    );
    try testing.expectEqualStrings(
        "2 fns modified",
        try formatSummaryHeader(a, .{ .function = 2 }, .modified),
    );
}

test "formatSummaryHeader: zero-count categories are omitted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "5 others added",
        try formatSummaryHeader(a, .{ .other = 5 }, .added),
    );
    try testing.expectEqualStrings(
        "added",
        try formatSummaryHeader(a, .{}, .added),
    );
    try testing.expectEqualStrings(
        "modified",
        try formatSummaryHeader(a, .{}, .modified),
    );
}

test "countDeclKinds: groups added decls by kind, ignores unchanged/changed/removed" {
    // An added `.zig` file with 2 fns and 1 const. `countDeclKinds` with
    // direction=.added should report function=2 / binding=1. Zig has no
    // native type_alias, so that slot stays zero.
    const after =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub const C: u32 = 1;
    ;

    var fd = try rv.diffSources(testing.allocator, .zig, "", after);
    defer fd.deinit();

    const counts = countDeclKinds(fd.entries, .added);
    try testing.expectEqual(@as(u32, 2), counts.function);
    try testing.expectEqual(@as(u32, 1), counts.binding);
    try testing.expectEqual(@as(u32, 0), counts.type_alias);
    try testing.expectEqual(@as(u32, 0), counts.other);

    // Same entries asked about `.removed` yields nothing, since every
    // top-level DeclDiff here is `.added`.
    const removed_counts = countDeclKinds(fd.entries, .removed);
    try testing.expectEqual(@as(u32, 0), removed_counts.function);
    try testing.expectEqual(@as(u32, 0), removed_counts.binding);
}

test "countDeclKinds: groups changed decls under direction=.modified" {
    const before =
        \\pub fn a() u32 { return 1; }
        \\pub const C: u32 = 1;
    ;
    const after =
        \\pub fn a() u32 { return 2; }
        \\pub const C: u32 = 2;
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    const counts = countDeclKinds(fd.entries, .modified);
    try testing.expectEqual(@as(u32, 1), counts.function);
    try testing.expectEqual(@as(u32, 1), counts.binding);

    // Same entries asked about `.added` yields nothing.
    const added_counts = countDeclKinds(fd.entries, .added);
    try testing.expectEqual(@as(u32, 0), added_counts.function);
    try testing.expectEqual(@as(u32, 0), added_counts.binding);
}

test "formatModifiedHeader: 2 fns modified, 1 const added → '1 const added, 2 fns modified'" {
    const before =
        \\pub fn a() u32 { return 1; }
        \\pub fn b() u32 { return 1; }
    ;
    const after =
        \\pub fn a() u32 { return 2; }
        \\pub fn b() u32 { return 2; }
        \\pub const C: u32 = 0;
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const s = try formatModifiedHeader(arena.allocator(), fd.entries);
    try testing.expectEqualStrings("1 const added, 2 fns modified", s);
}

test "formatModifiedHeader: empty entries → 'no decl-level changes'" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try formatModifiedHeader(arena.allocator(), &.{});
    try testing.expectEqualStrings("no decl-level changes", s);
}

test "formatModifiedHeader: only-unchanged file → 'no decl-level changes'" {
    const src = "pub fn a() void {}\npub fn b() void {}\n";
    var fd = try rv.diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const s = try formatModifiedHeader(arena.allocator(), fd.entries);
    try testing.expectEqualStrings("no decl-level changes", s);
}

test "formatModifiedHeader: mix of added / modified / removed comma-joined in canonical order" {
    const before =
        \\pub fn keep() void {}
        \\pub fn gone() void {}
        \\pub fn mod() u32 { return 1; }
    ;
    const after =
        \\pub fn keep() void {}
        \\pub fn fresh() void {}
        \\pub fn mod() u32 { return 2; }
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const s = try formatModifiedHeader(arena.allocator(), fd.entries);
    try testing.expectEqualStrings("1 fn added, 1 fn modified, 1 fn removed", s);
}

//! FileDiff → []StyledLine. Pure, tty-free, unit-testable.
//!
//! Produces the "structural unified" view described in the UI plan:
//!
//!   = name                (unchanged: dim, one line)
//!   + name  (ts_kind)     (added: green header + verbatim right-source as + lines)
//!   - name  (ts_kind)     (removed: red header + verbatim left-source as - lines)
//!   ~ name  (ts_kind)     (changed leaf: yellow header + left-source as -, then right-source as +)
//!   ~ name  (ts_kind)     (changed container: yellow header, then recurse with indent+1)
//!
//! Atom-level novel-range highlighting (Option C) is deferred; the returned
//! `StyledLine.novel_spans` is always empty for now but kept in the shape so
//! callers don't need a re-plumb later.
//!
//! Tabs in source are expanded to 4 spaces at build-time so cell widths stay
//! consistent without the renderer needing to know.

const std = @import("std");

const rv = @import("rv");

pub const Marker = enum(u8) {
    /// Unchanged header.
    unchanged,
    /// Added decl header, or a source line from an added decl.
    added,
    /// Removed decl header, or a source line from a removed decl.
    removed,
    /// Changed decl header (leaf or container).
    changed,
    /// File/stats header line.
    header,
    /// Blank separator between entries.
    blank,

    pub fn gutter(self: Marker) []const u8 {
        return switch (self) {
            .unchanged => "=",
            .added => "+",
            .removed => "-",
            .changed => "~",
            .header, .blank => " ",
        };
    }
};

/// Classification of a line for styling. `decl_header` lines get bold + color;
/// `source` lines get a softer fg to keep the header scannable.
pub const LineKind = enum {
    file_header,
    stats,
    decl_header,
    source,
    blank,
};

pub const StyledLine = struct {
    indent: u8,
    marker: Marker,
    kind: LineKind,
    /// Owned by the slice returned from `build`; freed via `freeLines`.
    text: []const u8,
    /// Byte ranges within `text` that a future atom-level highlighter should
    /// tint (Option C). Always empty in v1.
    novel_spans: []const ByteSpan = &.{},
};

pub const ByteSpan = struct { start: u32, end: u32 };

pub const Stats = struct {
    added: usize = 0,
    removed: usize = 0,
    changed: usize = 0,
    unchanged: usize = 0,
};

pub const BuildResult = struct {
    lines: []const StyledLine,
    stats: Stats,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *BuildResult) void {
        self.arena.deinit();
    }
};

/// Walks the FileDiff and emits lines for the structural-unified view.
/// All slices in `BuildResult` are arena-owned; `deinit` frees them.
pub fn build(gpa: std.mem.Allocator, file_diff: *const rv.FileDiff) !BuildResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(StyledLine) = .empty;
    var stats: Stats = .{};

    try appendEntries(arena, &out, &stats, file_diff, file_diff.entries, 0);

    return .{
        .lines = try out.toOwnedSlice(arena),
        .stats = stats,
        .arena = arena_state,
    };
}

fn appendEntries(
    arena: std.mem.Allocator,
    out: *std.ArrayList(StyledLine),
    stats: *Stats,
    file_diff: *const rv.FileDiff,
    entries: []const rv.DeclDiff,
    indent: u8,
) !void {
    for (entries) |entry| {
        switch (entry) {
            .unchanged => |u| {
                stats.unchanged += 1;
                try out.append(arena, .{
                    .indent = indent,
                    .marker = .unchanged,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, u.decl, u.moved),
                });
            },
            .added => |a| {
                stats.added += 1;
                try out.append(arena, .{
                    .indent = indent,
                    .marker = .added,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, a.decl, null),
                });
                try appendSourceLines(
                    arena,
                    out,
                    file_diff.right_source,
                    a.decl.list.byte_range.start,
                    a.decl.list.byte_range.end,
                    indent + 1,
                    .added,
                );
            },
            .removed => |r| {
                stats.removed += 1;
                try out.append(arena, .{
                    .indent = indent,
                    .marker = .removed,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, r.decl, null),
                });
                try appendSourceLines(
                    arena,
                    out,
                    file_diff.left_source,
                    r.decl.list.byte_range.start,
                    r.decl.list.byte_range.end,
                    indent + 1,
                    .removed,
                );
            },
            .changed => |c| {
                stats.changed += 1;
                try out.append(arena, .{
                    .indent = indent,
                    .marker = .changed,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, c.new, c.moved),
                });
                switch (c.body) {
                    .container => |children| try appendEntries(arena, out, stats, file_diff, children, indent + 1),
                    .leaf => {
                        try appendSourceLines(
                            arena,
                            out,
                            file_diff.left_source,
                            c.old.list.byte_range.start,
                            c.old.list.byte_range.end,
                            indent + 1,
                            .removed,
                        );
                        try appendSourceLines(
                            arena,
                            out,
                            file_diff.right_source,
                            c.new.list.byte_range.start,
                            c.new.list.byte_range.end,
                            indent + 1,
                            .added,
                        );
                    },
                }
            },
        }
    }
}

fn declHeaderText(
    arena: std.mem.Allocator,
    decl: rv.Decl,
    moved: ?rv.MoveInfo,
) ![]const u8 {
    const name = decl.name orelse "<anon>";
    if (moved) |m| {
        return std.fmt.allocPrint(arena, "{s}  ({s}, moved {d} → {d})", .{
            name, decl.ts_kind, m.from_idx, m.to_idx,
        });
    }
    return std.fmt.allocPrint(arena, "{s}  ({s})", .{ name, decl.ts_kind });
}

/// Split the given source slice by newlines and emit one StyledLine per line,
/// expanding tabs to 4 spaces. Empty trailing line (from a trailing '\n') is
/// omitted so we don't render a phantom row after each span.
fn appendSourceLines(
    arena: std.mem.Allocator,
    out: *std.ArrayList(StyledLine),
    source: []const u8,
    start: u32,
    end: u32,
    indent: u8,
    marker: Marker,
) !void {
    const slice = source[start..end];
    var it = std.mem.splitScalar(u8, slice, '\n');
    var first = true;
    while (it.next()) |line_raw| {
        // Drop a final empty token that comes from a trailing '\n'.
        if (line_raw.len == 0 and it.peek() == null and !first) break;
        first = false;

        const expanded = try expandTabs(arena, line_raw);
        try out.append(arena, .{
            .indent = indent,
            .marker = marker,
            .kind = .source,
            .text = expanded,
        });
    }
}

const tab_width: usize = 4;

fn expandTabs(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    const tab_count = std.mem.count(u8, line, "\t");
    if (tab_count == 0) return arena.dupe(u8, line);

    const new_len = line.len + tab_count * (tab_width - 1);
    const buf = try arena.alloc(u8, new_len);
    var j: usize = 0;
    for (line) |c| {
        if (c == '\t') {
            @memset(buf[j..][0..tab_width], ' ');
            j += tab_width;
        } else {
            buf[j] = c;
            j += 1;
        }
    }
    return buf;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "build: identical Zig sources → one unchanged header per decl, no source lines" {
    const src =
        \\pub fn a() void {}
        \\pub fn b() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.stats.unchanged);
    try testing.expectEqual(@as(usize, 0), result.stats.added);
    try testing.expectEqual(@as(usize, 0), result.stats.removed);
    try testing.expectEqual(@as(usize, 0), result.stats.changed);

    try testing.expectEqual(@as(usize, 2), result.lines.len);
    try testing.expectEqual(Marker.unchanged, result.lines[0].marker);
    try testing.expectEqual(LineKind.decl_header, result.lines[0].kind);
}

test "build: added Zig fn → header + all source lines marked added" {
    const before = "pub fn a() void {}\n";
    const after = "pub fn a() void {}\npub fn b() void {\n    return;\n}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.added);

    // Find the added header.
    var header_idx: ?usize = null;
    for (result.lines, 0..) |ln, i| {
        if (ln.marker == .added and ln.kind == .decl_header) {
            header_idx = i;
            break;
        }
    }
    try testing.expect(header_idx != null);
    const hi = header_idx.?;

    // Every line after the header that belongs to the added decl is marker=.added, kind=.source.
    try testing.expect(hi + 1 < result.lines.len);
    try testing.expectEqual(Marker.added, result.lines[hi + 1].marker);
    try testing.expectEqual(LineKind.source, result.lines[hi + 1].kind);
}

test "build: removed Zig fn → header + all source lines marked removed, from LEFT source" {
    const before = "pub fn a() void {}\npub fn gone() void { return; }\n";
    const after = "pub fn a() void {}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.removed);

    var saw_removed_source = false;
    for (result.lines) |ln| {
        if (ln.marker == .removed and ln.kind == .source) {
            // The removed line must be a real source line, not an empty string.
            try testing.expect(ln.text.len > 0);
            saw_removed_source = true;
        }
    }
    try testing.expect(saw_removed_source);
}

test "build: changed leaf → - lines (left) then + lines (right)" {
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.changed);

    // Expected order: changed header, then removed source lines, then added source lines.
    try testing.expect(result.lines.len >= 3);
    try testing.expectEqual(Marker.changed, result.lines[0].marker);

    var seen_removed_before_added = false;
    var last_was_removed = false;
    for (result.lines[1..]) |ln| {
        if (ln.kind != .source) continue;
        if (ln.marker == .removed) last_was_removed = true;
        if (ln.marker == .added and last_was_removed) {
            seen_removed_before_added = true;
            break;
        }
    }
    try testing.expect(seen_removed_before_added);
}

test "build: changed container → recurse with indent, no - / + dumps at container level" {
    const before =
        \\pub const Thing = struct {
        \\    pub fn one() void {}
        \\};
    ;
    const after =
        \\pub const Thing = struct {
        \\    pub fn one() void {}
        \\    pub fn two() void {}
        \\};
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.changed);
    try testing.expectEqual(@as(usize, 1), result.stats.added);
    try testing.expectEqual(@as(usize, 1), result.stats.unchanged);

    // First line: container "Thing" header at indent 0.
    try testing.expectEqual(Marker.changed, result.lines[0].marker);
    try testing.expectEqual(@as(u8, 0), result.lines[0].indent);

    // Children are indented >= 1.
    var saw_indented_child = false;
    for (result.lines[1..]) |ln| {
        if (ln.kind == .decl_header and ln.indent >= 1) saw_indented_child = true;
    }
    try testing.expect(saw_indented_child);
}

test "build: unchanged decl does not dump its source lines" {
    const src = "pub fn a() void {\n    return;\n}\npub fn b() void {}\n";
    var fd = try rv.diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd);
    defer result.deinit();

    for (result.lines) |ln| try testing.expect(ln.kind != .source);
}

test "build: decl header includes moved info when present" {
    const before = "pub fn a() void {}\npub fn b() void {}\n";
    const after = "pub fn b() void {}\npub fn a() void {}\n";
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd);
    defer result.deinit();

    var found_moved_in_text = false;
    for (result.lines) |ln| {
        if (std.mem.indexOf(u8, ln.text, "moved ") != null) found_moved_in_text = true;
    }
    try testing.expect(found_moved_in_text);
}

test "expandTabs: leading tab becomes 4 spaces" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try expandTabs(arena_state.allocator(), "\tfoo");
    try testing.expectEqualStrings("    foo", out);
}

test "expandTabs: no tabs → identical content, separate allocation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try expandTabs(arena_state.allocator(), "hello");
    try testing.expectEqualStrings("hello", out);
}

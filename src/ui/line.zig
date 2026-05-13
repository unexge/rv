//! FileDiff → view lines. Pure, tty-free, unit-testable.
//!
//! Two rendering modes share this builder:
//!
//!   `.unified` produces a flat `[]StyledLine`:
//!     = name                (unchanged: dim, one line)
//!     + name  (ts_kind)     (added: green header + verbatim right-source as + lines)
//!     - name  (ts_kind)     (removed: red header + verbatim left-source as - lines)
//!     ~ name  (ts_kind)     (changed leaf: yellow header + left-source as -, then right-source as +)
//!     ~ name  (ts_kind)     (changed container: yellow header, then recurse with indent+1)
//!
//!   `.split` produces `[]LinePair` (left_line, right_line per row):
//!     unchanged / changed header / changed-container header → identical on both sides.
//!     added → left blank, right has header + right-source `+` lines.
//!     removed → left has header + left-source `-` lines, right blank.
//!     changed leaf body → `-` lines on the left paired 1:1 with `+` lines on the
//!       right, padded with blanks on whichever side runs out first.
//!
//! Atom-level novel-range highlighting (Option C): for `changed` leaf bodies
//! we walk the `EditScript` and populate `StyledLine.novel_spans` on the
//! `-` / `+` source lines so the renderer can tint the exact bytes that
//! differ. Spans are in *display* (post-tab-expansion) coordinates and are
//! clipped to a single line (no span crosses `\n`). List-level novels are
//! deferred to a future iteration; v1 handles atoms only. Trivia novels
//! whose byte_ranges live outside the Decl's `list.byte_range` (see
//! `diff/align.zig::triviaEdits`) fall outside every emitted line and so
//! silently drop out of the clipping step.
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
    /// Byte ranges within `text` to tint as atom-level novels (Option C).
    /// Populated on `-` / `+` source lines of `changed` leaves only; empty
    /// on decl headers, blanks, and pure add/remove dumps. Offsets are in
    /// display (post-tab-expansion) coordinates, sorted by `start`, and
    /// clipped so no span crosses a `\n`.
    novel_spans: []const ByteSpan = &.{},
};

pub const ByteSpan = struct { start: u32, end: u32 };

/// Pre-collected novel byte ranges for one side of a `changed` leaf, used to
/// paint `StyledLine.novel_spans`. An empty slice means no highlighting.
const Novels = []const ByteSpan;

/// A single row in split-view: one StyledLine per pane. Either side may be
/// a blank filler (`marker == .blank`, `kind == .blank`, `text == ""`).
pub const LinePair = struct {
    left: StyledLine,
    right: StyledLine,

    /// The decl-header side of this pair, if any. Unchanged/changed headers
    /// are mirrored on both sides; added/removed headers live on whichever
    /// side isn't the blank filler.
    pub fn headerSide(self: LinePair) ?StyledLine {
        if (self.right.kind == .decl_header) return self.right;
        if (self.left.kind == .decl_header) return self.left;
        return null;
    }
};

pub const Mode = enum { unified, split };

pub const Stats = struct {
    added: usize = 0,
    removed: usize = 0,
    changed: usize = 0,
    unchanged: usize = 0,
};

pub const View = union(Mode) {
    unified: []const StyledLine,
    split: []const LinePair,
};

pub const BuildResult = struct {
    view: View,
    stats: Stats,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *BuildResult) void {
        self.arena.deinit();
    }

    /// Convenience: number of visible rows for the current view.
    pub fn rowCount(self: BuildResult) usize {
        return switch (self.view) {
            .unified => |ls| ls.len,
            .split => |ps| ps.len,
        };
    }
};

/// Walks the FileDiff and emits view lines for the requested mode.
/// All slices in `BuildResult` are arena-owned; `deinit` frees them.
pub fn build(
    gpa: std.mem.Allocator,
    file_diff: *const rv.FileDiff,
    mode: Mode,
) !BuildResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var stats: Stats = .{};
    const view: View = switch (mode) {
        .unified => blk: {
            var out: std.ArrayList(StyledLine) = .empty;
            try appendEntries(arena, &out, &stats, file_diff, file_diff.entries, 0);
            break :blk .{ .unified = try out.toOwnedSlice(arena) };
        },
        .split => blk: {
            var out: std.ArrayList(LinePair) = .empty;
            try appendEntriesSplit(arena, &out, &stats, file_diff, file_diff.entries, 0);
            break :blk .{ .split = try out.toOwnedSlice(arena) };
        },
    };

    return .{
        .view = view,
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
                    &.{},
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
                    &.{},
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
                    .leaf => |script| {
                        const left_novels = try collectAtomNovels(arena, script, .left);
                        const right_novels = try collectAtomNovels(arena, script, .right);
                        try appendSourceLines(
                            arena,
                            out,
                            file_diff.left_source,
                            c.old.list.byte_range.start,
                            c.old.list.byte_range.end,
                            indent + 1,
                            .removed,
                            left_novels,
                        );
                        try appendSourceLines(
                            arena,
                            out,
                            file_diff.right_source,
                            c.new.list.byte_range.start,
                            c.new.list.byte_range.end,
                            indent + 1,
                            .added,
                            right_novels,
                        );
                    },
                }
            },
        }
    }
}

// ── split-mode traversal ───────────────────────────────────────────────────

fn appendEntriesSplit(
    arena: std.mem.Allocator,
    out: *std.ArrayList(LinePair),
    stats: *Stats,
    file_diff: *const rv.FileDiff,
    entries: []const rv.DeclDiff,
    indent: u8,
) !void {
    for (entries) |entry| {
        switch (entry) {
            .unchanged => |u| {
                stats.unchanged += 1;
                const header: StyledLine = .{
                    .indent = indent,
                    .marker = .unchanged,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, u.decl, u.moved),
                };
                try out.append(arena, .{ .left = header, .right = header });
            },
            .added => |a| {
                stats.added += 1;
                const header: StyledLine = .{
                    .indent = indent,
                    .marker = .added,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, a.decl, null),
                };
                try out.append(arena, .{ .left = blankLine(indent), .right = header });
                const src_lines = try sourceLinesSlice(
                    arena,
                    file_diff.right_source,
                    a.decl.list.byte_range.start,
                    a.decl.list.byte_range.end,
                    indent + 1,
                    .added,
                    &.{},
                );
                for (src_lines) |line_right| {
                    try out.append(arena, .{ .left = blankLine(indent + 1), .right = line_right });
                }
            },
            .removed => |r| {
                stats.removed += 1;
                const header: StyledLine = .{
                    .indent = indent,
                    .marker = .removed,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, r.decl, null),
                };
                try out.append(arena, .{ .left = header, .right = blankLine(indent) });
                const src_lines = try sourceLinesSlice(
                    arena,
                    file_diff.left_source,
                    r.decl.list.byte_range.start,
                    r.decl.list.byte_range.end,
                    indent + 1,
                    .removed,
                    &.{},
                );
                for (src_lines) |line_left| {
                    try out.append(arena, .{ .left = line_left, .right = blankLine(indent + 1) });
                }
            },
            .changed => |c| {
                stats.changed += 1;
                const header: StyledLine = .{
                    .indent = indent,
                    .marker = .changed,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, c.new, c.moved),
                };
                try out.append(arena, .{ .left = header, .right = header });
                switch (c.body) {
                    .container => |children| try appendEntriesSplit(
                        arena,
                        out,
                        stats,
                        file_diff,
                        children,
                        indent + 1,
                    ),
                    .leaf => |script| {
                        const left_novels = try collectAtomNovels(arena, script, .left);
                        const right_novels = try collectAtomNovels(arena, script, .right);
                        const left_lines = try sourceLinesSlice(
                            arena,
                            file_diff.left_source,
                            c.old.list.byte_range.start,
                            c.old.list.byte_range.end,
                            indent + 1,
                            .removed,
                            left_novels,
                        );
                        const right_lines = try sourceLinesSlice(
                            arena,
                            file_diff.right_source,
                            c.new.list.byte_range.start,
                            c.new.list.byte_range.end,
                            indent + 1,
                            .added,
                            right_novels,
                        );
                        const n = @max(left_lines.len, right_lines.len);
                        for (0..n) |i| {
                            const left_line = if (i < left_lines.len)
                                left_lines[i]
                            else
                                blankLine(indent + 1);
                            const right_line = if (i < right_lines.len)
                                right_lines[i]
                            else
                                blankLine(indent + 1);
                            try out.append(arena, .{ .left = left_line, .right = right_line });
                        }
                    },
                }
            },
        }
    }
}

fn blankLine(indent: u8) StyledLine {
    return .{
        .indent = indent,
        .marker = .blank,
        .kind = .blank,
        .text = "",
    };
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
/// omitted so we don't render a phantom row after each span. `novels` is a
/// (possibly empty) slice of absolute byte ranges that belong to this side;
/// each range is clipped per-emitted-line and translated into
/// display-coordinate `ByteSpan`s on `StyledLine.novel_spans`.
fn appendSourceLines(
    arena: std.mem.Allocator,
    out: *std.ArrayList(StyledLine),
    source: []const u8,
    start: u32,
    end: u32,
    indent: u8,
    marker: Marker,
    novels: Novels,
) !void {
    const lines = try sourceLinesSlice(arena, source, start, end, indent, marker, novels);
    try out.appendSlice(arena, lines);
}

fn sourceLinesSlice(
    arena: std.mem.Allocator,
    source: []const u8,
    start: u32,
    end: u32,
    indent: u8,
    marker: Marker,
    novels: Novels,
) ![]const StyledLine {
    var buf: std.ArrayList(StyledLine) = .empty;
    const slice = source[start..end];

    // Manual line iteration so we can track each raw line's absolute start
    // offset in `source`; `splitScalar` would hide that.
    var cursor: usize = 0;
    var line_abs_start: u32 = start;
    var first = true;
    while (true) {
        const rest = slice[cursor..];
        const nl_rel = std.mem.indexOfScalar(u8, rest, '\n');
        const raw_line = if (nl_rel) |p| rest[0..p] else rest;

        // Drop a final empty token that comes from a trailing '\n'.
        if (raw_line.len == 0 and nl_rel == null and !first) break;
        first = false;

        const expanded = try expandTabs(arena, raw_line);
        const line_novels = try mapNovelsToLine(arena, raw_line, line_abs_start, novels);

        try buf.append(arena, .{
            .indent = indent,
            .marker = marker,
            .kind = .source,
            .text = expanded,
            .novel_spans = line_novels,
        });

        if (nl_rel) |p| {
            cursor += p + 1;
            line_abs_start = start + @as(u32, @intCast(cursor));
        } else break;
    }
    return try buf.toOwnedSlice(arena);
}

/// Collect absolute byte ranges of all atom-level novels on `side`. List-
/// level novels are intentionally skipped for v1 (they would require
/// descending into children to pick out which atoms to tint); the list's
/// full byte_range typically spans multiple lines and reverse-videoing it
/// wholesale is louder than useful.
fn collectAtomNovels(
    arena: std.mem.Allocator,
    script: rv.EditScript,
    side: rv.Side,
) ![]const ByteSpan {
    var out: std.ArrayList(ByteSpan) = .empty;
    for (script.edits) |e| switch (e) {
        .match => {},
        .novel => |nv| {
            if (nv.side != side) continue;
            switch (nv.node_ref.*) {
                .atom => |a| try out.append(arena, .{
                    .start = a.byte_range.start,
                    .end = a.byte_range.end,
                }),
                .list => {}, // deferred for v1; see module doc.
            }
        },
    };
    return try out.toOwnedSlice(arena);
}

/// Translate absolute-source novel byte ranges into per-line display
/// offsets for this raw (pre-tab-expansion) line. Spans outside the line
/// are dropped; spans that straddle the line's end are clipped so no span
/// ever crosses a newline. Output is sorted by `start`.
fn mapNovelsToLine(
    arena: std.mem.Allocator,
    raw_line: []const u8,
    line_abs_start: u32,
    novels: Novels,
) ![]const ByteSpan {
    if (novels.len == 0) return &.{};

    const line_abs_end: u32 = line_abs_start + @as(u32, @intCast(raw_line.len));

    var out: std.ArrayList(ByteSpan) = .empty;
    for (novels) |nv| {
        if (nv.end <= line_abs_start) continue;
        if (nv.start >= line_abs_end) continue;

        const clip_start_abs = @max(nv.start, line_abs_start);
        const clip_end_abs = @min(nv.end, line_abs_end);

        const raw_start: usize = clip_start_abs - line_abs_start;
        const raw_end: usize = clip_end_abs - line_abs_start;

        const disp_start: u32 = @intCast(rawToDisplay(raw_line, raw_start));
        const disp_end: u32 = @intCast(rawToDisplay(raw_line, raw_end));

        if (disp_end > disp_start) {
            try out.append(arena, .{ .start = disp_start, .end = disp_end });
        }
    }

    std.mem.sort(ByteSpan, out.items, {}, byteSpanLessThan);
    return try out.toOwnedSlice(arena);
}

fn byteSpanLessThan(_: void, a: ByteSpan, b: ByteSpan) bool {
    return a.start < b.start;
}

/// Map a raw-line byte offset to its post-tab-expansion display column.
/// Each `\t` counts as `tab_width` cells instead of one.
fn rawToDisplay(raw_line: []const u8, raw_offset: usize) usize {
    var tabs: usize = 0;
    var i: usize = 0;
    while (i < raw_offset) : (i += 1) {
        if (raw_line[i] == '\t') tabs += 1;
    }
    return raw_offset + tabs * (tab_width - 1);
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

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.stats.unchanged);
    try testing.expectEqual(@as(usize, 0), result.stats.added);
    try testing.expectEqual(@as(usize, 0), result.stats.removed);
    try testing.expectEqual(@as(usize, 0), result.stats.changed);

    const lines = result.view.unified;
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqual(Marker.unchanged, lines[0].marker);
    try testing.expectEqual(LineKind.decl_header, lines[0].kind);
}

test "build: added Zig fn → header + all source lines marked added" {
    const before = "pub fn a() void {}\n";
    const after = "pub fn a() void {}\npub fn b() void {\n    return;\n}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.added);

    const lines = result.view.unified;

    // Find the added header.
    var header_idx: ?usize = null;
    for (lines, 0..) |ln, i| {
        if (ln.marker == .added and ln.kind == .decl_header) {
            header_idx = i;
            break;
        }
    }
    try testing.expect(header_idx != null);
    const hi = header_idx.?;

    // Every line after the header that belongs to the added decl is marker=.added, kind=.source.
    try testing.expect(hi + 1 < lines.len);
    try testing.expectEqual(Marker.added, lines[hi + 1].marker);
    try testing.expectEqual(LineKind.source, lines[hi + 1].kind);
}

test "build: removed Zig fn → header + all source lines marked removed, from LEFT source" {
    const before = "pub fn a() void {}\npub fn gone() void { return; }\n";
    const after = "pub fn a() void {}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.removed);

    var saw_removed_source = false;
    for (result.view.unified) |ln| {
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

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.changed);

    const lines = result.view.unified;

    // Expected order: changed header, then removed source lines, then added source lines.
    try testing.expect(lines.len >= 3);
    try testing.expectEqual(Marker.changed, lines[0].marker);

    var seen_removed_before_added = false;
    var last_was_removed = false;
    for (lines[1..]) |ln| {
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

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.changed);
    try testing.expectEqual(@as(usize, 1), result.stats.added);
    try testing.expectEqual(@as(usize, 1), result.stats.unchanged);

    const lines = result.view.unified;

    // First line: container "Thing" header at indent 0.
    try testing.expectEqual(Marker.changed, lines[0].marker);
    try testing.expectEqual(@as(u8, 0), lines[0].indent);

    // Children are indented >= 1.
    var saw_indented_child = false;
    for (lines[1..]) |ln| {
        if (ln.kind == .decl_header and ln.indent >= 1) saw_indented_child = true;
    }
    try testing.expect(saw_indented_child);
}

test "build: unchanged decl does not dump its source lines" {
    const src = "pub fn a() void {\n    return;\n}\npub fn b() void {}\n";
    var fd = try rv.diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    for (result.view.unified) |ln| try testing.expect(ln.kind != .source);
}

test "build: decl header includes moved info when present" {
    const before = "pub fn a() void {}\npub fn b() void {}\n";
    const after = "pub fn b() void {}\npub fn a() void {}\n";
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    var found_moved_in_text = false;
    for (result.view.unified) |ln| {
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

// ── split-mode tests ─────────────────────────────────────────────────────

test "build split: identical sources → header pairs mirror both sides" {
    const src = "pub fn a() void {}\npub fn b() void {}\n";
    var fd = try rv.diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .split);
    defer result.deinit();

    const pairs = result.view.split;
    try testing.expectEqual(@as(usize, 2), pairs.len);
    for (pairs) |p| {
        try testing.expectEqual(Marker.unchanged, p.left.marker);
        try testing.expectEqual(Marker.unchanged, p.right.marker);
        try testing.expectEqualStrings(p.left.text, p.right.text);
    }
}

test "build split: added decl → left pane blank, right pane has header + source" {
    const before = "pub fn a() void {}\n";
    const after = "pub fn a() void {}\npub fn b() void {\n    return;\n}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .split);
    defer result.deinit();

    // Find the added header pair.
    var hi: ?usize = null;
    for (result.view.split, 0..) |p, i| {
        if (p.right.marker == .added and p.right.kind == .decl_header) {
            hi = i;
            break;
        }
    }
    try testing.expect(hi != null);
    const idx = hi.?;

    // Header pair: left blank, right is the added header.
    try testing.expectEqual(Marker.blank, result.view.split[idx].left.marker);
    try testing.expectEqual(LineKind.blank, result.view.split[idx].left.kind);
    try testing.expectEqualStrings("", result.view.split[idx].left.text);

    // Following source-line pair: left still blank, right has code.
    try testing.expect(idx + 1 < result.view.split.len);
    const next = result.view.split[idx + 1];
    try testing.expectEqual(Marker.blank, next.left.marker);
    try testing.expectEqual(Marker.added, next.right.marker);
    try testing.expectEqual(LineKind.source, next.right.kind);
    try testing.expect(next.right.text.len > 0);
}

test "build split: removed decl → right pane blank, left pane has header + source" {
    const before = "pub fn a() void {}\npub fn gone() void { return; }\n";
    const after = "pub fn a() void {}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .split);
    defer result.deinit();

    var saw_removed_source_left = false;
    for (result.view.split) |p| {
        if (p.left.marker == .removed and p.left.kind == .source) {
            try testing.expectEqual(Marker.blank, p.right.marker);
            try testing.expect(p.left.text.len > 0);
            saw_removed_source_left = true;
        }
    }
    try testing.expect(saw_removed_source_left);
}

test "build split: changed leaf → left `-` paired with right `+`, padded to equal counts" {
    // Old body: 1 line; new body: 3 lines, to force padding on the left.
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 {\n    const x: u32 = 42;\n    return x;\n}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .split);
    defer result.deinit();

    const pairs = result.view.split;
    // First pair: the changed header, identical on both sides.
    try testing.expectEqual(Marker.changed, pairs[0].left.marker);
    try testing.expectEqual(Marker.changed, pairs[0].right.marker);
    try testing.expectEqualStrings(pairs[0].left.text, pairs[0].right.text);

    // Body pairs: every row has either a real `-` on the left or a blank, and
    // either a real `+` on the right or a blank; never both sides blank.
    var total_body: usize = 0;
    var left_real: usize = 0;
    var right_real: usize = 0;
    for (pairs[1..]) |p| {
        total_body += 1;
        const left_blank = p.left.marker == .blank;
        const right_blank = p.right.marker == .blank;
        try testing.expect(!(left_blank and right_blank));
        if (!left_blank) {
            try testing.expectEqual(Marker.removed, p.left.marker);
            left_real += 1;
        }
        if (!right_blank) {
            try testing.expectEqual(Marker.added, p.right.marker);
            right_real += 1;
        }
    }
    try testing.expect(right_real > left_real);
    try testing.expectEqual(@max(left_real, right_real), total_body);
}

test "build split: changed container → header shared, children recurse with indent" {
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

    var result = try build(testing.allocator, &fd, .split);
    defer result.deinit();

    const pairs = result.view.split;

    // Container header pair: identical on both sides at indent 0.
    try testing.expectEqual(Marker.changed, pairs[0].left.marker);
    try testing.expectEqual(Marker.changed, pairs[0].right.marker);
    try testing.expectEqual(@as(u8, 0), pairs[0].left.indent);
    try testing.expectEqualStrings(pairs[0].left.text, pairs[0].right.text);

    // Somewhere among the children there is an indented decl_header.
    var saw_indented_child = false;
    for (pairs[1..]) |p| {
        if (p.headerSide()) |side| {
            if (side.indent >= 1) saw_indented_child = true;
        }
    }
    try testing.expect(saw_indented_child);
}

// ── novel-range highlighting (Option C) ─────────────────────────────────

/// Helper: collect all novel spans from source lines matching `marker`,
/// concatenated in source order. The concatenation is what the test cares
/// about — exactly which atoms got split into separate novel edits is an
/// implementation detail of Dijkstra.
fn collectHighlightedText(
    arena: std.mem.Allocator,
    lines: []const StyledLine,
    marker: Marker,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (lines) |ln| {
        if (ln.kind != .source) continue;
        if (ln.marker != marker) continue;
        for (ln.novel_spans) |s| {
            try buf.appendSlice(arena, ln.text[s.start..s.end]);
        }
    }
    return try buf.toOwnedSlice(arena);
}

test "build: changed leaf populates novel_spans covering exactly the differing atoms" {
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const removed_highlight = try collectHighlightedText(a, result.view.unified, .removed);
    const added_highlight = try collectHighlightedText(a, result.view.unified, .added);

    try testing.expectEqualStrings("1", removed_highlight);
    try testing.expectEqualStrings("2", added_highlight);
}

test "build: body_change fixture (1 → 42) — novel_spans cover exactly the literals" {
    // Mirrors tests/fixtures/zig/body_change. This is the acceptance case
    // called out in the task: the `1` and `42` should be tinted, inclusive.
    const before =
        \\pub fn greet() u32 {
        \\    return 1;
        \\}
    ;
    const after =
        \\pub fn greet() u32 {
        \\    return 42;
        \\}
    ;

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const removed_highlight = try collectHighlightedText(a, result.view.unified, .removed);
    const added_highlight = try collectHighlightedText(a, result.view.unified, .added);

    try testing.expectEqualStrings("1", removed_highlight);
    try testing.expectEqualStrings("42", added_highlight);
}

test "build: novel_spans respect tab expansion (display offsets, not raw)" {
    // Leading `\t` on the return line shifts every raw offset by
    // `tab_width - 1`. The novel span must land on the expanded position.
    const before = "pub fn greet() u32 {\n\treturn 1;\n}\n";
    const after = "pub fn greet() u32 {\n\treturn 2;\n}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    // Locate the removed `return` line.
    var hit: ?StyledLine = null;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        if (ln.marker != .removed) continue;
        if (std.mem.indexOf(u8, ln.text, "return") == null) continue;
        hit = ln;
        break;
    }
    try testing.expect(hit != null);
    const ln = hit.?;

    // After tab expansion, the line begins with 4 spaces. `return ` then
    // ends at column 11, so `1` lives at columns [11, 12).
    try testing.expect(ln.novel_spans.len >= 1);
    const span = ln.novel_spans[0];
    try testing.expectEqualStrings("1", ln.text[span.start..span.end]);
    try testing.expectEqual(@as(u32, 11), span.start);
    try testing.expectEqual(@as(u32, 12), span.end);
    try testing.expect(std.mem.startsWith(u8, ln.text, "    return "));
}

test "build: unchanged/added/removed decls carry no novel_spans" {
    // Pure add, pure remove, and pure unchanged should never produce novel
    // spans — atom-level highlighting is a changed-leaf feature.
    const before = "pub fn keep() void {}\npub fn gone() void { return; }\n";
    const after = "pub fn keep() void {}\npub fn fresh() void { return; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .unified);
    defer result.deinit();

    for (result.view.unified) |ln| {
        try testing.expectEqual(@as(usize, 0), ln.novel_spans.len);
    }
}

test "build split: changed leaf populates novel_spans on both panes" {
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try build(testing.allocator, &fd, .split);
    defer result.deinit();

    var left_any = false;
    var right_any = false;
    for (result.view.split) |p| {
        if (p.left.kind == .source and p.left.novel_spans.len > 0) {
            const s = p.left.novel_spans[0];
            try testing.expectEqualStrings("1", p.left.text[s.start..s.end]);
            left_any = true;
        }
        if (p.right.kind == .source and p.right.novel_spans.len > 0) {
            const s = p.right.novel_spans[0];
            try testing.expectEqualStrings("2", p.right.text[s.start..s.end]);
            right_any = true;
        }
    }
    try testing.expect(left_any);
    try testing.expect(right_any);
}

test "mapNovelsToLine: novel outside the emitted line is dropped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // raw_line starts at absolute offset 100, length 10.
    const raw = "abcdefghij";
    const novels = [_]ByteSpan{
        .{ .start = 50, .end = 60 }, // entirely before
        .{ .start = 200, .end = 210 }, // entirely after
        .{ .start = 102, .end = 105 }, // inside → [2, 5)
    };
    const got = try mapNovelsToLine(a, raw, 100, &novels);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u32, 2), got[0].start);
    try testing.expectEqual(@as(u32, 5), got[0].end);
}

test "mapNovelsToLine: novel straddling line end is clipped, never crosses \\n" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const raw = "hello"; // 5 bytes, at abs [10, 15)
    const novels = [_]ByteSpan{
        .{ .start = 12, .end = 25 }, // extends beyond line end (15)
    };
    const got = try mapNovelsToLine(a, raw, 10, &novels);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u32, 2), got[0].start);
    try testing.expectEqual(@as(u32, 5), got[0].end);
}

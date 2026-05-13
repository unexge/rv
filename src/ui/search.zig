//! Incremental substring search over the rendered diff lines.
//!
//! Pure, tty-free, unit-testable:
//!
//! - `findMatches` scans a `View` for every occurrence of `query` (per-line
//!   `std.mem.indexOf`; no regex in v1) and returns a flat, row-sorted
//!   slice of `Match`es. Matches never cross a line boundary because the
//!   view is already line-based.
//! - `matchesOnLine` is the per-line helper for the render path: it takes
//!   the line's (post-tab-expansion) display text and returns the byte
//!   spans covered by the query, in display coordinates.
//! - `nextMatchIndex` / `prevMatchIndex` / `firstMatchAtOrAfter` implement
//!   navigation over a materialised match list with wrap-around.
//!
//! Coordinate system: `Match.row` is the absolute view row (same units as
//! `AppState.cursor_y`); `start` / `end` are byte offsets into the line's
//! `text` field (which is already display bytes, see `line.zig::expandTabs`).
//! Callers that highlight matches at render time can treat the span as a
//! direct slice into `StyledLine.text`.
//!
//! Status: these primitives are not yet consumed by `app.zig` - the `/`
//! prompt, render-time overlay, and collapse snapshot/restore on
//! `/`/Esc are not implemented. Wiring them up is the remaining work
//! for the "Search within diff" subtask; this module ships the pure
//! scanning primitives on their own.

const std = @import("std");
const line_mod = @import("line.zig");

const View = line_mod.View;
const StyledLine = line_mod.StyledLine;
const LinePair = line_mod.LinePair;

pub const Match = struct {
    /// Absolute row in the current view; matches `AppState.cursor_y`.
    row: usize,
    /// Byte offsets into the row's rendered text (display coordinates).
    start: usize,
    end: usize,
};

/// Scan the entire view for `query`. Returns matches in row-then-column
/// order. An empty query returns an empty slice - callers treat "no query"
/// and "query with no hits" identically.
pub fn findMatches(
    arena: std.mem.Allocator,
    view: View,
    query: []const u8,
) ![]const Match {
    if (query.len == 0) return &.{};

    var out: std.ArrayList(Match) = .empty;
    switch (view) {
        .unified => |lines| for (lines, 0..) |ln, i| {
            try appendLineMatches(arena, &out, i, ln.text, query);
        },
        .split => |pairs| for (pairs, 0..) |p, i| {
            try appendPairMatches(arena, &out, i, p, query);
        },
    }
    return try out.toOwnedSlice(arena);
}

/// Per-line match spans in display coordinates. Intended for the render
/// path so a future overlay doesn't need to carry a materialised global
/// match list all the way down into the cell painter.
pub fn matchesOnLine(
    arena: std.mem.Allocator,
    text: []const u8,
    query: []const u8,
) ![]const line_mod.ByteSpan {
    if (query.len == 0 or query.len > text.len) return &.{};

    var out: std.ArrayList(line_mod.ByteSpan) = .empty;
    var cursor: usize = 0;
    while (cursor + query.len <= text.len) {
        const rel = std.mem.indexOf(u8, text[cursor..], query) orelse break;
        const abs = cursor + rel;
        try out.append(arena, .{
            .start = @intCast(abs),
            .end = @intCast(abs + query.len),
        });
        // Advance by one byte so overlapping matches (e.g. "aa" in "aaa")
        // are all surfaced; the render overlay coalesces visually.
        cursor = abs + 1;
    }
    return try out.toOwnedSlice(arena);
}

/// Index of the first match strictly *after* `cursor_row`, wrapping to the
/// start of the list. Returns null if `matches` is empty. Pressing `n`
/// repeatedly cycles through every hit even if the cursor currently sits
/// exactly on one.
pub fn nextMatchIndex(matches: []const Match, cursor_row: usize) ?usize {
    if (matches.len == 0) return null;
    for (matches, 0..) |m, i| {
        if (m.row > cursor_row) return i;
    }
    return 0;
}

/// Index of the last match strictly *before* `cursor_row`, wrapping to the
/// end of the list. Symmetric with `nextMatchIndex`.
pub fn prevMatchIndex(matches: []const Match, cursor_row: usize) ?usize {
    if (matches.len == 0) return null;
    var i: usize = matches.len;
    while (i > 0) {
        i -= 1;
        if (matches[i].row < cursor_row) return i;
    }
    return matches.len - 1;
}

/// Index of the first match at or after `from_row`. Used when the user
/// first commits a query: the cursor should jump to the closest match
/// without wrapping, so a single-press doesn't teleport backwards.
pub fn firstMatchAtOrAfter(matches: []const Match, from_row: usize) ?usize {
    if (matches.len == 0) return null;
    for (matches, 0..) |m, i| {
        if (m.row >= from_row) return i;
    }
    // Nothing at or after; wrap to the first match so the cursor still
    // lands on a real hit rather than staying put.
    return 0;
}

// ── internals ──────────────────────────────────────────────────────────────

fn appendLineMatches(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Match),
    row: usize,
    text: []const u8,
    query: []const u8,
) !void {
    if (query.len > text.len) return;
    var cursor: usize = 0;
    while (cursor + query.len <= text.len) {
        const rel = std.mem.indexOf(u8, text[cursor..], query) orelse break;
        const abs = cursor + rel;
        try out.append(arena, .{
            .row = row,
            .start = abs,
            .end = abs + query.len,
        });
        cursor = abs + 1;
    }
}

fn appendPairMatches(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Match),
    row: usize,
    pair: LinePair,
    query: []const u8,
) !void {
    // Split view: a row matches if *either* pane's text contains the query.
    // We emit one Match per row (not per pane) because navigation cares
    // about landing on the row; the render-time overlay re-derives per-pane
    // spans independently.
    const left_hit = query.len <= pair.left.text.len and
        std.mem.indexOf(u8, pair.left.text, query) != null;
    const right_hit = query.len <= pair.right.text.len and
        std.mem.indexOf(u8, pair.right.text, query) != null;
    if (!left_hit and !right_hit) return;

    // Record the first position we can find on either side, just so the
    // `Match` carries *some* span. The render path re-derives real per-pane
    // spans from `matchesOnLine` so the exact column here isn't shown.
    const start: usize = blk: {
        if (left_hit) break :blk std.mem.indexOf(u8, pair.left.text, query).?;
        break :blk std.mem.indexOf(u8, pair.right.text, query).?;
    };
    try out.append(arena, .{
        .row = row,
        .start = start,
        .end = start + query.len,
    });
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkLine(text: []const u8) StyledLine {
    return .{
        .indent = 0,
        .marker = .unchanged,
        .kind = .source,
        .text = text,
    };
}

test "findMatches: empty query → no matches" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const lines = [_]StyledLine{ mkLine("hello"), mkLine("world") };
    const view: View = .{ .unified = lines[0..] };
    const matches = try findMatches(arena_state.allocator(), view, "");
    try testing.expectEqual(@as(usize, 0), matches.len);
}

test "findMatches: single hit returns (row, start, end)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const lines = [_]StyledLine{
        mkLine("pub fn first() u32 { return 1; }"),
        mkLine("pub fn greet() u32 { return 2; }"),
    };
    const view: View = .{ .unified = lines[0..] };
    const matches = try findMatches(arena_state.allocator(), view, "greet");
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(usize, 1), matches[0].row);
    try testing.expectEqual(@as(usize, 7), matches[0].start);
    try testing.expectEqual(@as(usize, 12), matches[0].end);
}

test "findMatches: multiple hits on one line emitted left-to-right" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const lines = [_]StyledLine{mkLine("ab ab ab")};
    const view: View = .{ .unified = lines[0..] };
    const matches = try findMatches(arena_state.allocator(), view, "ab");
    try testing.expectEqual(@as(usize, 3), matches.len);
    try testing.expectEqual(@as(usize, 0), matches[0].start);
    try testing.expectEqual(@as(usize, 3), matches[1].start);
    try testing.expectEqual(@as(usize, 6), matches[2].start);
}

test "findMatches: overlapping matches ('aa' in 'aaaa') all emitted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const lines = [_]StyledLine{mkLine("aaaa")};
    const view: View = .{ .unified = lines[0..] };
    const matches = try findMatches(arena_state.allocator(), view, "aa");
    try testing.expectEqual(@as(usize, 3), matches.len);
    try testing.expectEqual(@as(usize, 0), matches[0].start);
    try testing.expectEqual(@as(usize, 1), matches[1].start);
    try testing.expectEqual(@as(usize, 2), matches[2].start);
}

test "findMatches: split view matches if either pane hits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const pairs = [_]LinePair{
        .{ .left = mkLine("only left has greet"), .right = mkLine("nothing here") },
        .{ .left = mkLine("nope"), .right = mkLine("right has greet") },
        .{ .left = mkLine("nope"), .right = mkLine("nope") },
    };
    const view: View = .{ .split = pairs[0..] };
    const matches = try findMatches(arena_state.allocator(), view, "greet");
    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expectEqual(@as(usize, 0), matches[0].row);
    try testing.expectEqual(@as(usize, 1), matches[1].row);
}

test "matchesOnLine: empty query, empty result" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const spans = try matchesOnLine(arena_state.allocator(), "hello", "");
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "matchesOnLine: query longer than text → no hit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const spans = try matchesOnLine(arena_state.allocator(), "hi", "hello");
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "matchesOnLine: spans cover each hit and are sorted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const spans = try matchesOnLine(arena_state.allocator(), "ab-ab-cab", "ab");
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqual(@as(u32, 0), spans[0].start);
    try testing.expectEqual(@as(u32, 2), spans[0].end);
    try testing.expectEqual(@as(u32, 3), spans[1].start);
    try testing.expectEqual(@as(u32, 7), spans[2].start);
}

test "nextMatchIndex: empty → null" {
    try testing.expectEqual(@as(?usize, null), nextMatchIndex(&.{}, 0));
}

test "nextMatchIndex: advances past cursor row, wraps at end" {
    const matches = [_]Match{
        .{ .row = 2, .start = 0, .end = 1 },
        .{ .row = 5, .start = 0, .end = 1 },
        .{ .row = 10, .start = 0, .end = 1 },
    };
    try testing.expectEqual(@as(?usize, 0), nextMatchIndex(matches[0..], 0));
    try testing.expectEqual(@as(?usize, 1), nextMatchIndex(matches[0..], 2));
    try testing.expectEqual(@as(?usize, 1), nextMatchIndex(matches[0..], 4));
    try testing.expectEqual(@as(?usize, 2), nextMatchIndex(matches[0..], 5));
    // Past the last match → wrap to 0.
    try testing.expectEqual(@as(?usize, 0), nextMatchIndex(matches[0..], 999));
}

test "prevMatchIndex: empty → null" {
    try testing.expectEqual(@as(?usize, null), prevMatchIndex(&.{}, 0));
}

test "prevMatchIndex: walks back past cursor row, wraps at start" {
    const matches = [_]Match{
        .{ .row = 2, .start = 0, .end = 1 },
        .{ .row = 5, .start = 0, .end = 1 },
        .{ .row = 10, .start = 0, .end = 1 },
    };
    try testing.expectEqual(@as(?usize, 1), prevMatchIndex(matches[0..], 10));
    try testing.expectEqual(@as(?usize, 1), prevMatchIndex(matches[0..], 8));
    try testing.expectEqual(@as(?usize, 0), prevMatchIndex(matches[0..], 5));
    // Before the first match → wrap to last.
    try testing.expectEqual(@as(?usize, 2), prevMatchIndex(matches[0..], 0));
}

test "firstMatchAtOrAfter: returns nearest hit without wrapping when possible" {
    const matches = [_]Match{
        .{ .row = 2, .start = 0, .end = 1 },
        .{ .row = 5, .start = 0, .end = 1 },
    };
    try testing.expectEqual(@as(?usize, 0), firstMatchAtOrAfter(matches[0..], 0));
    try testing.expectEqual(@as(?usize, 0), firstMatchAtOrAfter(matches[0..], 2));
    try testing.expectEqual(@as(?usize, 1), firstMatchAtOrAfter(matches[0..], 3));
    // Past the last match → wrap so the cursor still lands on a hit.
    try testing.expectEqual(@as(?usize, 0), firstMatchAtOrAfter(matches[0..], 999));
    try testing.expectEqual(@as(?usize, null), firstMatchAtOrAfter(&.{}, 0));
}

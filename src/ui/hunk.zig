//! Line-level Longest Common Subsequence over two byte slices.
//!
//! Used by `src/ui/line.zig` to render a git-style hunk for
//! `changed.body.leaf` entries: instead of dumping the full old body
//! followed by the full new body, lines that appear identically in both
//! sides collapse into `.common` entries and only the actual changes
//! surface as `.left` (removed) / `.right` (added) entries.
//!
//! Algorithm: standard O(m*n) dynamic programming. Inputs are at most a
//! function body (≤ a few hundred lines) so the quadratic table is fine
//! and not worth the complexity of Myers or Hunt-McIlroy.
//!
//! `text` on each `HunkLine` is a raw slice (no trailing `\n`) into the
//! caller's `left_slice` / `right_slice`; common lines are taken from the
//! left slice by convention. No bytes are copied or tab-expanded here -
//! that is `line.zig`'s job once per emitted row. `offset` is the line's
//! byte offset inside its source slice so callers can translate per-line
//! novel-span / highlight ranges back to absolute source coordinates.

const std = @import("std");

pub const Side = enum { common, left, right };

pub const HunkLine = struct {
    side: Side,
    text: []const u8,
    offset: u32,
};

pub fn hunk(
    arena: std.mem.Allocator,
    left_slice: []const u8,
    right_slice: []const u8,
) ![]const HunkLine {
    const left_lines = try splitLines(arena, left_slice);
    const right_lines = try splitLines(arena, right_slice);
    return try computeLcs(arena, left_lines, right_lines);
}

const SourceLine = struct { text: []const u8, offset: u32 };

/// Split a byte slice on `\n` into raw line slices (newline stripped).
/// A trailing `\n` does not produce a phantom empty line at the end,
/// mirroring the emission logic in `line.zig::sourceLinesSlice`.
fn splitLines(arena: std.mem.Allocator, slice: []const u8) ![]const SourceLine {
    var out: std.ArrayList(SourceLine) = .empty;
    if (slice.len == 0) return try out.toOwnedSlice(arena);
    var cursor: usize = 0;
    var first = true;
    while (true) {
        const rest = slice[cursor..];
        const nl_rel = std.mem.indexOfScalar(u8, rest, '\n');
        const raw = if (nl_rel) |p| rest[0..p] else rest;
        if (raw.len == 0 and nl_rel == null and !first) break;
        first = false;
        try out.append(arena, .{ .text = raw, .offset = @intCast(cursor) });
        if (nl_rel) |p| {
            cursor += p + 1;
        } else break;
    }
    return try out.toOwnedSlice(arena);
}

fn computeLcs(
    arena: std.mem.Allocator,
    left_lines: []const SourceLine,
    right_lines: []const SourceLine,
) ![]const HunkLine {
    const m = left_lines.len;
    const n = right_lines.len;
    const stride = n + 1;

    // dp[i * stride + j] = LCS length of left[..i] and right[..j].
    const dp = try arena.alloc(u32, (m + 1) * stride);
    defer arena.free(dp);
    @memset(dp, 0);

    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            if (std.mem.eql(u8, left_lines[i - 1].text, right_lines[j - 1].text)) {
                dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1;
            } else {
                dp[i * stride + j] = @max(
                    dp[(i - 1) * stride + j],
                    dp[i * stride + (j - 1)],
                );
            }
        }
    }

    // Backtrack from (m, n) to produce the edit script. Ties are broken
    // toward `.right` first (consumes new-side lines earlier), which keeps
    // the visual order consistent with git's usual "- before +" when there
    // are no common anchors.
    var out: std.ArrayList(HunkLine) = .empty;
    var ii: usize = m;
    var jj: usize = n;
    while (ii > 0 or jj > 0) {
        if (ii > 0 and jj > 0 and std.mem.eql(u8, left_lines[ii - 1].text, right_lines[jj - 1].text)) {
            const l = left_lines[ii - 1];
            try out.append(arena, .{ .side = .common, .text = l.text, .offset = l.offset });
            ii -= 1;
            jj -= 1;
        } else if (jj > 0 and (ii == 0 or dp[ii * stride + (jj - 1)] >= dp[(ii - 1) * stride + jj])) {
            const r = right_lines[jj - 1];
            try out.append(arena, .{ .side = .right, .text = r.text, .offset = r.offset });
            jj -= 1;
        } else {
            const l = left_lines[ii - 1];
            try out.append(arena, .{ .side = .left, .text = l.text, .offset = l.offset });
            ii -= 1;
        }
    }
    std.mem.reverse(HunkLine, out.items);
    return try out.toOwnedSlice(arena);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "hunk: identical slices → every line is .common" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const src = "line one\nline two\nline three";
    const out = try hunk(a, src, src);

    try testing.expectEqual(@as(usize, 3), out.len);
    for (out) |h| try testing.expectEqual(Side.common, h.side);
    try testing.expectEqualStrings("line one", out[0].text);
    try testing.expectEqualStrings("line two", out[1].text);
    try testing.expectEqualStrings("line three", out[2].text);
}

test "hunk: disjoint slices → all .left followed by all .right, no .common" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const left = "alpha\nbeta";
    const right = "gamma\ndelta";
    const out = try hunk(a, left, right);

    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqual(Side.left, out[0].side);
    try testing.expectEqualStrings("alpha", out[0].text);
    try testing.expectEqual(Side.left, out[1].side);
    try testing.expectEqualStrings("beta", out[1].text);
    try testing.expectEqual(Side.right, out[2].side);
    try testing.expectEqualStrings("gamma", out[2].text);
    try testing.expectEqual(Side.right, out[3].side);
    try testing.expectEqualStrings("delta", out[3].text);
}

test "hunk: single-line edit in middle of 10-line body → surrounding lines stay .common" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const before =
        \\line 0
        \\line 1
        \\line 2
        \\line 3
        \\line 4
        \\changed_old
        \\line 6
        \\line 7
        \\line 8
        \\line 9
    ;
    const after =
        \\line 0
        \\line 1
        \\line 2
        \\line 3
        \\line 4
        \\changed_new
        \\line 6
        \\line 7
        \\line 8
        \\line 9
    ;

    const out = try hunk(a, before, after);

    var common: usize = 0;
    var lefts: usize = 0;
    var rights: usize = 0;
    for (out) |h| switch (h.side) {
        .common => common += 1,
        .left => lefts += 1,
        .right => rights += 1,
    };
    try testing.expectEqual(@as(usize, 9), common);
    try testing.expectEqual(@as(usize, 1), lefts);
    try testing.expectEqual(@as(usize, 1), rights);

    for (out) |h| if (h.side == .left) {
        try testing.expectEqualStrings("changed_old", h.text);
    };
    for (out) |h| if (h.side == .right) {
        try testing.expectEqualStrings("changed_new", h.text);
    };
}

test "hunk: prefix added → original lines stay .common, new lines emit as .right" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const before = "keep 1\nkeep 2";
    const after = "new 0\nkeep 1\nkeep 2";
    const out = try hunk(a, before, after);

    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(Side.right, out[0].side);
    try testing.expectEqualStrings("new 0", out[0].text);
    try testing.expectEqual(Side.common, out[1].side);
    try testing.expectEqual(Side.common, out[2].side);
}

test "hunk: offset points at the line's start inside its source slice" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // "abc\nde\nf" - line offsets 0, 4, 7.
    const src = "abc\nde\nf";
    const out = try hunk(a, src, src);

    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(u32, 0), out[0].offset);
    try testing.expectEqual(@as(u32, 4), out[1].offset);
    try testing.expectEqual(@as(u32, 7), out[2].offset);
}

test "hunk: trailing newline does not yield a phantom empty line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const src = "only\n";
    const out = try hunk(a, src, src);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("only", out[0].text);
}

test "hunk: empty inputs → empty output" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out = try hunk(a, "", "");
    try testing.expectEqual(@as(usize, 0), out.len);
}

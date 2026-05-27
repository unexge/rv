//! Codepoint-level Longest Common Subsequence over two `[]const u8`.
//!
//! Used by `src/ui/line.zig` to render an inline word-diff for a 1:1
//! adjacent `.left` / `.right` pair from `hunk.zig`: instead of emitting
//! the two lines as separate `-` / `+` rows, we splice the bytes of both
//! sides into a single row with the differing runs tagged as
//! `.removed` / `.added` and the shared runs tagged `.common`.
//!
//! Algorithm: standard O(m*n) dynamic programming. The DP grid runs
//! over UTF-8 codepoints (not raw bytes) so a removed/added boundary
//! never lands mid-codepoint and the renderer can never emit a broken
//! char. Match cells store byte ranges, so the output `Run.bytes`
//! still slices into the original input buffers verbatim. Inputs are
//! at most one source line (≤ a few hundred bytes after tab expansion
//! is still small) so the quadratic table is fine.
//!
//! Invalid UTF-8: if either side fails to validate we fall back to a
//! byte-level DP. This keeps the function total even if upstream feeds
//! us garbage; well-formed source code never hits the fallback.
//!
//! Returned `Run.bytes` slices borrow from the input `left` / `right`
//! slices: `.removed` runs point into `left`, `.added` runs point into
//! `right`, and `.common` runs point into `left` by convention (the
//! bytes are equal on both sides by definition).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Side = enum { common, removed, added };

pub const Run = struct {
    side: Side,
    bytes: []const u8,
};

/// Compute the codepoint-level diff. Output is in source order: a
/// sequence of runs whose concatenation reconstructs `left` (taking
/// `.common` and `.removed`) and `right` (taking `.common` and
/// `.added`). Adjacent runs with the same `.side` are coalesced.
pub fn diff(arena: Allocator, left: []const u8, right: []const u8) ![]const Run {
    if (left.len == 0 and right.len == 0) return &.{};

    var out: std.ArrayList(Run) = .empty;

    if (left.len == 0) {
        try out.append(arena, .{ .side = .added, .bytes = right });
        return try out.toOwnedSlice(arena);
    }
    if (right.len == 0) {
        try out.append(arena, .{ .side = .removed, .bytes = left });
        return try out.toOwnedSlice(arena);
    }

    // Walk each input as codepoints. If either side fails to validate,
    // fall back to a byte-level grid (preserves the previous behaviour
    // for malformed inputs, which never appear in real source code).
    if (!std.unicode.utf8ValidateSlice(left) or !std.unicode.utf8ValidateSlice(right)) {
        return diffBytes(arena, left, right);
    }

    const left_units = try buildUnits(arena, left);
    const right_units = try buildUnits(arena, right);
    return diffUnits(arena, left, right, left_units, right_units);
}

/// Byte range of one codepoint inside its source buffer. `len` is the
/// UTF-8 byte length (1..4); the codepoint value itself is recovered
/// by slicing the source on demand. Stored as a struct (rather than
/// the decoded `u21`) so DP comparisons can reuse the compact byte
/// slice via `std.mem.eql`, which is cheaper than decoding twice.
const Unit = struct { start: u32, len: u8 };

fn buildUnits(arena: Allocator, s: []const u8) ![]Unit {
    var out: std.ArrayList(Unit) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch unreachable;
        try out.append(arena, .{ .start = @intCast(i), .len = len });
        i += len;
    }
    return out.toOwnedSlice(arena);
}

fn unitBytes(buf: []const u8, u: Unit) []const u8 {
    return buf[u.start .. u.start + u.len];
}

fn diffUnits(
    arena: Allocator,
    left: []const u8,
    right: []const u8,
    lu: []const Unit,
    ru: []const Unit,
) ![]const Run {
    const m = lu.len;
    const n = ru.len;
    const stride = n + 1;

    // dp[i * stride + j] = LCS length (in codepoints) of lu[..i] and
    // ru[..j].
    const dp = try arena.alloc(u32, (m + 1) * stride);
    defer arena.free(dp);
    @memset(dp, 0);

    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            if (std.mem.eql(u8, unitBytes(left, lu[i - 1]), unitBytes(right, ru[j - 1]))) {
                dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1;
            } else {
                dp[i * stride + j] = @max(
                    dp[(i - 1) * stride + j],
                    dp[i * stride + (j - 1)],
                );
            }
        }
    }

    // Backtrack from (m, n). Append per-codepoint edits in reverse
    // order, coalescing consecutive same-side units by extending the
    // previous run's slice start (the new unit sits immediately to the
    // left of it in the source buffer because we step backwards through
    // the input). Finally reverse so the output is in forward order.
    var out: std.ArrayList(Run) = .empty;
    var ii: usize = m;
    var jj: usize = n;
    while (ii > 0 or jj > 0) {
        var side: Side = undefined;
        var bytes: []const u8 = undefined;
        if (ii > 0 and jj > 0 and
            std.mem.eql(u8, unitBytes(left, lu[ii - 1]), unitBytes(right, ru[jj - 1])))
        {
            side = .common;
            bytes = unitBytes(left, lu[ii - 1]);
            ii -= 1;
            jj -= 1;
        } else if (jj > 0 and (ii == 0 or
            dp[ii * stride + (jj - 1)] >= dp[(ii - 1) * stride + jj]))
        {
            side = .added;
            bytes = unitBytes(right, ru[jj - 1]);
            jj -= 1;
        } else {
            side = .removed;
            bytes = unitBytes(left, lu[ii - 1]);
            ii -= 1;
        }

        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.side == side and bytes.ptr + bytes.len == last.bytes.ptr) {
                last.bytes = bytes.ptr[0 .. bytes.len + last.bytes.len];
                continue;
            }
        }
        try out.append(arena, .{ .side = side, .bytes = bytes });
    }
    std.mem.reverse(Run, out.items);
    return try out.toOwnedSlice(arena);
}

fn diffBytes(arena: Allocator, left: []const u8, right: []const u8) ![]const Run {
    const m = left.len;
    const n = right.len;
    const stride = n + 1;

    const dp = try arena.alloc(u32, (m + 1) * stride);
    defer arena.free(dp);
    @memset(dp, 0);

    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            if (left[i - 1] == right[j - 1]) {
                dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1;
            } else {
                dp[i * stride + j] = @max(
                    dp[(i - 1) * stride + j],
                    dp[i * stride + (j - 1)],
                );
            }
        }
    }

    var out: std.ArrayList(Run) = .empty;
    var ii: usize = m;
    var jj: usize = n;
    while (ii > 0 or jj > 0) {
        var side: Side = undefined;
        var bytes: []const u8 = undefined;
        if (ii > 0 and jj > 0 and left[ii - 1] == right[jj - 1]) {
            side = .common;
            bytes = left[ii - 1 .. ii];
            ii -= 1;
            jj -= 1;
        } else if (jj > 0 and (ii == 0 or
            dp[ii * stride + (jj - 1)] >= dp[(ii - 1) * stride + jj]))
        {
            side = .added;
            bytes = right[jj - 1 .. jj];
            jj -= 1;
        } else {
            side = .removed;
            bytes = left[ii - 1 .. ii];
            ii -= 1;
        }

        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.side == side and bytes.ptr + bytes.len == last.bytes.ptr) {
                last.bytes = bytes.ptr[0 .. bytes.len + last.bytes.len];
                continue;
            }
        }
        try out.append(arena, .{ .side = side, .bytes = bytes });
    }
    std.mem.reverse(Run, out.items);
    return try out.toOwnedSlice(arena);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "diff: identical inputs → one common run" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out = try diff(a, "hello", "hello");
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(Side.common, out[0].side);
    try testing.expectEqualStrings("hello", out[0].bytes);
}

test "diff: disjoint inputs → one removed run + one added run" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out = try diff(a, "abc", "xyz");
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(Side.removed, out[0].side);
    try testing.expectEqualStrings("abc", out[0].bytes);
    try testing.expectEqual(Side.added, out[1].side);
    try testing.expectEqualStrings("xyz", out[1].bytes);
}

test "diff: interleaved single-byte substitution" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // axb vs ayb → common(a), removed(x), added(y), common(b).
    const out = try diff(a, "axb", "ayb");
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqual(Side.common, out[0].side);
    try testing.expectEqualStrings("a", out[0].bytes);
    try testing.expectEqual(Side.removed, out[1].side);
    try testing.expectEqualStrings("x", out[1].bytes);
    try testing.expectEqual(Side.added, out[2].side);
    try testing.expectEqualStrings("y", out[2].bytes);
    try testing.expectEqual(Side.common, out[3].side);
    try testing.expectEqualStrings("b", out[3].bytes);
}

test "diff: empty inputs → empty output" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out = try diff(a, "", "");
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "diff: empty left + non-empty right → one added run" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out = try diff(a, "", "hi");
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(Side.added, out[0].side);
    try testing.expectEqualStrings("hi", out[0].bytes);
}

test "diff: empty right + non-empty left → one removed run" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out = try diff(a, "hi", "");
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(Side.removed, out[0].side);
    try testing.expectEqualStrings("hi", out[0].bytes);
}

test "diff: pure insertion in the middle" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // "foo bar" vs "foo bar baz": common("foo bar") + added(" baz").
    const out = try diff(a, "foo bar", "foo bar baz");
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(Side.common, out[0].side);
    try testing.expectEqualStrings("foo bar", out[0].bytes);
    try testing.expectEqual(Side.added, out[1].side);
    try testing.expectEqualStrings(" baz", out[1].bytes);
}

test "diff: pure deletion in the middle" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // "foo bar baz" vs "foo baz": common("foo "), removed("bar "), common("baz").
    const out = try diff(a, "foo bar baz", "foo baz");
    var common_total: usize = 0;
    var removed_total: usize = 0;
    for (out) |r| switch (r.side) {
        .common => common_total += r.bytes.len,
        .removed => removed_total += r.bytes.len,
        .added => try testing.expect(false),
    };
    try testing.expectEqual(@as(usize, 7), common_total);
    try testing.expectEqual(@as(usize, 4), removed_total);
}

test "diff: reconstructs both inputs from runs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const left = "fn encode(document: &Foo) -> Vec<u8>";
    const right = "fn encode(document: &Bar) -> Vec<u8>";
    const runs = try diff(a, left, right);

    var rebuilt_left: std.ArrayList(u8) = .empty;
    var rebuilt_right: std.ArrayList(u8) = .empty;
    for (runs) |r| switch (r.side) {
        .common => {
            try rebuilt_left.appendSlice(a, r.bytes);
            try rebuilt_right.appendSlice(a, r.bytes);
        },
        .removed => try rebuilt_left.appendSlice(a, r.bytes),
        .added => try rebuilt_right.appendSlice(a, r.bytes),
    };
    try testing.expectEqualStrings(left, rebuilt_left.items);
    try testing.expectEqualStrings(right, rebuilt_right.items);
}

// ── codepoint-aware behaviour ─────────────────────────────────────────────

/// Every emitted run's `bytes` must be valid UTF-8 - the codepoint-
/// aware grid guarantees no run boundary lands mid-codepoint.
fn expectAllRunsValidUtf8(runs: []const Run) !void {
    for (runs) |r| try testing.expect(std.unicode.utf8ValidateSlice(r.bytes));
}

test "diff: codepoint substitution αβγ vs αδγ - runs split on codepoint boundaries" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out = try diff(a, "αβγ", "αδγ");
    try expectAllRunsValidUtf8(out);

    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqual(Side.common, out[0].side);
    try testing.expectEqualStrings("α", out[0].bytes);
    try testing.expectEqual(Side.removed, out[1].side);
    try testing.expectEqualStrings("β", out[1].bytes);
    try testing.expectEqual(Side.added, out[2].side);
    try testing.expectEqualStrings("δ", out[2].bytes);
    try testing.expectEqual(Side.common, out[3].side);
    try testing.expectEqualStrings("γ", out[3].bytes);
}

test "diff: ASCII + non-ASCII identifier - café vs cafe pairs the é as one removed run" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const left = "let café = ...";
    const right = "let cafe = ...";
    const out = try diff(a, left, right);
    try expectAllRunsValidUtf8(out);

    // Reconstruction confirms no codepoint was split.
    var rebuilt_left: std.ArrayList(u8) = .empty;
    var rebuilt_right: std.ArrayList(u8) = .empty;
    for (out) |r| switch (r.side) {
        .common => {
            try rebuilt_left.appendSlice(a, r.bytes);
            try rebuilt_right.appendSlice(a, r.bytes);
        },
        .removed => try rebuilt_left.appendSlice(a, r.bytes),
        .added => try rebuilt_right.appendSlice(a, r.bytes),
    };
    try testing.expectEqualStrings(left, rebuilt_left.items);
    try testing.expectEqualStrings(right, rebuilt_right.items);

    // The differing codepoints (é vs e) each surface as a single-
    // codepoint run, never half a sequence.
    var saw_eacute_removed = false;
    var saw_e_added = false;
    for (out) |r| switch (r.side) {
        .removed => if (std.mem.eql(u8, r.bytes, "é")) {
            saw_eacute_removed = true;
        },
        .added => if (std.mem.eql(u8, r.bytes, "e")) {
            saw_e_added = true;
        },
        .common => {},
    };
    try testing.expect(saw_eacute_removed);
    try testing.expect(saw_e_added);
}

test "diff: invalid UTF-8 falls back to byte-level (no crash, exact reconstruction)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Truncated α (0xCE alone) on the left, valid α on the right.
    const left = "\xCEx";
    const right = "αx";
    const out = try diff(a, left, right);

    var rebuilt_left: std.ArrayList(u8) = .empty;
    var rebuilt_right: std.ArrayList(u8) = .empty;
    for (out) |r| switch (r.side) {
        .common => {
            try rebuilt_left.appendSlice(a, r.bytes);
            try rebuilt_right.appendSlice(a, r.bytes);
        },
        .removed => try rebuilt_left.appendSlice(a, r.bytes),
        .added => try rebuilt_right.appendSlice(a, r.bytes),
    };
    try testing.expectEqualStrings(left, rebuilt_left.items);
    try testing.expectEqualStrings(right, rebuilt_right.items);
}

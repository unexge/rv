//! Line-level alignment within a multi-line `.left` / `.right` run.
//!
//! Phase 1's word-diff (`word_lcs.zig` + `tryBuildInlineCollapsedLine`)
//! collapses an immediately-adjacent 1:1 `.left` / `.right` pair from
//! `hunk.zig` into one inline row. It cannot help when the pair-able
//! lines are buried inside a larger run alongside other non-pair-able
//! lines: e.g. a function whose signature changed (one obvious pair)
//! and whose body was rewritten in several places (more pairs + some
//! unpaired lines on either side).
//!
//! This module runs a second LCS DP over the run, this time using
//! byte-level similarity (not byte equality) as the match relation:
//! two raw lines `a` and `b` are considered a pair when
//! `shared_bytes / min(|a|, |b|) >= 0.5` - the same threshold the
//! 1:1 collapse uses.
//!
//! Output is an alignment script: a sequence of `.pair`, `.left_only`,
//! and `.right_only` ops in run order. The caller (`buildLeafHunk`)
//! walks the script, splicing pairs into single inline rows and
//! emitting unpaired lines as plain `.removed` / `.added` rows.
//!
//! Tie-breaking: the DP cell stores the maximum *sum of similarities*
//! along any matched-pair subsequence, not just the count. Among
//! equal-count solutions the one whose pairs collectively share the
//! most bytes wins, so a left line with a clear best partner doesn't
//! get matched against a weaker candidate just because it appeared
//! first in the run.
//!
//! Performance: similarity is computed once per (i, j) cell into a
//! pre-allocated `m * n` matrix; the matrix fill is O(m*n) byte-LCS
//! calls, each O(|a|*|b|). For run sizes up to a few dozen lines on
//! either side this is well within budget for a TUI.

const std = @import("std");

const word_lcs = @import("word_lcs.zig");

const Allocator = std.mem.Allocator;

/// One step in the alignment script.
pub const AlignOp = union(enum) {
    /// `lefts[left_idx]` is paired with `rights[right_idx]` and the
    /// caller may collapse them into a single inline row.
    pair: struct { left_idx: usize, right_idx: usize },
    /// `lefts[idx]` has no counterpart on the right; emit as `.removed`.
    left_only: usize,
    /// `rights[idx]` has no counterpart on the left; emit as `.added`.
    right_only: usize,
};

/// Pair-acceptance threshold expressed as `shared * 2 >= min_len`
/// (i.e. similarity >= 0.5). Same value as the 1:1 collapse path so
/// the two alignment passes agree on what constitutes a pair.
const pair_threshold: f32 = 0.5;

/// Produce an alignment script for a `.left` / `.right` run.
///
/// Inputs are the raw line bytes (newline stripped, no tab expansion)
/// in source order. Output ops are also in source order: pairs sit
/// where the alignment picked them, unpaired lefts/rights fill the
/// gaps in between.
pub fn alignLines(
    arena: Allocator,
    lefts: []const []const u8,
    rights: []const []const u8,
) ![]const AlignOp {
    if (lefts.len == 0 and rights.len == 0) return &.{};
    if (lefts.len == 0) {
        const out = try arena.alloc(AlignOp, rights.len);
        for (out, 0..) |*op, i| op.* = .{ .right_only = i };
        return out;
    }
    if (rights.len == 0) {
        const out = try arena.alloc(AlignOp, lefts.len);
        for (out, 0..) |*op, i| op.* = .{ .left_only = i };
        return out;
    }

    const m = lefts.len;
    const n = rights.len;

    // Pre-compute per-cell similarity. `sim[i*n + j]` is the similarity
    // of `lefts[i]` and `rights[j]`; values < threshold are clamped to
    // 0 so the DP doesn't accumulate sub-threshold pairs.
    const sim = try arena.alloc(f32, m * n);
    defer arena.free(sim);
    for (lefts, 0..) |l, i| {
        for (rights, 0..) |r, j| {
            const s = try similarity(arena, l, r);
            sim[i * n + j] = if (s >= pair_threshold) s else 0.0;
        }
    }

    // dp[i][j] = max sum of similarities along any matched-pair
    // subsequence using `lefts[..i]` and `rights[..j]`. Unlike a plain
    // LCS we maximise the cumulative similarity instead of the pair
    // count, which gives us a natural tie-break: among equal-count
    // alignments the one with stronger pair-wise matches wins.
    const stride = n + 1;
    const dp = try arena.alloc(f32, (m + 1) * stride);
    defer arena.free(dp);
    @memset(dp, 0.0);

    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            const skip = @max(dp[(i - 1) * stride + j], dp[i * stride + (j - 1)]);
            const s = sim[(i - 1) * n + (j - 1)];
            if (s > 0.0) {
                const take = dp[(i - 1) * stride + (j - 1)] + s;
                dp[i * stride + j] = @max(skip, take);
            } else {
                dp[i * stride + j] = skip;
            }
        }
    }

    var out: std.ArrayList(AlignOp) = .empty;
    var ii: usize = m;
    var jj: usize = n;
    while (ii > 0 or jj > 0) {
        if (ii > 0 and jj > 0) {
            const s = sim[(ii - 1) * n + (jj - 1)];
            if (s > 0.0 and dp[ii * stride + jj] == dp[(ii - 1) * stride + (jj - 1)] + s) {
                try out.append(arena, .{ .pair = .{
                    .left_idx = ii - 1,
                    .right_idx = jj - 1,
                } });
                ii -= 1;
                jj -= 1;
                continue;
            }
        }
        if (jj > 0 and (ii == 0 or
            dp[ii * stride + (jj - 1)] >= dp[(ii - 1) * stride + jj]))
        {
            try out.append(arena, .{ .right_only = jj - 1 });
            jj -= 1;
        } else {
            try out.append(arena, .{ .left_only = ii - 1 });
            ii -= 1;
        }
    }
    std.mem.reverse(AlignOp, out.items);
    return try out.toOwnedSlice(arena);
}

/// Byte-level similarity in `[0, 1]`: shared bytes (per `word_lcs.diff`)
/// divided by the shorter input's length. Defined as 0 when either side
/// is empty so empty/non-empty pairs never cross the threshold.
fn similarity(arena: Allocator, a: []const u8, b: []const u8) !f32 {
    const min_len = @min(a.len, b.len);
    if (min_len == 0) return 0.0;

    const runs = try word_lcs.diff(arena, a, b);
    var shared: usize = 0;
    for (runs) |r| if (r.side == .common) {
        shared += r.bytes.len;
    };
    return @as(f32, @floatFromInt(shared)) / @as(f32, @floatFromInt(min_len));
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectPair(op: AlignOp, left_idx: usize, right_idx: usize) !void {
    try testing.expect(op == .pair);
    try testing.expectEqual(left_idx, op.pair.left_idx);
    try testing.expectEqual(right_idx, op.pair.right_idx);
}

fn expectLeftOnly(op: AlignOp, idx: usize) !void {
    try testing.expect(op == .left_only);
    try testing.expectEqual(idx, op.left_only);
}

fn expectRightOnly(op: AlignOp, idx: usize) !void {
    try testing.expect(op == .right_only);
    try testing.expectEqual(idx, op.right_only);
}

test "alignLines: 1:1 inside a 1+1 run → one pair" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lefts = [_][]const u8{"fn make() -> Foo {"};
    const rights = [_][]const u8{"fn make() -> Bar {"};

    const ops = try alignLines(a, &lefts, &rights);
    try testing.expectEqual(@as(usize, 1), ops.len);
    try expectPair(ops[0], 0, 0);
}

test "alignLines: 2:2 with each pair similar → two pairs in order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lefts = [_][]const u8{
        "/// Old comment for Foo",
        "fn make() -> Foo {",
    };
    const rights = [_][]const u8{
        "/// New comment for Bar",
        "fn make() -> Bar {",
    };

    const ops = try alignLines(a, &lefts, &rights);
    try testing.expectEqual(@as(usize, 2), ops.len);
    try expectPair(ops[0], 0, 0);
    try expectPair(ops[1], 1, 1);
}

test "alignLines: 4:1 asymmetric chain → only the strongest pair survives" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Each left chain fragment is a substring of the merged right line,
    // so all four similarities are ≥ 0.5. Monotonic LCS picks at most
    // one of them; the rest become left_only. The ratio test (4 lefts
    // + 1 right ⇒ 5 ops, exactly one pair) is the contract.
    const lefts = [_][]const u8{
        "    let x = a()",
        "        .b()",
        "        .c()",
        "        .d();",
    };
    const rights = [_][]const u8{"    let x = a().b().c().d();"};

    const ops = try alignLines(a, &lefts, &rights);
    // 4 lefts + 1 right, exactly one monotonic pair ⇒ 1 pair + 3
    // left_only = 4 ops total.
    try testing.expectEqual(@as(usize, 4), ops.len);

    var pair_count: usize = 0;
    var left_count: usize = 0;
    var right_count: usize = 0;
    for (ops) |op| switch (op) {
        .pair => pair_count += 1,
        .left_only => left_count += 1,
        .right_only => right_count += 1,
    };
    try testing.expectEqual(@as(usize, 1), pair_count);
    try testing.expectEqual(@as(usize, 3), left_count);
    try testing.expectEqual(@as(usize, 0), right_count);
}

test "alignLines: 4:1 disjoint shapes → no pair" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Genuinely dissimilar shapes: every left/right pair is far below
    // the 0.5 threshold, so no monotonic alignment exists.
    const lefts = [_][]const u8{
        "AAAAAAAAAAAAA",
        "BBBBBBBBBBBBB",
        "CCCCCCCCCCCCC",
        "DDDDDDDDDDDDD",
    };
    const rights = [_][]const u8{"!@#$%^&*()-_=+"};

    const ops = try alignLines(a, &lefts, &rights);
    try testing.expectEqual(@as(usize, 5), ops.len);
    for (ops) |op| try testing.expect(op != .pair);
}

test "alignLines: 5:5 disjoint → no pairs, all unpaired" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lefts = [_][]const u8{
        "AAAAAAAAAAAAA",
        "BBBBBBBBBBBBB",
        "CCCCCCCCCCCCC",
        "DDDDDDDDDDDDD",
        "EEEEEEEEEEEEE",
    };
    const rights = [_][]const u8{
        "1111111111",
        "2222222222",
        "3333333333",
        "4444444444",
        "5555555555",
    };

    const ops = try alignLines(a, &lefts, &rights);
    try testing.expectEqual(@as(usize, 10), ops.len);
    for (ops) |op| try testing.expect(op != .pair);
}

test "alignLines: reordered identical lines: every input referenced exactly once" {
    // Reordered identical lines should normally be handled by the
    // linewise hunker via byte-equality and never reach line_align.
    // If they ever do, line_align must not crash and must produce a
    // sensible alignment (every line accounted for, paired identicals
    // collapse).
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lefts = [_][]const u8{ "a;", "b;", "c;" };
    const rights = [_][]const u8{ "b;", "a;", "c;" };

    const ops = try alignLines(a, &lefts, &rights);
    // LCS-like alignment maximises monotonic pairs: it can pair `c` and
    // either `a` or `b` (one gets dropped to keep the order). What we
    // care about is that every input is referenced exactly once.
    var seen_left = [_]bool{ false, false, false };
    var seen_right = [_]bool{ false, false, false };
    for (ops) |op| switch (op) {
        .pair => |p| {
            seen_left[p.left_idx] = true;
            seen_right[p.right_idx] = true;
        },
        .left_only => |i| seen_left[i] = true,
        .right_only => |i| seen_right[i] = true,
    };
    for (seen_left) |s| try testing.expect(s);
    for (seen_right) |s| try testing.expect(s);
}

test "alignLines: mixed pair/no-pair inside one run" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Modelled on the task's mixed scenario: signature change, body
    // rewritten in several places, plus a chained-call run that
    // collapsed onto one line on the right. The exact pairing of the
    // chain lines is sensitive to the prefix-similarity metric (a
    // short left line that is a substring of a longer right line
    // still scores 1.0); what we assert here is the set of obvious
    // pairs every reasonable algorithm must pick, plus that the
    // genuinely unpaired `extra: 1,` left line stays unpaired.
    const lefts = [_][]const u8{
        "fn make() -> Foo {", // L0 pairs with R0
        "    let x = chain()",
        "        .step1()",
        "        .step2();",
        "    insert(Foo::wrap(k), v);", // L4 pairs with R2
        "    Foo {", // L5 pairs with R3
        "        field_a: wrap(x),", // L6 pairs with R4
        "        field_b: Old::default(),", // L7 pairs with R5
        "        extra_marker_xyz123,", // L8 unpaired
    };
    const rights = [_][]const u8{
        "fn make() -> Bar {", // R0
        "    let x = chain().step1().step2();", // R1
        "    insert(k, v);", // R2
        "    Bar {", // R3
        "        field_a: x,", // R4
        "        field_b: New::default(),", // R5
    };

    const ops = try alignLines(a, &lefts, &rights);

    var paired_left = [_]bool{false} ** lefts.len;
    var paired_right = [_]bool{false} ** rights.len;
    for (ops) |op| switch (op) {
        .pair => |p| {
            paired_left[p.left_idx] = true;
            paired_right[p.right_idx] = true;
        },
        else => {},
    };

    // Five obvious pairs the alignment must pick.
    try testing.expect(paired_left[0] and paired_right[0]);
    try testing.expect(paired_left[4] and paired_right[2]);
    try testing.expect(paired_left[5] and paired_right[3]);
    try testing.expect(paired_left[6] and paired_right[4]);
    try testing.expect(paired_left[7] and paired_right[5]);

    // The trailing `extra_marker_xyz123,` line has no counterpart on
    // the right and must stay unpaired regardless of the chain
    // resolution.
    try testing.expect(!paired_left[8]);

    // Every input is referenced exactly once across the script.
    var seen_left = [_]bool{false} ** lefts.len;
    var seen_right = [_]bool{false} ** rights.len;
    for (ops) |op| switch (op) {
        .pair => |p| {
            seen_left[p.left_idx] = true;
            seen_right[p.right_idx] = true;
        },
        .left_only => |i| seen_left[i] = true,
        .right_only => |i| seen_right[i] = true,
    };
    for (seen_left) |s| try testing.expect(s);
    for (seen_right) |s| try testing.expect(s);

    // Pairs are monotonic in source order on both sides.
    var prev_l: ?usize = null;
    var prev_r: ?usize = null;
    for (ops) |op| if (op == .pair) {
        if (prev_l) |pl| try testing.expect(op.pair.left_idx > pl);
        if (prev_r) |pr| try testing.expect(op.pair.right_idx > pr);
        prev_l = op.pair.left_idx;
        prev_r = op.pair.right_idx;
    };
}

test "alignLines: prefers higher-similarity pair over weaker first match" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `lefts[0]` is a near-perfect match for `rights[1]` and a weak
    // match (above threshold) for `rights[0]`. With pair-count-only
    // LCS the DP can pick either; tie-broken by similarity, the
    // stronger pair wins, leaving `rights[0]` unpaired.
    const lefts = [_][]const u8{
        "let abcdefghij = something_else_long_too;",
    };
    const rights = [_][]const u8{
        "let abcdefghij = something();",
        "let abcdefghij = something_else_long_too!;",
    };

    const ops = try alignLines(a, &lefts, &rights);
    try testing.expectEqual(@as(usize, 2), ops.len);
    // Output order: right_only(0) before pair(0, 1).
    try expectRightOnly(ops[0], 0);
    try expectPair(ops[1], 0, 1);
}

test "alignLines: empty lefts → all right_only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const rights = [_][]const u8{ "x", "y" };
    const ops = try alignLines(a, &.{}, &rights);
    try testing.expectEqual(@as(usize, 2), ops.len);
    try expectRightOnly(ops[0], 0);
    try expectRightOnly(ops[1], 1);
}

test "alignLines: empty rights → all left_only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lefts = [_][]const u8{ "x", "y" };
    const ops = try alignLines(a, &lefts, &.{});
    try testing.expectEqual(@as(usize, 2), ops.len);
    try expectLeftOnly(ops[0], 0);
    try expectLeftOnly(ops[1], 1);
}

test "alignLines: empty inputs → empty output" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ops = try alignLines(a, &.{}, &.{});
    try testing.expectEqual(@as(usize, 0), ops.len);
}

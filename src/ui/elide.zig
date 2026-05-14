//! Plus/minus N context window pass over a flat `[]StyledLine` produced
//! by `file_view.zig`. Collapses long unchanged runs into a single
//! `.elided` row and assigns each gap a stable `GapId`.
//!
//! Pure: no I/O, no state mutation. Reads `state.expanded_gaps` to
//! decide whether a derived gap should stay collapsed (default) or be
//! re-expanded verbatim. All output slices and strings allocate from
//! `arena`.

const std = @import("std");

const line_mod = @import("line.zig");
const state_mod = @import("state.zig");

const Allocator = std.mem.Allocator;

/// Number of unchanged rows on each side of an anchor that always stay
/// visible. Hardcoded to 3 for v1 per the parent task's design notes.
pub const context_lines: usize = 3;

/// Sentinel substituted for `null` line numbers when hashing a gap id.
/// Real source files never reach 4 GiB / 4 G lines, so collisions with
/// genuine numbers are not a concern in practice.
const null_line_sentinel: u32 = 0xFFFF_FFFF;

/// Run the ±`context_lines` window pass over `lines`. Maximal runs of
/// rows that aren't anchors and aren't within `context_lines` of an
/// anchor collapse into a single `.elided` row, unless the gap's id is
/// in `state.expanded_gaps` - then the run is emitted verbatim.
pub fn elide(
    arena: Allocator,
    lines: []const line_mod.StyledLine,
    state: *const state_mod.AppState,
) ![]const line_mod.StyledLine {
    if (lines.len == 0) return &.{};

    // 1. Mark each row as either an anchor (must stay) or eligible.
    const kept = try arena.alloc(bool, lines.len);
    defer arena.free(kept);
    @memset(kept, false);

    // 2. Extend anchors by ±context_lines into a "kept" mask.
    for (lines, 0..) |ln, i| {
        if (!isChangeAnchor(ln)) continue;
        const lo = i -| context_lines;
        const hi_excl = @min(lines.len, i + context_lines + 1);
        var k = lo;
        while (k < hi_excl) : (k += 1) kept[k] = true;
    }

    // 3. Walk once, collapsing maximal runs of unkept rows.
    var out: std.ArrayList(line_mod.StyledLine) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        if (kept[i]) {
            try out.append(arena, lines[i]);
            i += 1;
            continue;
        }
        const run_start = i;
        while (i < lines.len and !kept[i]) : (i += 1) {}
        const run_len = i - run_start;
        const first = lines[run_start];
        const gap_id = gapIdFor(first.line_no_left, first.line_no_right);

        if (state.isGapExpanded(gap_id)) {
            try out.appendSlice(arena, lines[run_start..i]);
        } else {
            try out.append(arena, .{
                .indent = 0,
                .marker = .blank,
                .kind = .elided,
                .text = try formatElidedText(arena, run_len),
                .gap_id = gap_id,
            });
        }
    }

    return try out.toOwnedSlice(arena);
}

/// A row anchors the context window iff its marker reflects a real
/// change, OR it's a `.decl_anchor` for a non-unchanged decl. Plain
/// `.unchanged` / `.context` / `.blank` rows are eligible for elision,
/// as are decl anchors whose decl is itself unchanged.
fn isChangeAnchor(line: line_mod.StyledLine) bool {
    return switch (line.marker) {
        .added, .removed, .changed => true,
        .context, .blank => line.kind == .decl_anchor,
        .unchanged => false,
    };
}

/// Hash the bounding line numbers of a gap into a stable id. Collisions
/// across distinct gaps in the same file are acceptable - they just
/// mean toggling one expands both, which is benign.
fn gapIdFor(start_left: ?u32, start_right: ?u32) state_mod.GapId {
    var hasher: std.hash.Wyhash = .init(0);
    const l: u32 = start_left orelse null_line_sentinel;
    const r: u32 = start_right orelse null_line_sentinel;
    hasher.update(std.mem.asBytes(&l));
    hasher.update(std.mem.asBytes(&r));
    return hasher.final();
}

/// `"… N unchanged lines …"` (singular `"line"` for N==1).
fn formatElidedText(arena: Allocator, hidden_count: usize) ![]const u8 {
    const noun: []const u8 = if (hidden_count == 1) "line" else "lines";
    return try std.fmt.allocPrint(arena, "… {d} unchanged {s} …", .{ hidden_count, noun });
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Synthetic-row helper: an unchanged source line at left/right line `n`.
fn unchangedRow(n: u32) line_mod.StyledLine {
    return .{
        .indent = 0,
        .marker = .unchanged,
        .kind = .source,
        .text = "",
        .line_no_left = n,
        .line_no_right = n,
    };
}

/// Synthetic-row helper: an added source line at right line `n`.
fn addedRow(n: u32) line_mod.StyledLine {
    return .{
        .indent = 0,
        .marker = .added,
        .kind = .source,
        .text = "",
        .line_no_right = n,
    };
}

test "elide: all-unchanged input collapses to a single elided row" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();

    var input: [20]line_mod.StyledLine = undefined;
    for (&input, 0..) |*row, i| row.* = unchangedRow(@intCast(i + 1));

    const out = try elide(a, &input, &state);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(line_mod.LineKind.elided, out[0].kind);
    try testing.expectEqualStrings("… 20 unchanged lines …", out[0].text);
}

test "elide: single change in middle keeps anchor ±3 and one elided row each side" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();

    // 20 rows, row 10 is `.added`; rows 7..13 (anchor ±3) stay visible.
    var input: [20]line_mod.StyledLine = undefined;
    for (&input, 0..) |*row, i| row.* = unchangedRow(@intCast(i + 1));
    input[10] = addedRow(11);

    const out = try elide(a, &input, &state);

    // Leading elided + 7 kept rows + trailing elided.
    try testing.expectEqual(@as(usize, 9), out.len);
    try testing.expectEqual(line_mod.LineKind.elided, out[0].kind);
    try testing.expectEqualStrings("… 7 unchanged lines …", out[0].text);
    // Rows 7..13 of the input survive in the middle.
    try testing.expectEqual(line_mod.Marker.unchanged, out[1].marker);
    try testing.expectEqual(@as(?u32, 8), out[1].line_no_left);
    try testing.expectEqual(line_mod.Marker.added, out[4].marker);
    try testing.expectEqual(line_mod.Marker.unchanged, out[7].marker);
    try testing.expectEqual(@as(?u32, 14), out[7].line_no_left);
    try testing.expectEqual(line_mod.LineKind.elided, out[8].kind);
    try testing.expectEqualStrings("… 6 unchanged lines …", out[8].text);
}

test "elide: two changes within 2*context windows merge with no gap between" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();

    // Anchors at row 5 and row 9: windows 2..8 and 6..12 overlap.
    var input: [20]line_mod.StyledLine = undefined;
    for (&input, 0..) |*row, i| row.* = unchangedRow(@intCast(i + 1));
    input[5] = addedRow(6);
    input[9] = addedRow(10);

    const out = try elide(a, &input, &state);

    // No `.elided` rows between row 5 and row 9: the merged window keeps
    // rows 2..12 (11 rows) plus one elided each side.
    try testing.expectEqual(@as(usize, 13), out.len);
    try testing.expectEqual(line_mod.LineKind.elided, out[0].kind);
    var middle_elided: usize = 0;
    for (out[1 .. out.len - 1]) |r| if (r.kind == .elided) {
        middle_elided += 1;
    };
    try testing.expectEqual(@as(usize, 0), middle_elided);
    try testing.expectEqual(line_mod.LineKind.elided, out[out.len - 1].kind);
}

test "elide: change at first row → no leading elided row" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();

    var input: [20]line_mod.StyledLine = undefined;
    for (&input, 0..) |*row, i| row.* = unchangedRow(@intCast(i + 1));
    input[0] = addedRow(1);

    const out = try elide(a, &input, &state);

    try testing.expect(out[0].kind != .elided);
    try testing.expectEqual(line_mod.Marker.added, out[0].marker);
    // Trailing elided row is still present.
    try testing.expectEqual(line_mod.LineKind.elided, out[out.len - 1].kind);
}

test "elide: change at last row → no trailing elided row" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();

    var input: [20]line_mod.StyledLine = undefined;
    for (&input, 0..) |*row, i| row.* = unchangedRow(@intCast(i + 1));
    input[19] = addedRow(20);

    const out = try elide(a, &input, &state);

    try testing.expect(out[out.len - 1].kind != .elided);
    try testing.expectEqual(line_mod.Marker.added, out[out.len - 1].marker);
    try testing.expectEqual(line_mod.LineKind.elided, out[0].kind);
}

test "elide: expanded gap is emitted verbatim" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();

    // Same setup as the "single change in middle" test.
    var input: [20]line_mod.StyledLine = undefined;
    for (&input, 0..) |*row, i| row.* = unchangedRow(@intCast(i + 1));
    input[10] = addedRow(11);

    // Pre-populate the gap that *would* form on the leading run. The
    // first eligible row is input[0] (line_no_left = 1, right = 1).
    const leading_gap = gapIdFor(1, 1);
    try state.expanded_gaps.put(leading_gap, {});

    const out = try elide(a, &input, &state);

    // Leading 7 rows stay verbatim, then 7 kept anchor rows, then a
    // single trailing elided row → 7 + 7 + 1 = 15 rows.
    try testing.expectEqual(@as(usize, 15), out.len);
    for (out[0..7]) |r| try testing.expect(r.kind != .elided);
    try testing.expectEqual(line_mod.LineKind.elided, out[14].kind);
}

test "elide: 1-line gap renders singular form" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();

    // Two anchors with exactly one unchanged row between their windows.
    // Windows of size 3 around rows 0 and 8: 0..3 and 5..11. Row 4 is
    // the lone gap.
    var input: [12]line_mod.StyledLine = undefined;
    for (&input, 0..) |*row, i| row.* = unchangedRow(@intCast(i + 1));
    input[0] = addedRow(1);
    input[8] = addedRow(9);

    const out = try elide(a, &input, &state);

    var found_singular = false;
    for (out) |r| if (r.kind == .elided) {
        try testing.expectEqualStrings("… 1 unchanged line …", r.text);
        found_singular = true;
    };
    try testing.expect(found_singular);
}

test "elide: a `.decl_anchor` with marker=.added is itself an anchor" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();

    // 20 unchanged rows; row 10 is a decl_anchor with marker=.added.
    var input: [20]line_mod.StyledLine = undefined;
    for (&input, 0..) |*row, i| row.* = unchangedRow(@intCast(i + 1));
    input[10] = .{
        .indent = 0,
        .marker = .added,
        .kind = .decl_anchor,
        .text = "anchor",
    };

    const out = try elide(a, &input, &state);

    // The anchor row is preserved.
    var saw_anchor = false;
    for (out) |r| if (r.kind == .decl_anchor) {
        try testing.expectEqual(line_mod.Marker.added, r.marker);
        try testing.expectEqualStrings("anchor", r.text);
        saw_anchor = true;
    };
    try testing.expect(saw_anchor);
}

test "elide: gap_id is stable across rebuilds of the same input" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();

    var input: [20]line_mod.StyledLine = undefined;
    for (&input, 0..) |*row, i| row.* = unchangedRow(@intCast(i + 1));
    input[10] = addedRow(11);

    const out_a = try elide(a, &input, &state);
    const out_b = try elide(a, &input, &state);

    // Find the leading elided row in each output and compare gap_ids.
    try testing.expectEqual(out_a[0].kind, line_mod.LineKind.elided);
    try testing.expectEqual(out_b[0].kind, line_mod.LineKind.elided);
    try testing.expectEqual(out_a[0].gap_id, out_b[0].gap_id);
    try testing.expectEqual(out_a[out_a.len - 1].gap_id, out_b[out_b.len - 1].gap_id);
}

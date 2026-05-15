//! File-wide line builder for modified files. Stitches the SST diff into a
//! flat `[]StyledLine` keyed off the underlying source lines, then runs
//! `elide.zig` to collapse long unchanged runs.
//!
//! Pipeline:
//!
//!   FileDiff.entries + left/right_source
//!         │
//!         ▼
//!   projectFile      → `[]StyledLine` (one row per source line, plus a
//!                      `.decl_anchor` row above each top-level / nested
//!                      Decl). Walks `entries` together with the source
//!                      buffers, running `hunk_mod.hunk` on the gaps
//!                      between Decls so file-level whitespace and
//!                      stray comments still surface.
//!         │
//!         ▼
//!   elide_mod.elide  → applies the ±`context_lines` window, collapsing
//!                      long unchanged runs into single `.elided` rows.
//!         │
//!         ▼
//!   unified vs split mode dispatch (split mode pairs adjacent
//!   `.removed` / `.added` runs the same way `line.zig` does).
//!
//! The shape of `BuildResult` matches `line.build` so the renderer in
//! `app.zig` can stay layout-agnostic.

const std = @import("std");

const rv = @import("rv");
const elide_mod = @import("elide.zig");
const hunk_mod = @import("hunk.zig");
const line_mod = @import("line.zig");
const state_mod = @import("state.zig");

const Allocator = std.mem.Allocator;

/// Re-exported so callers don't have to import `elide.zig` for the constant.
pub const context_lines: usize = elide_mod.context_lines;

/// Local byte range. The SST's `node.ByteRange` isn't exported through `rv`;
/// re-deriving the two `u32`s here keeps `file_view.zig`'s import surface
/// to `rv` only.
const Range = struct { start: u32, end: u32 };

/// Walking state threaded through the projector. `*_byte` track how far we
/// have consumed each source slice; `*_line` track the 1-indexed line
/// number that the next emitted row should carry on the corresponding side.
const Cursors = struct {
    left_byte: u32 = 0,
    right_byte: u32 = 0,
    left_line: u32 = 1,
    right_line: u32 = 1,
};

/// Build the file-wide view of `file_diff`. Mirrors `line.build`'s return
/// shape so app.zig's renderer stays mode-agnostic.
pub fn build(
    gpa: Allocator,
    file_diff: *const rv.FileDiff,
    mode: line_mod.Mode,
    state: *const state_mod.AppState,
) !line_mod.BuildResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var stats: line_mod.Stats = .{};
    collectStats(file_diff.entries, &stats);

    const projected = try projectFile(arena, file_diff, state);
    const elided = try elide_mod.elide(arena, projected, state);

    const view: line_mod.View = switch (mode) {
        .unified => .{ .unified = elided },
        .split => .{ .split = try splitFromUnified(arena, elided) },
    };

    const decl_index = try collectDeclIndex(arena, view);

    return .{
        .view = view,
        .stats = stats,
        .decl_index = decl_index,
        .arena = arena_state,
    };
}

// ── stats / decl_index ─────────────────────────────────────────────────────

/// Same recursive counting as `line.build`'s pass: every `.changed`
/// container's children are folded into the same counters so the English
/// summary in the diff-pane header doesn't depend on collapse state.
fn collectStats(entries: []const rv.DeclDiff, stats: *line_mod.Stats) void {
    for (entries) |e| switch (e) {
        .unchanged => stats.unchanged += 1,
        .added => stats.added += 1,
        .removed => stats.removed += 1,
        .changed => |c| {
            stats.changed += 1;
            if (c.body == .container) collectStats(c.body.container, stats);
        },
    };
}

/// Navigable rows are decl_anchor (file view) and decl_header (only here for
/// future-proofing; the file builder never emits them). `.elided` rows are
/// not navigation targets even though `n` / `p` will skip past them.
fn collectDeclIndex(arena: Allocator, view: line_mod.View) ![]const line_mod.DeclIndexEntry {
    var out: std.ArrayList(line_mod.DeclIndexEntry) = .empty;
    switch (view) {
        .unified => |lines| for (lines, 0..) |ln, i| {
            if (!isAnchorKind(ln.kind)) continue;
            try out.append(arena, .{
                .row = i,
                .changed = isChangedMarker(ln.marker),
            });
        },
        .split => |pairs| for (pairs, 0..) |p, i| {
            const side = anchorSide(p) orelse continue;
            try out.append(arena, .{
                .row = i,
                .changed = isChangedMarker(side.marker),
            });
        },
    }
    return try out.toOwnedSlice(arena);
}

fn isAnchorKind(kind: line_mod.LineKind) bool {
    return kind == .decl_anchor or kind == .decl_header;
}

fn anchorSide(p: line_mod.LinePair) ?line_mod.StyledLine {
    if (isAnchorKind(p.right.kind)) return p.right;
    if (isAnchorKind(p.left.kind)) return p.left;
    return null;
}

fn isChangedMarker(m: line_mod.Marker) bool {
    return m == .added or m == .removed or m == .changed;
}

// ── projection ─────────────────────────────────────────────────────────────

fn projectFile(
    arena: Allocator,
    file_diff: *const rv.FileDiff,
    state: *const state_mod.AppState,
) ![]const line_mod.StyledLine {
    var out: std.ArrayList(line_mod.StyledLine) = .empty;
    var cursors: Cursors = .{};

    const left_bound: Range = .{ .start = 0, .end = @intCast(file_diff.left_source.len) };
    const right_bound: Range = .{ .start = 0, .end = @intCast(file_diff.right_source.len) };

    try projectEntries(
        arena,
        &out,
        file_diff,
        state,
        file_diff.entries,
        0,
        left_bound,
        right_bound,
        &cursors,
    );

    return try out.toOwnedSlice(arena);
}

/// Inferred error sets blow up because `projectEntries` ↔ `projectDecl`
/// ↔ `projectChanged` form a recursion cycle. Declaring the set up front
/// breaks the cycle. Every leaf operation is an arena allocation or a
/// helper that itself only allocates, so the only error we ever see is
/// `OutOfMemory`.
const ProjectError = error{OutOfMemory};

/// Walk `entries` in order, emitting:
///   1. The gap between the previous decl (or parent's start) and this
///      decl on each side — through `hunk_mod.hunk` so file-level
///      whitespace and stray comments still surface as common / removed /
///      added lines with correct per-side line numbers.
///   2. The decl itself: a `.decl_anchor` row plus the body (or a single
///      `.elided` row when collapsed).
///   3. A trailing gap covering whatever's between the last decl and
///      `parent_*`'s end.
///
/// `parent_left` / `parent_right` give the byte ranges that bound this
/// container on each side. For the top-level call, that's the whole
/// source. For a recursed `.changed` container, it's `c.old`/`c.new`'s
/// byte ranges so the container's open/close braces show up as gaps
/// inside the recursion rather than getting orphaned at the outer level.
fn projectEntries(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    state: *const state_mod.AppState,
    entries: []const rv.DeclDiff,
    indent: u8,
    parent_left: Range,
    parent_right: Range,
    cursors: *Cursors,
) ProjectError!void {
    for (entries) |entry| {
        const lr = leftRangeOf(entry);
        const rr = rightRangeOf(entry, file_diff, cursors.right_byte);

        // Pre-decl gap: from current cursor up to the start of the line
        // that contains the decl. The bytes between the line start and
        // `r.start` (i.e. the decl's leading indentation) are dropped:
        // SST byte ranges for nested decls start at the keyword, so
        // emitting them as part of the gap produces a phantom partial-line
        // row with the wrong line number on top of an `.added` /
        // `.removed` marker for the indent of an added/removed child.
        // `@max` is defensive against moves that would otherwise produce
        // a negative range (the surrounding whitespace just gets dropped
        // in that case; v1 doesn't try to cleverly recover).
        const left_gap_end = if (lr) |r|
            @max(cursors.left_byte, lineStartBefore(file_diff.left_source, r.start))
        else
            cursors.left_byte;
        const right_gap_end = if (rr) |r|
            @max(cursors.right_byte, lineStartBefore(file_diff.right_source, r.start))
        else
            cursors.right_byte;
        try emitGap(
            arena,
            out,
            file_diff,
            indent,
            cursors,
            cursors.left_byte,
            left_gap_end,
            cursors.right_byte,
            right_gap_end,
        );
        cursors.left_byte = left_gap_end;
        cursors.right_byte = right_gap_end;

        // Re-anchor cursors at the decl's start on whichever sides exist.
        if (lr) |r| cursors.left_byte = r.start;
        if (rr) |r| cursors.right_byte = r.start;

        try projectDecl(arena, out, file_diff, state, entry, indent, cursors);

        // Advance past the decl. Consume the trailing `\n` (if any) so the
        // gap to the next decl doesn't yield a phantom blank row for the
        // line terminator that already belongs to the decl's last source
        // line.
        if (lr) |r| cursors.left_byte = consumeTrailingNewline(file_diff.left_source, r.end);
        if (rr) |r| cursors.right_byte = consumeTrailingNewline(file_diff.right_source, r.end);
    }

    // Trailing gap up to the parent's end (file end or container's `}`).
    const left_tail_end = @max(cursors.left_byte, parent_left.end);
    const right_tail_end = @max(cursors.right_byte, parent_right.end);
    try emitGap(
        arena,
        out,
        file_diff,
        indent,
        cursors,
        cursors.left_byte,
        left_tail_end,
        cursors.right_byte,
        right_tail_end,
    );
    cursors.left_byte = left_tail_end;
    cursors.right_byte = right_tail_end;
}

fn consumeTrailingNewline(source: []const u8, end: u32) u32 {
    if (end < source.len and source[end] == '\n') return end + 1;
    return end;
}

/// Position of the first byte of the line that contains `pos` (i.e. one
/// past the previous `\n`, or 0 when `pos` is on the first line). Used
/// to back up a gap end so it stops at a line boundary instead of
/// halfway through the leading-indent of the next decl.
fn lineStartBefore(source: []const u8, pos: u32) u32 {
    var i: usize = @min(pos, source.len);
    while (i > 0) : (i -= 1) {
        if (source[i - 1] == '\n') return @intCast(i);
    }
    return 0;
}

fn leftRangeOf(entry: rv.DeclDiff) ?Range {
    return switch (entry) {
        .removed => |r| toRange(r.decl.list.byte_range),
        .unchanged => |u| toRange(u.decl.list.byte_range),
        .changed => |c| toRange(c.old.list.byte_range),
        .added => null,
    };
}

/// Right-side byte range. For `.unchanged`, the engine drops the right-side
/// list pointer (only the left decl is kept), so we recover it by searching
/// `right_source` from the current cursor for the byte content of the
/// unchanged decl. Among all positions the bytes appear at, the leftmost
/// `>= right_byte` is the correct match because `entries` is in right-side
/// order with `removed` spliced in adjacent to its left anchor.
fn rightRangeOf(
    entry: rv.DeclDiff,
    file_diff: *const rv.FileDiff,
    right_byte: u32,
) ?Range {
    return switch (entry) {
        .removed => null,
        .added => |a| toRange(a.decl.list.byte_range),
        .changed => |c| toRange(c.new.list.byte_range),
        .unchanged => |u| blk: {
            const lr = u.decl.list.byte_range;
            const len: u32 = lr.end - lr.start;
            const left_bytes = file_diff.left_source[lr.start..lr.end];
            const found = std.mem.indexOfPos(u8, file_diff.right_source, right_byte, left_bytes) orelse {
                // Defensive fallback: an unchanged decl by definition appears
                // somewhere in right_source, but if alignment ever produces a
                // pathological case (e.g. a list-level non-byte equality) we
                // pretend the right-side decl sits at the current cursor so
                // emission keeps moving rather than crashing.
                break :blk Range{ .start = right_byte, .end = right_byte + len };
            };
            const start: u32 = @intCast(found);
            break :blk Range{ .start = start, .end = start + len };
        },
    };
}

fn toRange(br: anytype) Range {
    return .{ .start = br.start, .end = br.end };
}

fn projectDecl(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    state: *const state_mod.AppState,
    entry: rv.DeclDiff,
    indent: u8,
    cursors: *Cursors,
) ProjectError!void {
    switch (entry) {
        .unchanged => |u| try projectUnchanged(arena, out, file_diff, state, u, indent, cursors),
        .added => |a| try projectAdded(arena, out, file_diff, state, a, indent, cursors),
        .removed => |r| try projectRemoved(arena, out, file_diff, state, r, indent, cursors),
        .changed => |c| try projectChanged(arena, out, file_diff, state, c, indent, cursors),
    }
}

fn projectUnchanged(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    state: *const state_mod.AppState,
    u: anytype,
    indent: u8,
    cursors: *Cursors,
) !void {
    const id = state_mod.declId(u.decl);
    try out.append(arena, .{
        .indent = indent,
        .marker = .unchanged,
        .kind = .decl_anchor,
        .text = try line_mod.declHeaderText(arena, u.decl, u.moved, false),
        .decl_id = id,
    });

    if (state.isCollapsed(id)) {
        try emitCollapsedBody(arena, out, indent, id, u.decl.name, entryLineCount(.{ .unchanged = u }, file_diff));
        advanceCursorsForCollapsedEntry(.{ .unchanged = u }, file_diff, cursors);
        return;
    }

    const lr = u.decl.list.byte_range;
    try emitSourceLines(
        arena,
        out,
        file_diff,
        indent,
        file_diff.left_source[lr.start..lr.end],
        lr.start,
        u.decl.list,
        .unchanged,
        id,
        cursors,
        .both,
    );
}

fn projectAdded(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    state: *const state_mod.AppState,
    a: anytype,
    indent: u8,
    cursors: *Cursors,
) !void {
    const id = state_mod.declId(a.decl);
    try out.append(arena, .{
        .indent = indent,
        .marker = .added,
        .kind = .decl_anchor,
        .text = try line_mod.declHeaderText(arena, a.decl, null, false),
        .decl_id = id,
    });

    if (state.isCollapsed(id)) {
        try emitCollapsedBody(arena, out, indent, id, a.decl.name, entryLineCount(.{ .added = a }, file_diff));
        advanceCursorsForCollapsedEntry(.{ .added = a }, file_diff, cursors);
        return;
    }

    const rr = a.decl.list.byte_range;
    try emitSourceLines(
        arena,
        out,
        file_diff,
        indent,
        file_diff.right_source[rr.start..rr.end],
        rr.start,
        a.decl.list,
        .added,
        id,
        cursors,
        .right_only,
    );
}

fn projectRemoved(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    state: *const state_mod.AppState,
    r: anytype,
    indent: u8,
    cursors: *Cursors,
) !void {
    const id = state_mod.declId(r.decl);
    try out.append(arena, .{
        .indent = indent,
        .marker = .removed,
        .kind = .decl_anchor,
        .text = try line_mod.declHeaderText(arena, r.decl, null, false),
        .decl_id = id,
    });

    if (state.isCollapsed(id)) {
        try emitCollapsedBody(arena, out, indent, id, r.decl.name, entryLineCount(.{ .removed = r }, file_diff));
        advanceCursorsForCollapsedEntry(.{ .removed = r }, file_diff, cursors);
        return;
    }

    const lr = r.decl.list.byte_range;
    try emitSourceLines(
        arena,
        out,
        file_diff,
        indent,
        file_diff.left_source[lr.start..lr.end],
        lr.start,
        r.decl.list,
        .removed,
        id,
        cursors,
        .left_only,
    );
}

fn projectChanged(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    state: *const state_mod.AppState,
    c: anytype,
    indent: u8,
    cursors: *Cursors,
) ProjectError!void {
    const id = state_mod.declId(c.new);
    try out.append(arena, .{
        .indent = indent,
        .marker = .changed,
        .kind = .decl_anchor,
        .text = try line_mod.declHeaderText(arena, c.new, c.moved, false),
        .decl_id = id,
    });

    if (state.isCollapsed(id)) {
        try emitCollapsedBody(arena, out, indent, id, c.new.name, entryLineCount(.{ .changed = c }, file_diff));
        advanceCursorsForCollapsedEntry(.{ .changed = c }, file_diff, cursors);
        return;
    }

    switch (c.body) {
        .container => |children| {
            const left_range = toRange(c.old.list.byte_range);
            const right_range = toRange(c.new.list.byte_range);
            try projectEntries(
                arena,
                out,
                file_diff,
                state,
                children,
                indent + 1,
                left_range,
                right_range,
                cursors,
            );
        },
        .leaf => |script| {
            try projectChangedLeaf(arena, out, file_diff, script, c.old, c.new, id, indent + 1, cursors);
        },
    }
}

/// Reuse `line.zig`'s leaf hunk builder verbatim and post-process the result
/// to fill in per-side line numbers and a `decl_id`. The leaf hunk emits
/// one row per source line on whichever side(s) it appears, so cursor
/// advancement is purely a function of each row's marker.
fn projectChangedLeaf(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    script: rv.EditScript,
    old_decl: rv.Decl,
    new_decl: rv.Decl,
    decl_id: state_mod.DeclId,
    indent: u8,
    cursors: *Cursors,
) !void {
    const hunk_lines = try line_mod.buildLeafHunk(arena, file_diff, script, old_decl, new_decl, indent);
    for (hunk_lines) |line| {
        var sl = line;
        sl.decl_id = decl_id;
        switch (line.marker) {
            .context => {
                sl.line_no_left = cursors.left_line;
                sl.line_no_right = cursors.right_line;
                cursors.left_line += 1;
                cursors.right_line += 1;
            },
            .removed => {
                sl.line_no_left = cursors.left_line;
                cursors.left_line += 1;
            },
            .added => {
                sl.line_no_right = cursors.right_line;
                cursors.right_line += 1;
            },
            else => unreachable,
        }
        try out.append(arena, sl);
    }
}

// ── source-line and gap emission ───────────────────────────────────────────

const SideAdvance = enum { both, left_only, right_only };

/// Emit every source line of `slice` (split on `\n`, trailing empty line
/// dropped) as a `.source` row. Highlights for the whole decl are
/// collected once and clipped per line.
fn emitSourceLines(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    indent: u8,
    slice: []const u8,
    slice_abs_start: u32,
    decl_list: *const rv.List,
    marker: line_mod.Marker,
    decl_id: state_mod.DeclId,
    cursors: *Cursors,
    side: SideAdvance,
) !void {
    const highlights = try line_mod.collectHighlights(arena, decl_list, file_diff.language);

    var cursor_in_slice: usize = 0;
    var line_abs_start: u32 = slice_abs_start;
    var first = true;
    while (true) {
        const rest = slice[cursor_in_slice..];
        const nl_rel = std.mem.indexOfScalar(u8, rest, '\n');
        const raw_line = if (nl_rel) |p| rest[0..p] else rest;
        if (raw_line.len == 0 and nl_rel == null and !first) break;
        first = false;

        const expanded = try line_mod.expandTabs(arena, raw_line);
        const line_highlights = try line_mod.mapHighlightsToLine(arena, raw_line, line_abs_start, highlights);

        var line_no_left: ?u32 = null;
        var line_no_right: ?u32 = null;
        switch (side) {
            .both => {
                line_no_left = cursors.left_line;
                line_no_right = cursors.right_line;
                cursors.left_line += 1;
                cursors.right_line += 1;
            },
            .left_only => {
                line_no_left = cursors.left_line;
                cursors.left_line += 1;
            },
            .right_only => {
                line_no_right = cursors.right_line;
                cursors.right_line += 1;
            },
        }

        try out.append(arena, .{
            .indent = indent,
            .marker = marker,
            .kind = .source,
            .text = expanded,
            .highlights = line_highlights,
            .decl_id = decl_id,
            .line_no_left = line_no_left,
            .line_no_right = line_no_right,
        });

        if (nl_rel) |p| {
            cursor_in_slice += p + 1;
            line_abs_start = slice_abs_start + @as(u32, @intCast(cursor_in_slice));
        } else break;
    }
}

/// Run a linewise LCS on the gap region and emit one `.source` row per
/// `HunkLine`. Common rows are emitted as `.unchanged` so they elide the
/// same way unchanged-decl source lines do; left-only / right-only rows
/// pick up `.removed` / `.added` markers.
///
/// No highlight collection here: gap regions in real source files are
/// almost entirely whitespace, occasionally with stray comments. Painting
/// them at v1 isn't worth the extra SST walking.
fn emitGap(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    indent: u8,
    cursors: *Cursors,
    left_start: u32,
    left_end: u32,
    right_start: u32,
    right_end: u32,
) !void {
    if (left_start >= left_end and right_start >= right_end) return;
    const left_slice = file_diff.left_source[left_start..left_end];
    const right_slice = file_diff.right_source[right_start..right_end];
    const hunks = try hunk_mod.hunk(arena, left_slice, right_slice);
    for (hunks) |h| {
        const marker: line_mod.Marker = switch (h.side) {
            .common => .unchanged,
            .left => .removed,
            .right => .added,
        };
        const expanded = try line_mod.expandTabs(arena, h.text);

        var line_no_left: ?u32 = null;
        var line_no_right: ?u32 = null;
        switch (h.side) {
            .common => {
                line_no_left = cursors.left_line;
                line_no_right = cursors.right_line;
                cursors.left_line += 1;
                cursors.right_line += 1;
            },
            .left => {
                line_no_left = cursors.left_line;
                cursors.left_line += 1;
            },
            .right => {
                line_no_right = cursors.right_line;
                cursors.right_line += 1;
            },
        }

        try out.append(arena, .{
            .indent = indent,
            .marker = marker,
            .kind = .source,
            .text = expanded,
            .line_no_left = line_no_left,
            .line_no_right = line_no_right,
        });
    }
}

// ── collapsed-decl helpers ─────────────────────────────────────────────────

/// Synthetic gap_id for the `.elided` row that stands in for a collapsed
/// decl's body. Hashing the decl_id with a domain string keeps the
/// synthetic id deterministic across rebuilds while making collisions
/// with real gap ids vanishingly unlikely.
fn collapsedBodyGapId(decl_id: state_mod.DeclId) state_mod.GapId {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(std.mem.asBytes(&decl_id));
    hasher.update("collapsed-body");
    return hasher.final();
}

fn emitCollapsedBody(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    indent: u8,
    decl_id: state_mod.DeclId,
    name: ?[]const u8,
    line_count: u32,
) !void {
    const display_name = name orelse "<anon>";
    const text = try std.fmt.allocPrint(
        arena,
        "… body of {s} ({d} lines) …",
        .{ display_name, line_count },
    );
    try out.append(arena, .{
        .indent = indent,
        .marker = .blank,
        .kind = .elided,
        .text = text,
        .gap_id = collapsedBodyGapId(decl_id),
    });
}

/// Number of source lines per side that the entry's body would emit if
/// expanded. Used both for the "(N lines)" suffix on the synthetic
/// elided row and to advance the line cursors past a collapsed body so
/// downstream rows still get correct line numbers.
const PerSideLines = struct { left: u32, right: u32 };

fn entryLineCount(entry: rv.DeclDiff, file_diff: *const rv.FileDiff) u32 {
    const c = perSideLineCount(entry, file_diff);
    return @max(c.left, c.right);
}

fn perSideLineCount(entry: rv.DeclDiff, file_diff: *const rv.FileDiff) PerSideLines {
    return switch (entry) {
        .unchanged => |u| blk: {
            const n = countLines(file_diff.left_source[u.decl.list.byte_range.start..u.decl.list.byte_range.end]);
            break :blk .{ .left = n, .right = n };
        },
        .added => |a| .{
            .left = 0,
            .right = countLines(file_diff.right_source[a.decl.list.byte_range.start..a.decl.list.byte_range.end]),
        },
        .removed => |r| .{
            .left = countLines(file_diff.left_source[r.decl.list.byte_range.start..r.decl.list.byte_range.end]),
            .right = 0,
        },
        .changed => |c| .{
            .left = countLines(file_diff.left_source[c.old.list.byte_range.start..c.old.list.byte_range.end]),
            .right = countLines(file_diff.right_source[c.new.list.byte_range.start..c.new.list.byte_range.end]),
        },
    };
}

fn advanceCursorsForCollapsedEntry(
    entry: rv.DeclDiff,
    file_diff: *const rv.FileDiff,
    cursors: *Cursors,
) void {
    const c = perSideLineCount(entry, file_diff);
    cursors.left_line += c.left;
    cursors.right_line += c.right;
}

fn countLines(slice: []const u8) u32 {
    if (slice.len == 0) return 0;
    const newlines = std.mem.count(u8, slice, "\n");
    const tail_count: usize = if (slice[slice.len - 1] == '\n') 0 else 1;
    return @intCast(newlines + tail_count);
}

// ── split-mode conversion ─────────────────────────────────────────────────

/// Convert the unified `[]StyledLine` into split-mode `[]LinePair`. Mirrors
/// `line.zig::appendLeafHunkPairs`'s pairing logic but operates on the
/// already-elided row stream so both panes stay in sync.
///
/// `.decl_anchor` rows are flushed independently of the surrounding
/// `.added` / `.removed` source runs: the spec places an added/removed
/// anchor on its active side with a blank on the other, rather than
/// letting it pair up with an opposite-side anchor or source line.
fn splitFromUnified(
    arena: Allocator,
    lines: []const line_mod.StyledLine,
) ![]const line_mod.LinePair {
    var out: std.ArrayList(line_mod.LinePair) = .empty;
    var pending_left: std.ArrayList(line_mod.StyledLine) = .empty;
    var pending_right: std.ArrayList(line_mod.StyledLine) = .empty;

    for (lines) |ln| {
        if (ln.kind == .decl_anchor) {
            try line_mod.flushPendingPairs(arena, &out, &pending_left, &pending_right, ln.indent);
            switch (ln.marker) {
                .added => {
                    try pending_right.append(arena, ln);
                    try line_mod.flushPendingPairs(arena, &out, &pending_left, &pending_right, ln.indent);
                },
                .removed => {
                    try pending_left.append(arena, ln);
                    try line_mod.flushPendingPairs(arena, &out, &pending_left, &pending_right, ln.indent);
                },
                else => try out.append(arena, .{ .left = ln, .right = ln }),
            }
            continue;
        }
        switch (ln.marker) {
            .removed => try pending_left.append(arena, ln),
            .added => try pending_right.append(arena, ln),
            .unchanged, .changed, .context, .blank => {
                try line_mod.flushPendingPairs(arena, &out, &pending_left, &pending_right, ln.indent);
                try out.append(arena, .{ .left = ln, .right = ln });
            },
        }
    }
    // Use the first pending row's indent so trailing blank fillers line up
    // with the rest of the run rather than landing at indent 0.
    const trailing_indent: u8 = if (pending_left.items.len > 0)
        pending_left.items[0].indent
    else if (pending_right.items.len > 0)
        pending_right.items[0].indent
    else
        0;
    try line_mod.flushPendingPairs(arena, &out, &pending_left, &pending_right, trailing_indent);

    return try out.toOwnedSlice(arena);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn buildForTest(
    gpa: Allocator,
    file_diff: *const rv.FileDiff,
    mode: line_mod.Mode,
) !line_mod.BuildResult {
    var state = state_mod.AppState.init(gpa);
    defer state.deinit();
    return build(gpa, file_diff, mode, &state);
}

test "build: identical sources collapse the whole file to a single elided row" {
    const src =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    // Every source line is unchanged → elide collapses to one row, since
    // there's no anchor and unchanged decl_anchors aren't anchors either.
    const lines = result.view.unified;
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(line_mod.LineKind.elided, lines[0].kind);
}

test "build: stats count every top-level decl" {
    const before =
        \\pub fn a() void {}
        \\pub fn b() u32 { return 1; }
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() u32 { return 2; }
        \\pub fn c() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.unchanged);
    try testing.expectEqual(@as(usize, 1), result.stats.changed);
    try testing.expectEqual(@as(usize, 1), result.stats.added);
    try testing.expectEqual(@as(usize, 0), result.stats.removed);
}

test "build: single change in a long file emits ±3 context with elided rows on each side" {
    const before =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() void {}
        \\pub fn d() void {}
        \\pub fn e() u32 { return 1; }
        \\pub fn f() void {}
        \\pub fn g() void {}
        \\pub fn h() void {}
        \\pub fn i() void {}
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() void {}
        \\pub fn d() void {}
        \\pub fn e() u32 { return 2; }
        \\pub fn f() void {}
        \\pub fn g() void {}
        \\pub fn h() void {}
        \\pub fn i() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    const lines = result.view.unified;
    var leading_elided: usize = 0;
    var trailing_elided: usize = 0;
    var saw_changed_anchor = false;
    var saw_removed_source = false;
    var saw_added_source = false;
    var first_change_idx: ?usize = null;
    var last_change_idx: ?usize = null;
    for (lines, 0..) |ln, i| {
        switch (ln.marker) {
            .removed => if (ln.kind == .source) {
                saw_removed_source = true;
                if (first_change_idx == null) first_change_idx = i;
                last_change_idx = i;
            },
            .added => if (ln.kind == .source) {
                saw_added_source = true;
                if (first_change_idx == null) first_change_idx = i;
                last_change_idx = i;
            },
            .changed => if (ln.kind == .decl_anchor) {
                saw_changed_anchor = true;
                if (first_change_idx == null) first_change_idx = i;
                last_change_idx = i;
            },
            else => {},
        }
    }
    try testing.expect(saw_changed_anchor);
    try testing.expect(saw_removed_source);
    try testing.expect(saw_added_source);
    for (lines[0..first_change_idx.?]) |ln| if (ln.kind == .elided) {
        leading_elided += 1;
    };
    for (lines[last_change_idx.? + 1 ..]) |ln| if (ln.kind == .elided) {
        trailing_elided += 1;
    };
    try testing.expect(leading_elided >= 1);
    try testing.expect(trailing_elided >= 1);
}

test "build: added decl emits anchor + full body, flanking unchanged collapse" {
    const before =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() void {}
        \\pub fn d() void {}
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn fresh() void {
        \\    return;
        \\}
        \\pub fn c() void {}
        \\pub fn d() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    const lines = result.view.unified;

    var saw_added_anchor = false;
    var added_source_count: usize = 0;
    for (lines) |ln| {
        if (ln.marker == .added and ln.kind == .decl_anchor) saw_added_anchor = true;
        if (ln.marker == .added and ln.kind == .source) added_source_count += 1;
    }
    try testing.expect(saw_added_anchor);
    // The added body has 3 source lines (signature, return, closing brace).
    try testing.expectEqual(@as(usize, 3), added_source_count);

    // Unchanged decls outside ±3 of the added anchor collapse.
    var saw_elided = false;
    for (lines) |ln| if (ln.kind == .elided) {
        saw_elided = true;
    };
    try testing.expect(saw_elided);
}

test "build: collapsed decl emits anchor + single synthetic elided row" {
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    // Find the changed decl id and mark it collapsed.
    var collapse_id: state_mod.DeclId = 0;
    for (fd.entries) |e| if (e == .changed) {
        collapse_id = state_mod.declId(e.changed.new);
    };

    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();
    _ = try state.toggle(collapse_id);

    var result = try build(testing.allocator, &fd, .unified, &state);
    defer result.deinit();

    const lines = result.view.unified;

    // The view must contain a `.changed` decl_anchor and a synthetic `.elided`
    // row right after it whose text mentions the decl name.
    var anchor_idx: ?usize = null;
    for (lines, 0..) |ln, i| {
        if (ln.kind == .decl_anchor and ln.marker == .changed) {
            anchor_idx = i;
            break;
        }
    }
    try testing.expect(anchor_idx != null);
    try testing.expect(anchor_idx.? + 1 < lines.len);
    const after_anchor = lines[anchor_idx.? + 1];
    try testing.expectEqual(line_mod.LineKind.elided, after_anchor.kind);
    try testing.expect(std.mem.indexOf(u8, after_anchor.text, "greet") != null);
    try testing.expect(after_anchor.gap_id != null);
    // Synthetic gap_id matches the helper.
    try testing.expectEqual(collapsedBodyGapId(collapse_id), after_anchor.gap_id.?);

    // No body source lines for the collapsed decl.
    for (lines) |ln| try testing.expect(!(ln.kind == .source and ln.decl_id != null and
        ln.decl_id.? == collapse_id));
}

test "build: per-side line numbers populate per marker (added/removed/unchanged)" {
    const before =
        \\pub fn a() void {}
        \\pub fn gone() void { return; }
        \\pub fn b() void {}
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn fresh() void { return; }
        \\pub fn b() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var saw_added_source = false;
    var saw_removed_source = false;
    var saw_unchanged_source = false;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        switch (ln.marker) {
            .added => {
                try testing.expectEqual(@as(?u32, null), ln.line_no_left);
                try testing.expect(ln.line_no_right != null);
                saw_added_source = true;
            },
            .removed => {
                try testing.expect(ln.line_no_left != null);
                try testing.expectEqual(@as(?u32, null), ln.line_no_right);
                saw_removed_source = true;
            },
            .unchanged => {
                try testing.expect(ln.line_no_left != null);
                try testing.expect(ln.line_no_right != null);
                saw_unchanged_source = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_added_source);
    try testing.expect(saw_removed_source);
    try testing.expect(saw_unchanged_source);

    // decl_anchor and elided rows carry no per-side line numbers.
    for (result.view.unified) |ln| switch (ln.kind) {
        .decl_anchor, .elided => {
            try testing.expectEqual(@as(?u32, null), ln.line_no_left);
            try testing.expectEqual(@as(?u32, null), ln.line_no_right);
        },
        else => {},
    };
}

test "build: cross-decl context windows merge when changes are within 2*context lines" {
    // Two adjacent decls, each with a single-line change. The context
    // windows around the two anchors overlap, so no `.elided` row should
    // appear between them.
    const before =
        \\pub fn a() u32 { return 1; }
        \\pub fn b() u32 { return 1; }
    ;
    const after =
        \\pub fn a() u32 { return 2; }
        \\pub fn b() u32 { return 3; }
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    const lines = result.view.unified;

    // Locate the two `.changed` decl_anchors.
    var first_changed: ?usize = null;
    var last_changed: ?usize = null;
    for (lines, 0..) |ln, i| {
        if (ln.kind == .decl_anchor and ln.marker == .changed) {
            if (first_changed == null) first_changed = i;
            last_changed = i;
        }
    }
    try testing.expect(first_changed != null);
    try testing.expect(last_changed != null);
    try testing.expect(first_changed.? != last_changed.?);

    // No `.elided` row between the two anchors.
    var middle_elided: usize = 0;
    for (lines[first_changed.?..last_changed.? + 1]) |ln| if (ln.kind == .elided) {
        middle_elided += 1;
    };
    try testing.expectEqual(@as(usize, 0), middle_elided);
}

test "build split: mirrored common rows, paired add/remove runs" {
    const before =
        \\pub fn a() void {}
        \\pub fn b() u32 { return 1; }
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() u32 { return 2; }
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .split);
    defer result.deinit();

    const pairs = result.view.split;
    try testing.expect(pairs.len > 0);

    // Common-marker rows (.unchanged / .changed / .context / .blank /
    // .elided) mirror identically on both sides.
    for (pairs) |p| {
        switch (p.left.marker) {
            .removed, .added => continue,
            else => {},
        }
        try testing.expectEqual(p.left.kind, p.right.kind);
        try testing.expectEqual(p.left.marker, p.right.marker);
        try testing.expectEqualStrings(p.left.text, p.right.text);
    }

    // The hunk row pair: a `.removed` left and `.added` right at the same
    // row, never both blank.
    var saw_paired_change = false;
    for (pairs) |p| {
        const l_change = p.left.marker == .removed and p.left.kind == .source;
        const r_change = p.right.marker == .added and p.right.kind == .source;
        if (l_change and r_change) saw_paired_change = true;
    }
    try testing.expect(saw_paired_change);
}

test "build: decl_index lists every decl_anchor row" {
    const before =
        \\pub fn a() void {}
        \\pub fn b() u32 { return 1; }
        \\pub fn c() void {}
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() u32 { return 2; }
        \\pub fn c() void {}
        \\pub fn d() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    // 4 decls → 4 anchor rows in the index, regardless of elision.
    try testing.expectEqual(@as(usize, 4), result.decl_index.len);
    for (result.decl_index) |e| {
        try testing.expectEqual(line_mod.LineKind.decl_anchor, result.view.unified[e.row].kind);
    }
}

test "build split: adjacent removed and added decl_anchors each get their own row with blank on the inactive side" {
    // Rename: `gone` → `fresh`. The diff engine emits a `.removed` decl
    // followed by an `.added` decl with no unchanged content between, so
    // both pending_left and pending_right hold an anchor + body when the
    // run flushes. Without the spec fix, the two anchors would pair up
    // with each other on the same row.
    const before =
        \\pub fn gone() void { return; }
    ;
    const after =
        \\pub fn fresh() void { return; }
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .split);
    defer result.deinit();

    var saw_removed_anchor_pair = false;
    var saw_added_anchor_pair = false;
    for (result.view.split) |p| {
        // A `.removed` anchor must sit on the left with blank on the right.
        if (p.left.kind == .decl_anchor and p.left.marker == .removed) {
            try testing.expectEqual(line_mod.LineKind.blank, p.right.kind);
            try testing.expectEqual(line_mod.Marker.blank, p.right.marker);
            saw_removed_anchor_pair = true;
        }
        // An `.added` anchor must sit on the right with blank on the left.
        if (p.right.kind == .decl_anchor and p.right.marker == .added) {
            try testing.expectEqual(line_mod.LineKind.blank, p.left.kind);
            try testing.expectEqual(line_mod.Marker.blank, p.left.marker);
            saw_added_anchor_pair = true;
        }
        // The two anchors must never share a row.
        try testing.expect(!(p.left.kind == .decl_anchor and p.right.kind == .decl_anchor and
            p.left.marker == .removed and p.right.marker == .added));
    }
    try testing.expect(saw_removed_anchor_pair);
    try testing.expect(saw_added_anchor_pair);
}

test "countLines: handles trailing newline, no newline, empty" {
    try testing.expectEqual(@as(u32, 0), countLines(""));
    try testing.expectEqual(@as(u32, 1), countLines("abc"));
    try testing.expectEqual(@as(u32, 1), countLines("abc\n"));
    try testing.expectEqual(@as(u32, 2), countLines("abc\ndef"));
    try testing.expectEqual(@as(u32, 2), countLines("abc\ndef\n"));
    try testing.expectEqual(@as(u32, 1), countLines("\n"));
    try testing.expectEqual(@as(u32, 2), countLines("\n\n"));
}

test "build: nested container decl emits correct per-side line numbers" {
    // Regression: nested decls' SST byte_range starts at the keyword,
    // not at column 0 of their line. The pre-decl gap must stop at the
    // newline before the decl rather than emitting the leading
    // indentation as a phantom partial-line row, otherwise per-side
    // line numbers slip by one for every nested decl and added/removed
    // children produce a misleading whitespace-only `+`/`-` row.
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    // No source row should be only whitespace (the indentation of a
    // nested decl belongs to the decl's first source line via `indent`,
    // not to a standalone gap row).
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        const trimmed = std.mem.trim(u8, ln.text, " \t");
        try testing.expect(trimmed.len > 0);
    }

    // `pub fn one() void {}` is line 2 on both sides;
    // `pub fn two() void {}` is line 3 on the right.
    var saw_one = false;
    var saw_two = false;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        if (std.mem.indexOf(u8, ln.text, "pub fn one") != null) {
            try testing.expectEqual(@as(?u32, 2), ln.line_no_left);
            try testing.expectEqual(@as(?u32, 2), ln.line_no_right);
            saw_one = true;
        }
        if (std.mem.indexOf(u8, ln.text, "pub fn two") != null) {
            try testing.expectEqual(@as(?u32, null), ln.line_no_left);
            try testing.expectEqual(@as(?u32, 3), ln.line_no_right);
            saw_two = true;
        }
    }
    try testing.expect(saw_one);
    try testing.expect(saw_two);
}

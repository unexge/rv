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

/// Build the navigable decl index. Two cases share the same scan:
///
/// - Collapsed decls keep emitting a `.decl_anchor` row above their
///   synthetic `.elided` body, so the anchor itself is the jump target.
/// - Expanded decls now inline their `(name, ts_kind)` annotation on
///   their first source row instead of emitting an anchor, so the
///   annotated source row is the jump target.
///
/// Source rows are picked up only when they carry a `decl_annotation`,
/// which by construction means the first emitted row of an expanded
/// decl. That keeps every other source row out of the index.
fn collectDeclIndex(arena: Allocator, view: line_mod.View) ![]const line_mod.DeclIndexEntry {
    var out: std.ArrayList(line_mod.DeclIndexEntry) = .empty;
    switch (view) {
        .unified => |lines| for (lines, 0..) |ln, i| {
            if (!isJumpTargetRow(ln)) continue;
            try out.append(arena, .{
                .row = i,
                .changed = isChangedMarker(ln.marker),
            });
        },
        .split => |pairs| for (pairs, 0..) |p, i| {
            const side = jumpTargetSide(p) orelse continue;
            try out.append(arena, .{
                .row = i,
                .changed = isChangedMarker(side.marker),
            });
        },
    }
    return try out.toOwnedSlice(arena);
}

fn isJumpTargetRow(ln: line_mod.StyledLine) bool {
    if (ln.kind == .decl_anchor or ln.kind == .decl_header) return true;
    if (ln.kind == .source and ln.decl_annotation != null) return true;
    return false;
}

fn jumpTargetSide(p: line_mod.LinePair) ?line_mod.StyledLine {
    if (isJumpTargetRow(p.right)) return p.right;
    if (isJumpTargetRow(p.left)) return p.left;
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

    if (entriesContainReordering(file_diff.entries)) {
        try emitGap(
            arena,
            &out,
            file_diff,
            0,
            &cursors,
            0,
            @intCast(file_diff.left_source.len),
            0,
            @intCast(file_diff.right_source.len),
        );
        return try out.toOwnedSlice(arena);
    }

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

fn entriesContainReordering(entries: []const rv.DeclDiff) bool {
    var previous_moved_from: ?usize = null;
    for (entries) |entry| switch (entry) {
        .unchanged => |u| if (u.moved) |m| {
            if (previous_moved_from) |previous| if (m.from_idx < previous) return true;
            previous_moved_from = m.from_idx;
        },
        .changed => |c| {
            if (c.moved) |m| {
                if (previous_moved_from) |previous| if (m.from_idx < previous) return true;
                previous_moved_from = m.from_idx;
            }
            if (c.body == .container and entriesContainReordering(c.body.container)) return true;
        },
        .added, .removed => {},
    };
    return false;
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
        // that contains the decl. SST byte ranges for nested decls start
        // at the keyword, so emitting the bytes between the line start
        // and `r.start` as part of the gap would produce a phantom
        // partial-line row with the wrong line number on top of an
        // `.added` / `.removed` marker for the indent of an added/removed
        // child. Those leading-indent bytes belong to the decl slice
        // instead - `projectAdded` / `projectRemoved` / `projectUnchanged`
        // extend their slice back to `lineStart(r.start)` to pick them up.
        // `@max` is defensive against moves that would otherwise produce
        // a negative range (the surrounding whitespace just gets dropped
        // in that case; v1 doesn't try to cleverly recover).
        const left_gap_end = if (lr) |r|
            @max(cursors.left_byte, line_mod.lineStart(file_diff.left_source, r.start))
        else
            cursors.left_byte;
        const right_gap_end = if (rr) |r|
            @max(cursors.right_byte, line_mod.lineStart(file_diff.right_source, r.start))
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
    if (end >= source.len) return end;
    if (source[end] == '\n') return end + 1;
    if (source[end] == '\r' and end + 1 < source.len and source[end + 1] == '\n') {
        return end + 2;
    }
    return end;
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

    if (state.isCollapsed(id)) {
        try out.append(arena, .{
            .indent = indent,
            .marker = .unchanged,
            .kind = .decl_anchor,
            .text = try line_mod.declHeaderText(arena, u.decl, u.moved, false),
            .decl_id = id,
        });
        try emitCollapsedBody(arena, out, indent, id, u.decl.name, entryLineCount(.{ .unchanged = u }, file_diff));
        advanceCursorsForCollapsedEntry(.{ .unchanged = u }, file_diff, cursors);
        return;
    }

    const annotation = try formatDeclAnnotation(arena, u.decl, u.moved);
    const lr = u.decl.list.byte_range;
    const slice_start = line_mod.lineStart(file_diff.left_source, lr.start);
    try emitSourceLines(
        arena,
        out,
        file_diff,
        indent,
        file_diff.left_source[slice_start..lr.end],
        slice_start,
        u.decl.list,
        .unchanged,
        id,
        cursors,
        .both,
        annotation,
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

    if (state.isCollapsed(id)) {
        try out.append(arena, .{
            .indent = indent,
            .marker = .added,
            .kind = .decl_anchor,
            .text = try line_mod.declHeaderText(arena, a.decl, null, false),
            .decl_id = id,
        });
        try emitCollapsedBody(arena, out, indent, id, a.decl.name, entryLineCount(.{ .added = a }, file_diff));
        advanceCursorsForCollapsedEntry(.{ .added = a }, file_diff, cursors);
        return;
    }

    const annotation = try formatDeclAnnotation(arena, a.decl, null);
    const rr = a.decl.list.byte_range;
    const slice_start = line_mod.lineStart(file_diff.right_source, rr.start);
    try emitSourceLines(
        arena,
        out,
        file_diff,
        indent,
        file_diff.right_source[slice_start..rr.end],
        slice_start,
        a.decl.list,
        .added,
        id,
        cursors,
        .right_only,
        annotation,
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

    if (state.isCollapsed(id)) {
        try out.append(arena, .{
            .indent = indent,
            .marker = .removed,
            .kind = .decl_anchor,
            .text = try line_mod.declHeaderText(arena, r.decl, null, false),
            .decl_id = id,
        });
        try emitCollapsedBody(arena, out, indent, id, r.decl.name, entryLineCount(.{ .removed = r }, file_diff));
        advanceCursorsForCollapsedEntry(.{ .removed = r }, file_diff, cursors);
        return;
    }

    const annotation = try formatDeclAnnotation(arena, r.decl, null);
    const lr = r.decl.list.byte_range;
    const slice_start = line_mod.lineStart(file_diff.left_source, lr.start);
    try emitSourceLines(
        arena,
        out,
        file_diff,
        indent,
        file_diff.left_source[slice_start..lr.end],
        slice_start,
        r.decl.list,
        .removed,
        id,
        cursors,
        .left_only,
        annotation,
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

    if (state.isCollapsed(id)) {
        try out.append(arena, .{
            .indent = indent,
            .marker = .changed,
            .kind = .decl_anchor,
            .text = try line_mod.declHeaderText(arena, c.new, c.moved, false),
            .decl_id = id,
        });
        try emitCollapsedBody(arena, out, indent, id, c.new.name, entryLineCount(.{ .changed = c }, file_diff));
        advanceCursorsForCollapsedEntry(.{ .changed = c }, file_diff, cursors);
        return;
    }

    const annotation = try formatDeclAnnotation(arena, c.new, c.moved);

    switch (c.body) {
        .container => |children| {
            const left_range = toRange(c.old.list.byte_range);
            const right_range = toRange(c.new.list.byte_range);
            const start_idx = out.items.len;
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
            // The container's signature line (`pub const Thing = struct {`)
            // is emitted as part of the leading gap inside the recursion;
            // stamp the annotation + decl_id onto whichever source row
            // appeared first so `findDeclRow` can land on it.
            stampDeclAnnotationOnFirstSource(out.items[start_idx..], annotation, id);
        },
        .leaf => |script| {
            try projectChangedLeaf(arena, out, file_diff, script, c.old, c.new, id, indent, cursors, annotation);
        },
        .import_group => |group| {
            // Import-group annotation reads `(<prefix>, use_group)` rather
            // than `(<full_path>, use_declaration)` so the navigable
            // landmark surfaces the shared prefix the alignment keyed on,
            // not the verbatim path of one side. `formatDeclAnnotation`
            // stays unchanged for every other body so its existing tests
            // and call sites are untouched.
            const ig_annotation = try formatImportGroupAnnotation(arena, group.prefix, c.moved);
            try projectChangedImportGroup(
                arena,
                out,
                file_diff,
                group,
                c.old,
                c.new,
                id,
                indent,
                cursors,
                ig_annotation,
            );
        },
    }
}

/// Reuse `line.zig`'s leaf hunk builder verbatim and post-process the result
/// to fill in per-side line numbers and a `decl_id`. The leaf hunk emits
/// one row per source line on whichever side(s) it appears, so cursor
/// advancement is purely a function of each row's marker.
///
/// `annotation` is stamped onto the first emitted hunk row so the
/// expanded changed leaf still carries the `(name, ts_kind[, moved
/// N → M])` annotation that the dropped `.decl_anchor` row used to
/// surface.
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
    annotation: ?[]const u8,
) !void {
    const hunk_lines = try line_mod.buildLeafHunk(arena, file_diff, script, old_decl, new_decl, indent);
    var stamped = annotation == null;
    for (hunk_lines) |line| {
        var sl = line;
        sl.decl_id = decl_id;
        switch (line.marker) {
            .context, .changed => {
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
        if (!stamped) {
            sl.decl_annotation = annotation;
            stamped = true;
        }
        try out.append(arena, sl);
    }
}

/// Render a paired import-group `Changed` decl as one synthetic
/// `.changed` source row via `line_mod.buildImportGroupLine`, stamping
/// it with the decl's id and inline annotation so it shows up in
/// `decl_index` like any other navigable decl row. The builder synthesizes
/// text from `use` onward, so prepend the right declaration's source indent
/// and shift its highlight spans to keep it aligned with sibling rows.
///
/// The single emitted line stands in for whatever physical line range
/// each side spanned, so per-side line cursors advance by
/// `countLines(byte_range)` rather than `+= 1`. That keeps subsequent
/// gap rendering's per-side line numbers in sync with the source
/// buffers even when one side spans multiple physical lines (the
/// rumqttc multi-line example) and the other a single line.
fn projectChangedImportGroup(
    arena: Allocator,
    out: *std.ArrayList(line_mod.StyledLine),
    file_diff: *const rv.FileDiff,
    group: rv.ImportGroupDiff,
    old_decl: rv.Decl,
    new_decl: rv.Decl,
    decl_id: state_mod.DeclId,
    indent: u8,
    cursors: *Cursors,
    annotation: ?[]const u8,
) !void {
    var line = try line_mod.buildImportGroupLine(arena, group, indent);

    const new_range = new_decl.list.byte_range;
    const source_line_start = line_mod.lineStart(file_diff.right_source, new_range.start);
    const raw_source_indent = file_diff.right_source[source_line_start..new_range.start];
    const source_indent = try line_mod.expandTabs(arena, raw_source_indent);
    line.text = try std.fmt.allocPrint(arena, "{s}{s}", .{ source_indent, line.text });

    const shifted_highlights = try arena.alloc(line_mod.HighlightSpan, line.highlights.len);
    const indent_width: u32 = @intCast(source_indent.len);
    for (line.highlights, shifted_highlights) |highlight, *shifted| {
        shifted.* = highlight;
        shifted.start += indent_width;
        shifted.end += indent_width;
    }
    line.highlights = shifted_highlights;

    line.decl_id = decl_id;
    line.decl_annotation = annotation;
    line.line_no_left = cursors.left_line;
    line.line_no_right = cursors.right_line;
    try out.append(arena, line);

    const old_range = old_decl.list.byte_range;
    cursors.left_line += countLines(file_diff.left_source[old_range.start..old_range.end]);
    cursors.right_line += countLines(file_diff.right_source[new_range.start..new_range.end]);
}

// ── source-line and gap emission ───────────────────────────────────────────

const SideAdvance = enum { both, left_only, right_only };

/// Variant of `formatDeclAnnotation` for `.import_group` changed decls.
/// The annotation reads `(<prefix>, use_group)` (with an optional
/// `, moved N → M` suffix) so the inline landmark identifies the
/// shared path prefix the alignment keyed on rather than the verbatim
/// path of one side. `use_group` is a synthetic ts_kind: it has no
/// counterpart in tree-sitter's grammar, but reads naturally next to
/// `use_declaration` in the rest of the UI.
fn formatImportGroupAnnotation(
    arena: Allocator,
    prefix: []const u8,
    moved: ?rv.MoveInfo,
) ![]const u8 {
    if (moved) |m| {
        return std.fmt.allocPrint(arena, "({s}, use_group, moved {d} → {d})", .{
            prefix, m.from_idx, m.to_idx,
        });
    }
    return std.fmt.allocPrint(arena, "({s}, use_group)", .{prefix});
}

/// Render the trailing `(name, ts_kind)` (or `(name, ts_kind, moved
/// N → M)`) annotation that gets stamped onto the first source row of
/// an expanded decl in lieu of a dedicated `.decl_anchor` row. Anonymous
/// decls fall back to `<anon>` so the annotation never collapses to an
/// empty `()`.
fn formatDeclAnnotation(
    arena: Allocator,
    decl: rv.Decl,
    moved: ?rv.MoveInfo,
) ![]const u8 {
    const name = decl.name orelse "<anon>";
    if (moved) |m| {
        return std.fmt.allocPrint(arena, "({s}, {s}, moved {d} → {d})", .{
            name, decl.ts_kind, m.from_idx, m.to_idx,
        });
    }
    return std.fmt.allocPrint(arena, "({s}, {s})", .{ name, decl.ts_kind });
}

/// Stamp `annotation` onto the first unowned `.source` row in `slice`
/// and tag that row with `decl_id`. "Unowned" means `decl_id == null`,
/// i.e. the row was emitted by `emitGap` rather than by a child decl's
/// projection. Used by the changed-container case where the container's
/// signature line surfaces inside the recursion as a gap row that
/// doesn't otherwise belong to any decl. No-op when `annotation` is
/// null or no unowned source row exists (e.g. when the container and
/// its first child share a line and the leading gap is empty); in that
/// degenerate case the container is left un-navigable rather than
/// hijacking a child decl's row.
fn stampDeclAnnotationOnFirstSource(
    slice: []line_mod.StyledLine,
    annotation: ?[]const u8,
    decl_id: state_mod.DeclId,
) void {
    const ann = annotation orelse return;
    for (slice) |*sl| {
        if (sl.kind != .source) continue;
        if (sl.decl_id != null) return;
        sl.decl_annotation = ann;
        sl.decl_id = decl_id;
        return;
    }
}

/// Emit every source line of `slice` (split on `\n`, trailing empty line
/// dropped) as a `.source` row. Highlights for the whole decl are
/// collected once and clipped per line.
///
/// `annotation`, when non-null, is stamped onto the *first* emitted row's
/// `decl_annotation` field. This lets the file-wide builder inline the
/// `(name, ts_kind)` landmark on the decl's first source line instead
/// of emitting a dedicated `.decl_anchor` row above it.
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
    annotation: ?[]const u8,
) !void {
    const highlights = try line_mod.collectHighlights(arena, decl_list, file_diff.language);

    var cursor_in_slice: usize = 0;
    var line_abs_start: u32 = slice_abs_start;
    var first = true;
    var stamped = annotation == null;
    while (true) {
        const rest = slice[cursor_in_slice..];
        const nl_rel = std.mem.indexOfScalar(u8, rest, '\n');
        const raw_with_cr = if (nl_rel) |p| rest[0..p] else rest;
        if (raw_with_cr.len == 0 and nl_rel == null and !first) break;
        first = false;
        const raw_line = line_mod.stripCarriageReturn(raw_with_cr);

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

        const row_annotation: ?[]const u8 = if (!stamped) blk: {
            stamped = true;
            break :blk annotation;
        } else null;

        try out.append(arena, .{
            .indent = indent,
            .marker = marker,
            .kind = .source,
            .text = expanded,
            .highlights = line_highlights,
            .decl_id = decl_id,
            .line_no_left = line_no_left,
            .line_no_right = line_no_right,
            .decl_annotation = row_annotation,
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
/// pick up `.removed` / `.added` markers. Consecutive `-` / `+` runs
/// pass through `line_mod.alignHunks` so leading-trivia comment blocks
/// (doc comments, `//` notes) on a renamed decl collapse into single
/// inline `.changed` rows the same way leaf bodies do.
///
/// No highlight collection here: gap regions in real source files are
/// almost entirely whitespace, occasionally with stray comments. Painting
/// them at v1 isn't worth the extra SST walking; collapsed `.changed`
/// rows already drop highlights by design (see
/// `tryBuildInlineCollapsedLine`).
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
    const steps = try line_mod.alignHunks(arena, hunks, indent, null);
    for (steps) |step| switch (step) {
        .common => |h| {
            const expanded = try line_mod.expandTabs(arena, h.text);
            const ll = cursors.left_line;
            const rl = cursors.right_line;
            cursors.left_line += 1;
            cursors.right_line += 1;
            try out.append(arena, .{
                .indent = indent,
                .marker = .unchanged,
                .kind = .source,
                .text = expanded,
                .line_no_left = ll,
                .line_no_right = rl,
            });
        },
        .plain => |h| {
            const expanded = try line_mod.expandTabs(arena, h.text);
            var line_no_left: ?u32 = null;
            var line_no_right: ?u32 = null;
            const marker: line_mod.Marker = switch (h.side) {
                .left => blk: {
                    line_no_left = cursors.left_line;
                    cursors.left_line += 1;
                    break :blk .removed;
                },
                .right => blk: {
                    line_no_right = cursors.right_line;
                    cursors.right_line += 1;
                    break :blk .added;
                },
                .common => unreachable,
            };
            try out.append(arena, .{
                .indent = indent,
                .marker = marker,
                .kind = .source,
                .text = expanded,
                .line_no_left = line_no_left,
                .line_no_right = line_no_right,
            });
        },
        .collapsed => |line| {
            // A collapsed pair consumes one line on each side, just like
            // a `.context` / `.unchanged` row would.
            var styled = line;
            styled.line_no_left = cursors.left_line;
            styled.line_no_right = cursors.right_line;
            cursors.left_line += 1;
            cursors.right_line += 1;
            try out.append(arena, styled);
        },
        // Only produced by `alignHunks` when novels are supplied; the
        // gap path passes `null`, so the variant never appears here.
        .right_context => unreachable,
    };
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
        .decl_id = decl_id,
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

fn expectProjectedSources(
    lines: []const line_mod.StyledLine,
    expected_left: []const u8,
    expected_right: []const u8,
) !void {
    var left: std.ArrayList(u8) = .empty;
    defer left.deinit(testing.allocator);
    var right: std.ArrayList(u8) = .empty;
    defer right.deinit(testing.allocator);

    for (lines) |line| {
        if (line.line_no_left != null) {
            try left.appendSlice(testing.allocator, line.text);
            try left.append(testing.allocator, '\n');
        }
        if (line.line_no_right != null) {
            try right.appendSlice(testing.allocator, line.text);
            try right.append(testing.allocator, '\n');
        }
    }
    try testing.expectEqualStrings(
        std.mem.trimEnd(u8, expected_left, "\n"),
        std.mem.trimEnd(u8, left.items, "\n"),
    );
    try testing.expectEqualStrings(
        std.mem.trimEnd(u8, expected_right, "\n"),
        std.mem.trimEnd(u8, right.items, "\n"),
    );
}

test "consumeTrailingNewline consumes a complete CRLF sequence" {
    try testing.expectEqual(@as(u32, 3), consumeTrailingNewline("a\r\n", 1));
}

test "build: hundred-line rewritten function stays bounded" {
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(testing.allocator);
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(testing.allocator);
    try before.appendSlice(testing.allocator, "pub fn stress() void {\n");
    try after.appendSlice(testing.allocator, "pub fn stress() void {\n");
    for (0..100) |i| {
        var buffer: [96]u8 = undefined;
        const old_line = try std.fmt.bufPrint(&buffer, "    const old_{d} = {d};\n", .{ i, i });
        try before.appendSlice(testing.allocator, old_line);
        const new_line = try std.fmt.bufPrint(&buffer, "    const new_{d} = {d};\n", .{ i, i + 1000 });
        try after.appendSlice(testing.allocator, new_line);
    }
    try before.appendSlice(testing.allocator, "}\n");
    try after.appendSlice(testing.allocator, "}\n");

    var fd = try rv.diffSources(testing.allocator, .zig, before.items, after.items);
    defer fd.deinit();
    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    try testing.expect(result.view.unified.len >= 100);
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
    var saw_changed_decl_annotation = false;
    var saw_change_source = false;
    var first_change_idx: ?usize = null;
    var last_change_idx: ?usize = null;
    for (lines, 0..) |ln, i| {
        if (ln.kind != .source) continue;
        switch (ln.marker) {
            .removed, .added, .changed => {
                saw_change_source = true;
                if (first_change_idx == null) first_change_idx = i;
                last_change_idx = i;
            },
            else => {},
        }
        // The 1:1 inline-collapsed leaf change emits a single
        // `.changed` source row whose `decl_annotation` identifies the
        // changed decl `e`. Match `"(e,"` rather than just `"e"` so
        // unrelated annotations whose `ts_kind` happens to contain an
        // `e` (e.g. `function_declaration`) don't satisfy the check.
        if (ln.decl_annotation) |ann| {
            if (std.mem.indexOf(u8, ann, "(e,") != null) saw_changed_decl_annotation = true;
        }
    }
    try testing.expect(saw_changed_decl_annotation);
    try testing.expect(saw_change_source);
    for (lines[0..first_change_idx.?]) |ln| if (ln.kind == .elided) {
        leading_elided += 1;
    };
    for (lines[last_change_idx.? + 1 ..]) |ln| if (ln.kind == .elided) {
        trailing_elided += 1;
    };
    try testing.expect(leading_elided >= 1);
    try testing.expect(trailing_elided >= 1);
}

test "build: added decl emits annotated first source row + full body, flanking unchanged collapse" {
    // Eight unchanged decls flank the added one so the rows past ±3
    // context are guaranteed to elide even with the more compact layout
    // (one fewer row per expanded decl now that anchors are gone).
    const before =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() void {}
        \\pub fn d() void {}
        \\pub fn e() void {}
        \\pub fn f() void {}
        \\pub fn g() void {}
        \\pub fn h() void {}
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() void {}
        \\pub fn d() void {}
        \\pub fn fresh() void {
        \\    return;
        \\}
        \\pub fn e() void {}
        \\pub fn f() void {}
        \\pub fn g() void {}
        \\pub fn h() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    const lines = result.view.unified;

    // Expanded added decl: no `.decl_anchor` row, the first added source
    // row carries the inline `(name, ts_kind)` annotation instead.
    var saw_added_anchor = false;
    var added_source_count: usize = 0;
    var added_with_annotation: usize = 0;
    for (lines) |ln| {
        if (ln.marker == .added and ln.kind == .decl_anchor) saw_added_anchor = true;
        if (ln.marker == .added and ln.kind == .source) {
            added_source_count += 1;
            if (ln.decl_annotation) |ann| {
                try testing.expect(std.mem.indexOf(u8, ann, "fresh") != null);
                added_with_annotation += 1;
            }
        }
    }
    try testing.expect(!saw_added_anchor);
    // The added body has 3 source lines (signature, return, closing brace).
    try testing.expectEqual(@as(usize, 3), added_source_count);
    // Annotation is stamped on exactly one row (the signature).
    try testing.expectEqual(@as(usize, 1), added_with_annotation);

    // Unchanged decls far from the added decl collapse into elided rows.
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
    // windows around the two changed decls overlap, so no `.elided` row
    // should appear between them.
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

    // Locate the two changed decls by their inline annotations. The leaf
    // hunk emits a `.removed` + `.added` pair per change, with the
    // annotation landing on the first row of each pair (the `.removed`
    // line).
    var first_changed: ?usize = null;
    var last_changed: ?usize = null;
    for (lines, 0..) |ln, i| {
        if (ln.kind != .source) continue;
        if (ln.decl_annotation == null) continue;
        if (ln.marker != .removed and ln.marker != .added and ln.marker != .changed) continue;
        if (first_changed == null) first_changed = i;
        last_changed = i;
    }
    try testing.expect(first_changed != null);
    try testing.expect(last_changed != null);
    try testing.expect(first_changed.? != last_changed.?);

    // No `.elided` row between the two changed decls.
    var middle_elided: usize = 0;
    for (lines[first_changed.? .. last_changed.? + 1]) |ln| if (ln.kind == .elided) {
        middle_elided += 1;
    };
    try testing.expectEqual(@as(usize, 0), middle_elided);
}

test "build split: mirrored common rows, paired add/remove runs" {
    // Use leaf bodies whose differing line is dissimilar enough that
    // the inline 1:1 collapse doesn't kick in - the test specifically
    // exercises split-mode `.removed` / `.added` pairing.
    const before =
        \\pub fn a() void {}
        \\pub fn b() u32 {
        \\    QQQQQQQQQQ();
        \\}
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() u32 {
        \\    WWWWWWWWWW();
        \\}
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

test "build: decl_index covers every navigable decl row" {
    // 4 decls expanded → 4 entries in the index, each pointing at the
    // first source row of the decl (the row carrying the inline
    // annotation).
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

    try testing.expectEqual(@as(usize, 4), result.decl_index.len);
    for (result.decl_index) |e| {
        const ln = result.view.unified[e.row];
        // Either an anchor (collapsed) or an annotated source row
        // (expanded). With no collapse state, every entry is the latter.
        try testing.expectEqual(line_mod.LineKind.source, ln.kind);
        try testing.expect(ln.decl_annotation != null);
    }
}

test "build split: adjacent removed and added decl bodies pair on the same row" {
    // Rename: `gone` → `fresh`. Without a `.decl_anchor` row in the
    // mix, the unified stream is just `.removed` source + `.added`
    // source, so the split conversion pairs them onto a single row
    // (left=removed, right=added) like any other adjacent change.
    // Both panes carry their respective inline annotations.
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

    var saw_paired_rename = false;
    for (result.view.split) |p| {
        const left_ok = p.left.kind == .source and p.left.marker == .removed;
        const right_ok = p.right.kind == .source and p.right.marker == .added;
        if (!left_ok or !right_ok) continue;
        const left_ann = p.left.decl_annotation orelse continue;
        const right_ann = p.right.decl_annotation orelse continue;
        try testing.expect(std.mem.indexOf(u8, left_ann, "gone") != null);
        try testing.expect(std.mem.indexOf(u8, right_ann, "fresh") != null);
        saw_paired_rename = true;
    }
    try testing.expect(saw_paired_rename);
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

test "build: changed method aligns with an added sibling" {
    const before =
        \\impl Example {
        \\    pub fn beta(&self) -> u32 {
        \\        self.value
        \\    }
        \\}
    ;
    const after =
        \\impl Example {
        \\    pub fn alpha(&self) -> u32 {
        \\        0
        \\    }
        \\
        \\    pub fn beta(&self) -> u32 {
        \\        self.value + 1
        \\    }
        \\}
    ;

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var added_col: ?usize = null;
    var changed_col: ?usize = null;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        const text_col = std.mem.indexOf(u8, ln.text, "pub fn ") orelse continue;
        const source_col = @as(usize, ln.indent) * 2 + text_col;
        if (std.mem.indexOf(u8, ln.text, "alpha") != null) added_col = source_col;
        if (std.mem.indexOf(u8, ln.text, "beta") != null) changed_col = source_col;
    }

    try testing.expectEqual(
        added_col orelse return error.MissingAddedMethod,
        changed_col orelse return error.MissingChangedMethod,
    );
}

test "build: adding a trait method keeps existing signatures unchanged" {
    const before =
        \\pub trait Example {
        \\    /// Returns alpha.
        \\    fn alpha(&self) -> u32;
        \\}
    ;
    const after =
        \\pub trait Example {
        \\    /// Returns alpha.
        \\    fn alpha(&self) -> u32;
        \\
        \\    /// Returns beta.
        \\    fn beta(&self) -> u32 { 2 }
        \\}
    ;

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var saw_trait = false;
    var saw_alpha = false;
    var saw_beta = false;
    var removed_rows: usize = 0;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        if (ln.marker == .removed) removed_rows += 1;
        if (std.mem.indexOf(u8, ln.text, "trait Example") != null) {
            try testing.expect(ln.marker != .added and ln.marker != .removed);
            saw_trait = true;
        }
        if (std.mem.indexOf(u8, ln.text, "fn alpha") != null) {
            try testing.expect(ln.marker != .added and ln.marker != .removed);
            saw_alpha = true;
        }
        if (std.mem.indexOf(u8, ln.text, "fn beta") != null) {
            try testing.expectEqual(line_mod.Marker.added, ln.marker);
            saw_beta = true;
        }
    }

    try testing.expect(saw_trait);
    try testing.expect(saw_alpha);
    try testing.expect(saw_beta);
    try testing.expectEqual(@as(usize, 0), removed_rows);
}

test "build: nested decl's first source line preserves source-column indent" {
    // Regression: tree-sitter's `byte_range.start` for a nested decl
    // points at the first non-whitespace token (e.g. `async` / `fn`),
    // so slicing `source[rr.start..rr.end]` drops the leading indent on
    // the first physical line. The pre-decl gap deliberately stops at
    // `lineStart(decl.start)`, leaving those indent bytes in no-man's-
    // land. The fix is to extend the decl slice back to `lineStart`,
    // mirroring what `sourceLinesSlice` does on the leaf-body path.
    const before =
        \\mod tests {
        \\    fn existing() {}
        \\}
    ;
    const after =
        \\mod tests {
        \\    fn existing() {}
        \\
        \\    #[tokio::test]
        \\    async fn snapshot_empty_queue() {
        \\        let tmp = 0;
        \\    }
        \\}
    ;
    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var saw_async_fn = false;
    var saw_existing = false;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        if (std.mem.indexOf(u8, ln.text, "async fn snapshot_empty_queue") != null) {
            try testing.expect(std.mem.startsWith(u8, ln.text, "    "));
            saw_async_fn = true;
        }
        if (std.mem.indexOf(u8, ln.text, "fn existing") != null) {
            try testing.expect(std.mem.startsWith(u8, ln.text, "    "));
            saw_existing = true;
        }
    }
    try testing.expect(saw_async_fn);
    try testing.expect(saw_existing);
}

// ── inline decl annotation ────────────────────────────────────────────

test "build: expanded decls emit no `.decl_anchor` rows; annotation lands on first source row" {
    // Three decls, all expanded by default. With no anchors, every decl
    // is anchored on its first emitted source row, which carries the
    // inline `(name, ts_kind)` annotation.
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

    // No `.decl_anchor` row in the view at all — every decl is expanded.
    for (result.view.unified) |ln| try testing.expect(ln.kind != .decl_anchor);

    // Each expanded decl produces exactly one annotated source row.
    var annotated_rows: usize = 0;
    var annotations_seen: [3][]const u8 = undefined;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        if (ln.decl_annotation) |ann| {
            try testing.expect(annotated_rows < annotations_seen.len);
            annotations_seen[annotated_rows] = ann;
            annotated_rows += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), annotated_rows);

    // Each annotation contains the decl name and `ts_kind`.
    var saw_a = false;
    var saw_b = false;
    var saw_c = false;
    for (annotations_seen[0..annotated_rows]) |ann| {
        try testing.expect(std.mem.indexOf(u8, ann, "function_declaration") != null);
        if (std.mem.indexOf(u8, ann, "(a,") != null) saw_a = true;
        if (std.mem.indexOf(u8, ann, "(b,") != null) saw_b = true;
        if (std.mem.indexOf(u8, ann, "(c,") != null) saw_c = true;
    }
    try testing.expect(saw_a);
    try testing.expect(saw_b);
    try testing.expect(saw_c);
}

test "build: row count drops by one per expanded decl vs. emitting a `.decl_anchor` per decl" {
    // The dropped `.decl_anchor` row for each expanded decl is the
    // savings the inline annotation buys. Verify the count exactly:
    // four expanded decls → four rows fewer than (rows + decl_count).
    const before =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() void {}
        \\pub fn d() void {}
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() void {}
        \\pub fn d() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    // Identical sources collapse to a single `.elided` row regardless,
    // so we artificially expand every gap to compare row counts.
    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();
    var initial = try build(testing.allocator, &fd, .unified, &state);
    defer initial.deinit();
    try state.expandAllGaps(initial.view);

    var result = try build(testing.allocator, &fd, .unified, &state);
    defer result.deinit();

    var anchor_count: usize = 0;
    var annotated_source_count: usize = 0;
    for (result.view.unified) |ln| {
        if (ln.kind == .decl_anchor) anchor_count += 1;
        if (ln.kind == .source and ln.decl_annotation != null) annotated_source_count += 1;
    }
    try testing.expectEqual(@as(usize, 0), anchor_count);
    try testing.expectEqual(@as(usize, 4), annotated_source_count);
}

test "build: collapsed decls keep `.decl_anchor` row plus a synthetic elided body row" {
    // Regression guard: the inline-annotation refactor must not change
    // collapsed-decl shape. Each collapsed decl still emits a
    // `.decl_anchor` landmark above an `.elided` synthetic body row, so
    // the existing cursor target for re-expansion stays put.
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 { return 2; }\n";
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

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
    try testing.expect(lines.len >= 2);
    try testing.expectEqual(line_mod.LineKind.decl_anchor, lines[0].kind);
    try testing.expectEqual(line_mod.LineKind.elided, lines[1].kind);
    // The collapsed anchor row carries no inline annotation — its
    // existing `name (ts_kind)` text already tells the user what the
    // decl is, and a redundant suffix would clutter the row.
    try testing.expectEqual(@as(?[]const u8, null), lines[0].decl_annotation);
}

test "build: jump index targets first-source rows for expanded decls and anchors for collapsed ones" {
    const before =
        \\pub fn keep() void {}
        \\pub fn tweak() u32 { return 1; }
    ;
    const after =
        \\pub fn keep() void {}
        \\pub fn tweak() u32 { return 2; }
        \\pub fn added() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    // Collapse `tweak` to verify the per-decl mode dispatch.
    var collapse_id: state_mod.DeclId = 0;
    for (fd.entries) |e| if (e == .changed) {
        collapse_id = state_mod.declId(e.changed.new);
    };
    var state = state_mod.AppState.init(testing.allocator);
    defer state.deinit();
    _ = try state.toggle(collapse_id);

    var result = try build(testing.allocator, &fd, .unified, &state);
    defer result.deinit();

    // Three decls → three index entries.
    try testing.expectEqual(@as(usize, 3), result.decl_index.len);

    var saw_collapsed_anchor = false;
    var saw_expanded_source = false;
    for (result.decl_index) |e| {
        const ln = result.view.unified[e.row];
        switch (ln.kind) {
            .decl_anchor => {
                // Only the collapsed `tweak` produces an anchor row.
                try testing.expectEqual(collapse_id, ln.decl_id.?);
                saw_collapsed_anchor = true;
            },
            .source => {
                try testing.expect(ln.decl_annotation != null);
                saw_expanded_source = true;
            },
            else => return error.UnexpectedKind,
        }
    }
    try testing.expect(saw_collapsed_anchor);
    try testing.expect(saw_expanded_source);
}

test "build: reordered declarations preserve both source projections" {
    const before =
        \\pub fn a() void {}
        \\pub fn b() void {}
    ;
    const after =
        \\pub fn b() void {}
        \\pub fn a() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    try expectProjectedSources(result.view.unified, before, after);
}

test "formatDeclAnnotation: shape matches `(name, ts_kind)` with optional move suffix" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Synthetic Decl: only `name` and `ts_kind` are read by the helper,
    // the rest of the struct is irrelevant for the format check.
    var dummy_list: rv.List = undefined;
    const decl: rv.Decl = .{
        .kind = .other,
        .ts_kind = "function_declaration",
        .name = "greet",
        .list = &dummy_list,
    };

    const plain = try formatDeclAnnotation(a, decl, null);
    try testing.expectEqualStrings("(greet, function_declaration)", plain);

    const moved = try formatDeclAnnotation(a, decl, .{ .from_idx = 2, .to_idx = 7 });
    try testing.expectEqualStrings("(greet, function_declaration, moved 2 → 7)", moved);
}

test "build: changed container's signature line carries the container annotation" {
    // For a `.changed` container, the container's signature line
    // (`pub const Thing = struct {`) surfaces inside the recursion as
    // a gap row. The inline annotation must still land on that row so
    // the container is navigable from the file-wide view.
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

    var saw_container_annotation = false;
    var container_id: ?state_mod.DeclId = null;
    for (fd.entries) |e| if (e == .changed) {
        container_id = state_mod.declId(e.changed.new);
    };
    try testing.expect(container_id != null);

    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        const ann = ln.decl_annotation orelse continue;
        if (std.mem.indexOf(u8, ann, "Thing") == null) continue;
        // The annotation row also takes the container's decl_id so
        // `findDeclRow` can land on it.
        try testing.expectEqual(container_id.?, ln.decl_id.?);
        try testing.expect(std.mem.startsWith(u8, ln.text, "pub const Thing"));
        saw_container_annotation = true;
    }
    try testing.expect(saw_container_annotation);
}

test "build: same-line container does not hijack the first child's decl_id" {
    // Degenerate case: container and first child share a source line, so
    // the leading gap inside the recursion is empty and the first source
    // row in the recursion belongs to the child rather than to a gap.
    // `stampDeclAnnotationOnFirstSource` must skip rows that already have
    // a `decl_id`, otherwise the container's annotation hijacks the
    // child's row and the child becomes un-navigable.
    const before =
        \\pub const Thing = struct { fn one() void {} };
    ;
    const after =
        \\pub const Thing = struct { fn one() u32 { return 1; } };
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var container_id: ?state_mod.DeclId = null;
    var child_id: ?state_mod.DeclId = null;
    for (fd.entries) |e| if (e == .changed) {
        container_id = state_mod.declId(e.changed.new);
        // Sanity: this fixture must hit the .container path in
        // `projectChanged`, otherwise the bug we're guarding against is
        // unreachable from this test.
        try testing.expect(e.changed.body == .container);
        for (e.changed.body.container) |child| switch (child) {
            .changed => |c| child_id = state_mod.declId(c.new),
            else => {},
        };
    };
    try testing.expect(container_id != null);
    try testing.expect(child_id != null);
    try testing.expect(container_id.? != child_id.?);

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    // Whatever decl_id the first source row carries, it must not be the
    // child's — that would mean the container hijacked the child's row.
    // (In this degenerate case the container is left un-navigable, which
    // is the lesser evil.)
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        if (ln.decl_id) |id| {
            // The first owned source row must belong to a real decl, not
            // to a hijacked one. Specifically: rows annotated for the
            // child must still report the child's id.
            if (ln.decl_annotation != null and id == container_id.?) {
                // Tolerated only if no child source row exists in the
                // view — but this fixture has one, so this is a fail.
                try testing.expect(false);
            }
        }
    }
}

// ── import-group rendering (subtask 3) ─────────────────────────────────

/// Locate the single `.changed` source row produced by an import-group
/// projection. Tests use this to skip past the file's gap and elided
/// rows and land on the merged row directly.
fn findImportGroupRow(lines: []const line_mod.StyledLine) ?line_mod.StyledLine {
    for (lines) |ln| {
        if (ln.kind != .source) continue;
        if (ln.marker != .changed) continue;
        if (std.mem.startsWith(u8, ln.text, "use ")) return ln;
    }
    return null;
}

test "build: serde import-group renders as one .changed row with `Deserialize` tagged added" {
    const before = "use serde::Serialize;\n";
    const after = "use serde::{Deserialize, Serialize};\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    // Exactly one `.changed` source row (the merged import-group line).
    var changed_source_count: usize = 0;
    for (result.view.unified) |ln| {
        if (ln.kind == .source and ln.marker == .changed) changed_source_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), changed_source_count);

    const row = findImportGroupRow(result.view.unified) orelse return error.MissingImportGroupRow;
    try testing.expectEqualStrings("use serde::{Deserialize, Serialize};", row.text);

    var saw_added = false;
    for (row.highlights) |h| {
        if (h.class != .inline_added) continue;
        try testing.expectEqualStrings("Deserialize", row.text[h.start..h.end]);
        saw_added = true;
    }
    try testing.expect(saw_added);
}

test "build: nested import-group aligns with surrounding use declarations" {
    const before =
        \\mod example {
        \\    use crate::alpha::alpha;
        \\    use crate::beta::{Bravo, Charlie, delta, echo};
        \\    use crate::*;
        \\}
    ;
    const after =
        \\mod example {
        \\    use crate::alpha::alpha;
        \\    use crate::beta::{Bravo, Charlie, delta, echo, foxtrot};
        \\    use crate::*;
        \\}
    ;

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var context_col: ?usize = null;
    var changed_col: ?usize = null;
    var saw_added_highlight = false;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        const source_col = @as(usize, ln.indent) * 2 +
            (std.mem.indexOf(u8, ln.text, "use ") orelse continue);
        if (std.mem.indexOf(u8, ln.text, "alpha::alpha") != null) {
            context_col = source_col;
        }
        if (std.mem.indexOf(u8, ln.text, "foxtrot") != null) {
            changed_col = source_col;
            for (ln.highlights) |highlight| {
                const highlighted = ln.text[highlight.start..highlight.end];
                if (highlight.class == .inline_added and
                    std.mem.eql(u8, highlighted, "foxtrot"))
                {
                    saw_added_highlight = true;
                }
            }
        }
    }

    try testing.expectEqual(
        context_col orelse return error.MissingContextUse,
        changed_col orelse return error.MissingChangedUse,
    );
    try testing.expect(saw_added_highlight);
}

test "build: rumqttc multi-line vs single-line import-group collapses to one row" {
    const before = "use rumqttc::{AsyncClient, ConnectionError, Event, EventLoop, MqttOptions, Packet, QoS};\n";
    const after = "use rumqttc::{\n    AsyncClient, ConnectionError, Event, EventLoop, MqttOptions, Packet, QoS, Transport,\n};\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    const row = findImportGroupRow(result.view.unified) orelse return error.MissingImportGroupRow;
    try testing.expect(std.mem.indexOf(u8, row.text, "Transport") != null);

    var saw_transport_added = false;
    for (row.highlights) |h| {
        if (h.class != .inline_added) continue;
        if (std.mem.eql(u8, row.text[h.start..h.end], "Transport")) saw_transport_added = true;
    }
    try testing.expect(saw_transport_added);

    // First physical line on each side (both decls start at line 1).
    try testing.expectEqual(@as(?u32, 1), row.line_no_left);
    try testing.expectEqual(@as(?u32, 1), row.line_no_right);
}

test "build: rename use decl splices removed and added symbols inline" {
    const before = "use std::sync::Old;\n";
    const after = "use std::sync::New;\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    const row = findImportGroupRow(result.view.unified) orelse return error.MissingImportGroupRow;
    try testing.expectEqualStrings("use std::sync::{Old, New};", row.text);
    try testing.expect(std.mem.indexOf(u8, row.text, "removed:") == null);

    var saw_new_added = false;
    var saw_old_removed = false;
    for (row.highlights) |h| {
        const slice = row.text[h.start..h.end];
        if (h.class == .inline_added and std.mem.eql(u8, slice, "New")) saw_new_added = true;
        if (h.class == .inline_removed and std.mem.eql(u8, slice, "Old")) saw_old_removed = true;
    }
    try testing.expect(saw_new_added);
    try testing.expect(saw_old_removed);
}

test "build: all-kept reorder of an import-group does not produce a `.changed` row" {
    // Engine-layer regression smoke: alignment subtask demotes
    // reorder-only bodies to `.unchanged`, so the file view must show
    // no `.changed` row for the use decl.
    const before = "use foo::{a, b};\n";
    const after = "use foo::{b, a};\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        if (ln.marker == .changed) {
            try testing.expect(!std.mem.startsWith(u8, ln.text, "use "));
        }
    }
}

test "build: import-group line shows up in decl_index exactly once with changed = true" {
    const before = "use serde::Serialize;\n";
    const after = "use serde::{Deserialize, Serialize};\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var ig_entries: usize = 0;
    for (result.decl_index) |e| {
        const ln = result.view.unified[e.row];
        if (ln.kind == .source and std.mem.startsWith(u8, ln.text, "use ")) {
            try testing.expect(e.changed);
            ig_entries += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), ig_entries);
}

test "build: import-group stats counter increments `changed` once for the merged group" {
    const before = "use serde::Serialize;\n";
    const after = "use serde::{Deserialize, Serialize};\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stats.changed);
    try testing.expectEqual(@as(usize, 0), result.stats.added);
    try testing.expectEqual(@as(usize, 0), result.stats.removed);
}

test "build split: import-group emits the same merged line on both panes" {
    const before = "use serde::Serialize;\n";
    const after = "use serde::{Deserialize, Serialize};\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .split);
    defer result.deinit();

    var saw_mirrored = false;
    for (result.view.split) |p| {
        if (p.left.kind != .source or p.right.kind != .source) continue;
        if (!std.mem.startsWith(u8, p.left.text, "use ")) continue;
        try testing.expectEqualStrings(p.left.text, p.right.text);
        try testing.expectEqual(p.left.marker, p.right.marker);
        try testing.expectEqual(line_mod.Marker.changed, p.left.marker);
        saw_mirrored = true;
    }
    try testing.expect(saw_mirrored);
}

test "build: reordered changed import group preserves both source projections" {
    const before = "use serde::Serialize;\nfn x() {}\n";
    const after = "fn x() {}\nuse serde::{Deserialize, Serialize};\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    try expectProjectedSources(result.view.unified, before, after);
}

test "build: doc-comment rename in gap before a changed decl collapses to inline `~` rows" {
    // Engine emits the leading-trivia comment block as part of the gap
    // region between file start and the decl. Without `emitGap` running
    // through `line_mod.alignHunks`, those comments would render as four
    // separate `-` / `+` rows even for a clean rename. After the fix
    // they collapse into two `.changed` rows that mirror how leaf bodies
    // already render the same kind of pair.
    const before =
        \\/// Creates a minimal [`Foo`] from epoch.
        \\// TODO: Remove this once `Foo` is ready.
        \\pub fn mk() -> Foo { Foo {} }
        \\
    ;
    const after =
        \\/// Creates a minimal [`Bar`] from epoch.
        \\// TODO: Remove this once `Bar` is ready.
        \\pub fn mk() -> Bar { Bar {} }
        \\
    ;

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var saw_doc = false;
    var saw_todo = false;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        if (std.mem.startsWith(u8, ln.text, "/// ")) {
            try testing.expectEqual(line_mod.Marker.changed, ln.marker);
            try testing.expectEqual(@as(?u32, 1), ln.line_no_left);
            try testing.expectEqual(@as(?u32, 1), ln.line_no_right);
            try expectInlineRename(ln, "Foo", "Bar");
            saw_doc = true;
        }
        if (std.mem.startsWith(u8, ln.text, "// TODO")) {
            try testing.expectEqual(line_mod.Marker.changed, ln.marker);
            try testing.expectEqual(@as(?u32, 2), ln.line_no_left);
            try testing.expectEqual(@as(?u32, 2), ln.line_no_right);
            try expectInlineRename(ln, "Foo", "Bar");
            saw_todo = true;
        }
    }
    try testing.expect(saw_doc);
    try testing.expect(saw_todo);
}

fn expectInlineRename(
    ln: line_mod.StyledLine,
    removed: []const u8,
    added: []const u8,
) !void {
    var saw_removed = false;
    var saw_added = false;
    for (ln.highlights) |h| {
        const slice = ln.text[h.start..h.end];
        if (h.class == .inline_removed and std.mem.eql(u8, slice, removed)) saw_removed = true;
        if (h.class == .inline_added and std.mem.eql(u8, slice, added)) saw_added = true;
    }
    try testing.expect(saw_removed);
    try testing.expect(saw_added);
}

//! FileDiff → view lines. Pure, tty-free, unit-testable.
//!
//! Two rendering modes share this builder:
//!
//!   `.unified` produces a flat `[]StyledLine`:
//!     = name                (unchanged: dim, one line)
//!     + name  (ts_kind)     (added: green header + verbatim right-source as + lines)
//!     - name  (ts_kind)     (removed: red header + verbatim left-source as - lines)
//!     ~ name  (ts_kind)     (changed leaf: yellow header + git-style hunk of the body:
//!                            ` context, - removed, + added lines produced by a linewise
//!                            LCS in `hunk.zig`)
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
const hunk_mod = @import("hunk.zig");
const state_mod = @import("state.zig");
const theme = @import("theme.zig");

pub const AppState = state_mod.AppState;
pub const DeclId = state_mod.DeclId;
pub const GapId = state_mod.GapId;
pub const declId = state_mod.declId;
pub const TokenClass = theme.TokenClass;

pub const Marker = enum(u8) {
    /// Unchanged header.
    unchanged,
    /// Added decl header, or a source line from an added decl.
    added,
    /// Removed decl header, or a source line from a removed decl.
    removed,
    /// Changed decl header (leaf or container).
    changed,
    /// Blank separator between entries.
    blank,
    /// Unchanged context line inside a changed leaf's hunk - the LCS
    /// anchors between `-` / `+` runs. Uses a blank ` ` gutter like git,
    /// so it reads as structural filler rather than a decl-level state.
    context,

    pub fn gutter(self: Marker) []const u8 {
        return switch (self) {
            .unchanged => "=",
            .added => "+",
            .removed => "-",
            .changed => "~",
            .blank, .context => " ",
        };
    }
};

/// Classification of a line for styling. `decl_header` lines get bold + color;
/// `source` lines get a softer fg to keep the header scannable.
///
/// `.decl_anchor` and `.elided` are emitted only by the file-wide builder
/// (`file_view.zig`) and rendered through dedicated helpers, not via
/// `Marker.gutter()` / `styleFor`. The decl-axis builder in this module
/// never emits them.
pub const LineKind = enum {
    decl_header,
    source,
    blank,
    /// Thin landmark row above a decl's first source line in the file-
    /// wide view. Carries the decl's name + `ts_kind` so existing
    /// `n`/`p`/`N`/`P` jump navigation still has anchors to land on.
    decl_anchor,
    /// Collapsed run of unchanged lines in the file-wide view, rendered
    /// as `… N unchanged lines …`. Carries `gap_id` so toggling can
    /// flip the corresponding entry in `AppState.expanded_gaps`.
    elided,
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
    /// Syntax-highlight spans: per-atom `(start, end, class)` runs in
    /// display coordinates, sorted by `start`, non-overlapping. Populated
    /// on `source` lines only - decl headers and blanks leave this
    /// empty. Gaps between spans (whitespace, unclassified punctuation)
    /// inherit the line's base marker style.
    highlights: []const HighlightSpan = &.{},
    /// Stable identity of the decl this line belongs to. Set on
    /// `decl_header` lines (used by `app.zig` to locate the focused decl
    /// for collapse/expand toggles); `null` on source, blank, and file-
    /// header lines.
    decl_id: ?DeclId = null,
    /// 1-indexed left-side (pre-image) line number. Populated by the
    /// file-wide builder on rows that exist in the left source: removed,
    /// context, and the left side of a paired change. `null` on `.added`,
    /// `.decl_anchor`, `.elided`, and `.blank` rows.
    line_no_left: ?u32 = null,
    /// 1-indexed right-side (post-image) line number. Populated by the
    /// file-wide builder on rows that exist in the right source: added,
    /// context, and the right side of a paired change. `null` on
    /// `.removed`, `.decl_anchor`, `.elided`, and `.blank` rows.
    line_no_right: ?u32 = null,
    /// Stable identity of the elided gap this row represents. Set only
    /// on `.elided` rows; `null` everywhere else.
    gap_id: ?GapId = null,
    /// Trailing dim annotation rendered to the right of `text`. Used by
    /// the file-wide builder to stamp a decl's `(name, ts_kind[, moved
    /// N → M])` onto its first source row in lieu of a dedicated
    /// `.decl_anchor` landmark line. `null` everywhere else.
    decl_annotation: ?[]const u8 = null,
};

pub const ByteSpan = struct { start: u32, end: u32 };

pub const HighlightSpan = struct {
    start: u32,
    end: u32,
    class: TokenClass,
};

/// Pre-collected novel byte ranges for one side of a `changed` leaf, used to
/// paint `StyledLine.novel_spans`. An empty slice means no highlighting.
const Novels = []const ByteSpan;

/// Pre-collected absolute-byte token spans for a single decl's body,
/// produced by walking the decl's SST `List` and classifying each atom.
/// An empty slice means no syntax highlighting (e.g. nothing we could
/// classify above `.ident` / `.punct`).
const Highlights = []const HighlightSpan;

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

/// One entry per decl header in the current view, in row order. Lets
/// `app.zig` jump to the next/previous decl without scanning the full
/// line list on every keypress and supports the `N`/`P` "changed only"
/// variant via the `changed` flag.
pub const DeclIndexEntry = struct {
    /// Absolute row in the current view; same units as `AppState.cursor_y`.
    row: usize,
    /// True when the decl's header marker is `added`, `removed`, or
    /// `changed` - the set that `N`/`P` iterate. Unchanged headers have
    /// this set to false.
    changed: bool,
};

pub const BuildResult = struct {
    view: View,
    stats: Stats,
    /// Row index of every decl header, in view order. Built as a side
    /// table alongside the view so `n`/`p`/`N`/`P`/`g`/`G` navigation
    /// doesn't have to rescan the whole line list per keypress.
    decl_index: []const DeclIndexEntry,
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
///
/// `state.collapsed` is consulted per decl: collapsed added/removed/changed
/// decls have their bodies suppressed and their headers suffixed with
/// ` […]`. Everything else (scroll, cursor) is ignored here; those are
/// view-only concerns for `app.zig`.
pub fn build(
    gpa: std.mem.Allocator,
    file_diff: *const rv.FileDiff,
    mode: Mode,
    state: *const AppState,
) !BuildResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var stats: Stats = .{};
    const view: View = switch (mode) {
        .unified => blk: {
            var out: std.ArrayList(StyledLine) = .empty;
            try appendEntries(arena, &out, &stats, state, file_diff, file_diff.entries, 0);
            break :blk .{ .unified = try out.toOwnedSlice(arena) };
        },
        .split => blk: {
            var out: std.ArrayList(LinePair) = .empty;
            try appendEntriesSplit(arena, &out, &stats, state, file_diff, file_diff.entries, 0);
            break :blk .{ .split = try out.toOwnedSlice(arena) };
        },
    };

    const decl_index = try collectDeclIndex(arena, view);

    return .{
        .view = view,
        .stats = stats,
        .decl_index = decl_index,
        .arena = arena_state,
    };
}

/// Single post-pass over the built view, recording the row of every
/// `decl_header` line plus whether it represents a changed decl. Split
/// view: for mirrored (unchanged/changed) headers either side works;
/// `headerSide` already picks a non-blank pane for added/removed.
fn collectDeclIndex(arena: std.mem.Allocator, view: View) ![]const DeclIndexEntry {
    var out: std.ArrayList(DeclIndexEntry) = .empty;
    switch (view) {
        .unified => |lines| for (lines, 0..) |ln, i| {
            if (ln.kind != .decl_header) continue;
            try out.append(arena, .{
                .row = i,
                .changed = isChangedMarker(ln.marker),
            });
        },
        .split => |pairs| for (pairs, 0..) |p, i| {
            const side = p.headerSide() orelse continue;
            try out.append(arena, .{
                .row = i,
                .changed = isChangedMarker(side.marker),
            });
        },
    }
    return try out.toOwnedSlice(arena);
}

fn isChangedMarker(m: Marker) bool {
    return m == .added or m == .removed or m == .changed;
}

fn appendEntries(
    arena: std.mem.Allocator,
    out: *std.ArrayList(StyledLine),
    stats: *Stats,
    state: *const AppState,
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
                    .text = try declHeaderText(arena, u.decl, u.moved, false),
                    .decl_id = declId(u.decl),
                });
            },
            .added => |a| {
                stats.added += 1;
                const id = declId(a.decl);
                const collapsed = state.isCollapsed(id);
                try out.append(arena, .{
                    .indent = indent,
                    .marker = .added,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, a.decl, null, collapsed),
                    .decl_id = id,
                });
                if (!collapsed) try appendSourceLines(
                    arena,
                    out,
                    file_diff.right_source,
                    a.decl.list,
                    file_diff.language,
                    indent + 1,
                    .added,
                );
            },
            .removed => |r| {
                stats.removed += 1;
                const id = declId(r.decl);
                const collapsed = state.isCollapsed(id);
                try out.append(arena, .{
                    .indent = indent,
                    .marker = .removed,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, r.decl, null, collapsed),
                    .decl_id = id,
                });
                if (!collapsed) try appendSourceLines(
                    arena,
                    out,
                    file_diff.left_source,
                    r.decl.list,
                    file_diff.language,
                    indent + 1,
                    .removed,
                );
            },
            .changed => |c| {
                stats.changed += 1;
                const id = declId(c.new);
                const collapsed = state.isCollapsed(id);
                try out.append(arena, .{
                    .indent = indent,
                    .marker = .changed,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, c.new, c.moved, collapsed),
                    .decl_id = id,
                });
                if (collapsed) continue;
                switch (c.body) {
                    .container => |children| try appendEntries(arena, out, stats, state, file_diff, children, indent + 1),
                    .leaf => |script| {
                        const hunk_lines = try buildLeafHunk(arena, file_diff, script, c.old, c.new, indent + 1);
                        try out.appendSlice(arena, hunk_lines);
                    },
                    .import_group => |group| {
                        const line = try buildImportGroupLine(arena, group, indent + 1);
                        try out.append(arena, line);
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
    state: *const AppState,
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
                    .text = try declHeaderText(arena, u.decl, u.moved, false),
                    .decl_id = declId(u.decl),
                };
                try out.append(arena, .{ .left = header, .right = header });
            },
            .added => |a| {
                stats.added += 1;
                const id = declId(a.decl);
                const collapsed = state.isCollapsed(id);
                const header: StyledLine = .{
                    .indent = indent,
                    .marker = .added,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, a.decl, null, collapsed),
                    .decl_id = id,
                };
                try out.append(arena, .{ .left = blankLine(indent), .right = header });
                if (collapsed) continue;
                const src_lines = try sourceLinesSlice(
                    arena,
                    file_diff.right_source,
                    a.decl.list,
                    file_diff.language,
                    indent + 1,
                    .added,
                );
                for (src_lines) |line_right| {
                    try out.append(arena, .{ .left = blankLine(indent + 1), .right = line_right });
                }
            },
            .removed => |r| {
                stats.removed += 1;
                const id = declId(r.decl);
                const collapsed = state.isCollapsed(id);
                const header: StyledLine = .{
                    .indent = indent,
                    .marker = .removed,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, r.decl, null, collapsed),
                    .decl_id = id,
                };
                try out.append(arena, .{ .left = header, .right = blankLine(indent) });
                if (collapsed) continue;
                const src_lines = try sourceLinesSlice(
                    arena,
                    file_diff.left_source,
                    r.decl.list,
                    file_diff.language,
                    indent + 1,
                    .removed,
                );
                for (src_lines) |line_left| {
                    try out.append(arena, .{ .left = line_left, .right = blankLine(indent + 1) });
                }
            },
            .changed => |c| {
                stats.changed += 1;
                const id = declId(c.new);
                const collapsed = state.isCollapsed(id);
                const header: StyledLine = .{
                    .indent = indent,
                    .marker = .changed,
                    .kind = .decl_header,
                    .text = try declHeaderText(arena, c.new, c.moved, collapsed),
                    .decl_id = id,
                };
                try out.append(arena, .{ .left = header, .right = header });
                if (collapsed) continue;
                switch (c.body) {
                    .container => |children| try appendEntriesSplit(
                        arena,
                        out,
                        stats,
                        state,
                        file_diff,
                        children,
                        indent + 1,
                    ),
                    .leaf => |script| {
                        const hunk_lines = try buildLeafHunk(arena, file_diff, script, c.old, c.new, indent + 1);
                        try appendLeafHunkPairs(arena, out, hunk_lines, indent + 1);
                    },
                    .import_group => |group| {
                        const line = try buildImportGroupLine(arena, group, indent + 1);
                        try out.append(arena, .{ .left = line, .right = line });
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

/// Render the body of a changed leaf as a git-style hunk. Runs a
/// linewise LCS (`hunk.zig`) over the two leaf byte ranges and emits one
/// `StyledLine` per `HunkLine`:
///
///   `.common` → `marker = .context`, no novel spans (the line is
///               identical on both sides by definition).
///   `.left`   → `marker = .removed` with left-side novel and highlight
///               spans mapped in.
///   `.right`  → `marker = .added` with right-side novel and highlight
///               spans mapped in.
///
/// Returned lines are arena-owned and caller-owned; they go straight into
/// the unified output or get re-paired for split mode (see
/// `appendLeafHunkPairs`).
pub fn buildLeafHunk(
    arena: std.mem.Allocator,
    file_diff: *const rv.FileDiff,
    script: rv.EditScript,
    old_decl: rv.Decl,
    new_decl: rv.Decl,
    indent: u8,
) ![]const StyledLine {
    const left_start = old_decl.list.byte_range.start;
    const left_end = old_decl.list.byte_range.end;
    const right_start = new_decl.list.byte_range.start;
    const right_end = new_decl.list.byte_range.end;

    const left_slice = file_diff.left_source[left_start..left_end];
    const right_slice = file_diff.right_source[right_start..right_end];

    const left_novels = try collectAtomNovels(arena, script, .left);
    const right_novels = try collectAtomNovels(arena, script, .right);
    const left_highlights = try collectHighlights(arena, old_decl.list, file_diff.language);
    const right_highlights = try collectHighlights(arena, new_decl.list, file_diff.language);

    const hunks = try hunk_mod.hunk(arena, left_slice, right_slice);

    var out: std.ArrayList(StyledLine) = .empty;
    for (hunks) |h| {
        const marker: Marker = switch (h.side) {
            .common => .context,
            .left => .removed,
            .right => .added,
        };
        // Common lines are taken from the left slice by convention; their
        // highlights come from the left-side SST for the same reason.
        // Because the line bytes are identical, choosing left vs right
        // yields the same colouring in practice.
        const abs_start: u32 = switch (h.side) {
            .common, .left => left_start + h.offset,
            .right => right_start + h.offset,
        };
        const line_highlights_src: Highlights = switch (h.side) {
            .common, .left => left_highlights,
            .right => right_highlights,
        };
        const line_novels: []const ByteSpan = switch (h.side) {
            .left => try mapNovelsToLine(arena, h.text, abs_start, left_novels),
            .right => try mapNovelsToLine(arena, h.text, abs_start, right_novels),
            .common => &.{},
        };
        const line_highlights = try mapHighlightsToLine(
            arena,
            h.text,
            abs_start,
            line_highlights_src,
        );
        const expanded = try expandTabs(arena, h.text);

        try out.append(arena, .{
            .indent = indent,
            .marker = marker,
            .kind = .source,
            .text = expanded,
            .novel_spans = line_novels,
            .highlights = line_highlights,
        });
    }
    return try out.toOwnedSlice(arena);
}

/// Render a `Changed` import-group body as a single inline `.changed`
/// source row. Walks `group.entries`, splices kept-and-added symbols into
/// the canonical `use <prefix>::{ ... };` form (or a single-symbol form
/// when only one such symbol exists, regardless of removals), and surfaces
/// any removed symbols as a trailing dim ` removed: a, b` suffix so the
/// brace text stays parseable Rust.
///
/// Per-symbol tints come through `StyledLine.highlights`: kept symbols
/// get the neutral `.ident` class (so they inherit the `.changed`
/// marker colour), added symbols get `.import_symbol_added`, the literal
/// `removed:` label gets `.comment`, and each name in the suffix gets
/// `.import_symbol_removed`. The renderer in `app.zig` then layers
/// those on top of the row's marker style without any new code paths.
///
/// The synthesized text contains no tabs, so byte offsets in the
/// returned `text` double as display offsets - no `expandTabs` /
/// `mapHighlightsToLine` round-trip is needed.
pub fn buildImportGroupLine(
    arena: std.mem.Allocator,
    group: rv.ImportGroupDiff,
    indent: u8,
) !StyledLine {
    const Symbol = struct { text: []const u8, class: TokenClass };
    var kept_or_added: std.ArrayList(Symbol) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    for (group.entries) |entry| switch (entry) {
        .kept => |s| try kept_or_added.append(arena, .{ .text = s.text, .class = .ident }),
        .added => |s| try kept_or_added.append(arena, .{ .text = s.text, .class = .import_symbol_added }),
        .removed => |s| try removed.append(arena, s.text),
    };

    var buf: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(HighlightSpan) = .empty;

    try buf.appendSlice(arena, "use ");
    try buf.appendSlice(arena, group.prefix);
    try buf.appendSlice(arena, "::");

    // Single-symbol form is allowed even when there are removals: the
    // suffix surfaces those, the inline brace would otherwise just
    // wrap one identifier. `use foo::{};` (zero kept-or-added) still
    // takes the brace path so the produced text is the empty-brace
    // degenerate case rather than a stray `use foo::;`.
    const use_brace = kept_or_added.items.len != 1;
    if (use_brace) try buf.append(arena, '{');

    for (kept_or_added.items, 0..) |sym, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        const sym_start: u32 = @intCast(buf.items.len);
        try buf.appendSlice(arena, sym.text);
        const sym_end: u32 = @intCast(buf.items.len);
        try spans.append(arena, .{ .start = sym_start, .end = sym_end, .class = sym.class });
    }

    if (use_brace) try buf.append(arena, '}');
    try buf.append(arena, ';');

    if (removed.items.len > 0) {
        try buf.append(arena, ' ');
        const label_start: u32 = @intCast(buf.items.len);
        try buf.appendSlice(arena, "removed:");
        const label_end: u32 = @intCast(buf.items.len);
        try spans.append(arena, .{
            .start = label_start,
            .end = label_end,
            .class = .comment,
        });
        for (removed.items, 0..) |sym, i| {
            try buf.appendSlice(arena, if (i == 0) " " else ", ");
            const sym_start: u32 = @intCast(buf.items.len);
            try buf.appendSlice(arena, sym);
            const sym_end: u32 = @intCast(buf.items.len);
            try spans.append(arena, .{
                .start = sym_start,
                .end = sym_end,
                .class = .import_symbol_removed,
            });
        }
    }

    return .{
        .indent = indent,
        .marker = .changed,
        .kind = .source,
        .text = try buf.toOwnedSlice(arena),
        .highlights = try spans.toOwnedSlice(arena),
    };
}

/// Convert the unified hunk-line sequence produced by `buildLeafHunk`
/// into split-view `LinePair`s. `.context` lines mirror onto both panes;
/// consecutive `-` / `+` runs are batched and paired 1:1 with blank
/// filler on whichever side runs out first (so a common line always
/// re-anchors both panes to the same row).
fn appendLeafHunkPairs(
    arena: std.mem.Allocator,
    out: *std.ArrayList(LinePair),
    lines: []const StyledLine,
    indent: u8,
) !void {
    var pending_left: std.ArrayList(StyledLine) = .empty;
    var pending_right: std.ArrayList(StyledLine) = .empty;

    for (lines) |sl| switch (sl.marker) {
        .removed => try pending_left.append(arena, sl),
        .added => try pending_right.append(arena, sl),
        .context => {
            try flushPendingPairs(arena, out, &pending_left, &pending_right, indent);
            try out.append(arena, .{ .left = sl, .right = sl });
        },
        else => unreachable,
    };
    try flushPendingPairs(arena, out, &pending_left, &pending_right, indent);
}

pub fn flushPendingPairs(
    arena: std.mem.Allocator,
    out: *std.ArrayList(LinePair),
    left: *std.ArrayList(StyledLine),
    right: *std.ArrayList(StyledLine),
    indent: u8,
) !void {
    const n = @max(left.items.len, right.items.len);
    for (0..n) |i| {
        const l = if (i < left.items.len) left.items[i] else blankLine(indent);
        const r = if (i < right.items.len) right.items[i] else blankLine(indent);
        try out.append(arena, .{ .left = l, .right = r });
    }
    left.clearRetainingCapacity();
    right.clearRetainingCapacity();
}

pub fn declHeaderText(
    arena: std.mem.Allocator,
    decl: rv.Decl,
    moved: ?rv.MoveInfo,
    collapsed: bool,
) ![]const u8 {
    const name = decl.name orelse "<anon>";
    const suffix: []const u8 = if (collapsed) " […]" else "";
    if (moved) |m| {
        return std.fmt.allocPrint(arena, "{s}  ({s}, moved {d} → {d}){s}", .{
            name, decl.ts_kind, m.from_idx, m.to_idx, suffix,
        });
    }
    return std.fmt.allocPrint(arena, "{s}  ({s}){s}", .{ name, decl.ts_kind, suffix });
}

/// Split the given source slice by newlines and emit one StyledLine per line,
/// expanding tabs to 4 spaces. Empty trailing line (from a trailing '\n') is
/// omitted so we don't render a phantom row after each span.
///
/// `decl_list` is the SST list for the decl being dumped; its atoms are
/// walked and classified by `theme.classOf` to populate
/// `StyledLine.highlights` (syntax colouring). Atoms outside the emitted
/// lines' byte ranges simply get clipped away.
fn appendSourceLines(
    arena: std.mem.Allocator,
    out: *std.ArrayList(StyledLine),
    source: []const u8,
    decl_list: *const rv.List,
    language: rv.LanguageId,
    indent: u8,
    marker: Marker,
) !void {
    const lines = try sourceLinesSlice(arena, source, decl_list, language, indent, marker);
    try out.appendSlice(arena, lines);
}

fn sourceLinesSlice(
    arena: std.mem.Allocator,
    source: []const u8,
    decl_list: *const rv.List,
    language: rv.LanguageId,
    indent: u8,
    marker: Marker,
) ![]const StyledLine {
    var buf: std.ArrayList(StyledLine) = .empty;
    const start: u32 = decl_list.byte_range.start;
    const end: u32 = decl_list.byte_range.end;
    const slice = source[start..end];

    // Collect syntax highlights once for the whole decl; per-line mapping
    // is a cheap clipping pass (same shape as `mapNovelsToLine`).
    const highlights = try collectHighlights(arena, decl_list, language);

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
        const line_highlights = try mapHighlightsToLine(arena, raw_line, line_abs_start, highlights);

        try buf.append(arena, .{
            .indent = indent,
            .marker = marker,
            .kind = .source,
            .text = expanded,
            .highlights = line_highlights,
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

/// Walk a decl's SST list and produce absolute-byte `HighlightSpan`s for
/// every atom (including leading/trailing trivia comments). Output is in
/// source order. Unclassifiable atoms still emit a span with `.other` so
/// the theme's `.other` policy (= keep base style) runs uniformly.
pub fn collectHighlights(
    arena: std.mem.Allocator,
    list: *const rv.List,
    language: rv.LanguageId,
) ![]const HighlightSpan {
    var out: std.ArrayList(HighlightSpan) = .empty;
    try walkAtomsForHighlights(arena, &out, .{ .list = list.* }, language);
    return try out.toOwnedSlice(arena);
}

fn walkAtomsForHighlights(
    arena: std.mem.Allocator,
    out: *std.ArrayList(HighlightSpan),
    n: rv.Node,
    language: rv.LanguageId,
) !void {
    switch (n) {
        .atom => |a| try appendAtomHighlight(arena, out, a, language),
        .list => |l| {
            for (l.leading_trivia) |t| try appendAtomHighlight(arena, out, t, language);
            for (l.children) |c| try walkAtomsForHighlights(arena, out, c, language);
            for (l.trailing_trivia) |t| try appendAtomHighlight(arena, out, t, language);
        },
    }
}

fn appendAtomHighlight(
    arena: std.mem.Allocator,
    out: *std.ArrayList(HighlightSpan),
    atom: anytype,
    language: rv.LanguageId,
) !void {
    try out.append(arena, .{
        .start = atom.byte_range.start,
        .end = atom.byte_range.end,
        .class = theme.classOf(language, atom.kind, atom.bytes),
    });
}

/// Per-line clipping for highlights. Mirrors `mapNovelsToLine`: drops
/// spans outside the line, clips any that straddle the line end, and
/// translates raw offsets into post-tab-expansion display offsets. Keeps
/// the `class` unchanged.
pub fn mapHighlightsToLine(
    arena: std.mem.Allocator,
    raw_line: []const u8,
    line_abs_start: u32,
    highlights: Highlights,
) ![]const HighlightSpan {
    if (highlights.len == 0) return &.{};

    const line_abs_end: u32 = line_abs_start + @as(u32, @intCast(raw_line.len));

    var out: std.ArrayList(HighlightSpan) = .empty;
    for (highlights) |h| {
        if (h.end <= line_abs_start) continue;
        if (h.start >= line_abs_end) continue;

        const clip_start_abs = @max(h.start, line_abs_start);
        const clip_end_abs = @min(h.end, line_abs_end);

        const raw_start: usize = clip_start_abs - line_abs_start;
        const raw_end: usize = clip_end_abs - line_abs_start;

        const disp_start: u32 = @intCast(rawToDisplay(raw_line, raw_start));
        const disp_end: u32 = @intCast(rawToDisplay(raw_line, raw_end));

        if (disp_end > disp_start) {
            try out.append(arena, .{
                .start = disp_start,
                .end = disp_end,
                .class = h.class,
            });
        }
    }

    std.mem.sort(HighlightSpan, out.items, {}, highlightLessThan);
    return try out.toOwnedSlice(arena);
}

fn highlightLessThan(_: void, a: HighlightSpan, b: HighlightSpan) bool {
    return a.start < b.start;
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

pub fn expandTabs(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
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

/// Most tests below don't care about collapse state; they want the fully-
/// expanded view. This helper builds with an empty `AppState` and hides
/// the plumbing from the test body.
fn buildForTest(
    gpa: std.mem.Allocator,
    file_diff: *const rv.FileDiff,
    mode: Mode,
) !BuildResult {
    var state = AppState.init(gpa);
    defer state.deinit();
    return build(gpa, file_diff, mode, &state);
}

test "build: identical Zig sources → one unchanged header per decl, no source lines" {
    const src =
        \\pub fn a() void {}
        \\pub fn b() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    for (result.view.unified) |ln| try testing.expect(ln.kind != .source);
}

test "build: decl header includes moved info when present" {
    const before = "pub fn a() void {}\npub fn b() void {}\n";
    const after = "pub fn b() void {}\npub fn a() void {}\n";
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
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

    var result = try buildForTest(testing.allocator, &fd, .split);
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

    var result = try buildForTest(testing.allocator, &fd, .split);
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

    var result = try buildForTest(testing.allocator, &fd, .split);
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

    var result = try buildForTest(testing.allocator, &fd, .split);
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

    var result = try buildForTest(testing.allocator, &fd, .split);
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const removed_highlight = try collectHighlightedText(a, result.view.unified, .removed);
    const added_highlight = try collectHighlightedText(a, result.view.unified, .added);

    try testing.expectEqualStrings("1", removed_highlight);
    try testing.expectEqualStrings("42", added_highlight);
}

test "build: body_change fixture renders hunk with context lines shown once (Option B)" {
    // Acceptance case for the linewise-LCS task: the surrounding lines
    // (function signature and closing brace) show once as `.context`, only
    // the differing middle line gets a `-` / `+` pair.
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    const lines = result.view.unified;
    // Expected: changed header, context, removed, added, context.
    try testing.expectEqual(@as(usize, 5), lines.len);

    try testing.expectEqual(Marker.changed, lines[0].marker);
    try testing.expectEqual(LineKind.decl_header, lines[0].kind);

    try testing.expectEqual(Marker.context, lines[1].marker);
    try testing.expectEqual(LineKind.source, lines[1].kind);
    try testing.expect(std.mem.indexOf(u8, lines[1].text, "pub fn greet() u32 {") != null);

    try testing.expectEqual(Marker.removed, lines[2].marker);
    try testing.expect(std.mem.indexOf(u8, lines[2].text, "return 1;") != null);

    try testing.expectEqual(Marker.added, lines[3].marker);
    try testing.expect(std.mem.indexOf(u8, lines[3].text, "return 42;") != null);

    try testing.expectEqual(Marker.context, lines[4].marker);
    try testing.expect(std.mem.indexOf(u8, lines[4].text, "}") != null);

    // Context lines carry no novel spans by construction.
    try testing.expectEqual(@as(usize, 0), lines[1].novel_spans.len);
    try testing.expectEqual(@as(usize, 0), lines[4].novel_spans.len);
}

test "build: context marker uses a blank gutter (git-style)" {
    try testing.expectEqualStrings(" ", Marker.context.gutter());
}

test "build: novel_spans respect tab expansion (display offsets, not raw)" {
    // Leading `\t` on the return line shifts every raw offset by
    // `tab_width - 1`. The novel span must land on the expanded position.
    const before = "pub fn greet() u32 {\n\treturn 1;\n}\n";
    const after = "pub fn greet() u32 {\n\treturn 2;\n}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
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

    var result = try buildForTest(testing.allocator, &fd, .split);
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

// ── collapse/expand ─────────────────────────────────────────────────────

/// Find the first (and typically only) `.changed` entry at the top level.
fn firstChanged(entries: []const rv.DeclDiff) rv.Decl {
    for (entries) |e| if (e == .changed) return e.changed.new;
    unreachable;
}

test "build: collapsed changed leaf hides body and appends '[…]' to header" {
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();
    _ = try state.toggle(declId(firstChanged(fd.entries)));

    var result = try build(testing.allocator, &fd, .unified, &state);
    defer result.deinit();

    // No source lines — the leaf's body is suppressed.
    for (result.view.unified) |ln| try testing.expect(ln.kind != .source);

    // Header has the `[…]` suffix.
    try testing.expectEqual(@as(usize, 1), result.view.unified.len);
    try testing.expect(std.mem.endsWith(u8, result.view.unified[0].text, " [\u{2026}]"));
}

test "build: collapsed container hides children and appends '[…]' to header" {
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

    var state = AppState.init(testing.allocator);
    defer state.deinit();
    _ = try state.toggle(declId(firstChanged(fd.entries)));

    var result = try build(testing.allocator, &fd, .unified, &state);
    defer result.deinit();

    // Only the container header is emitted — children don't appear.
    try testing.expectEqual(@as(usize, 1), result.view.unified.len);
    try testing.expectEqual(LineKind.decl_header, result.view.unified[0].kind);
    try testing.expect(std.mem.endsWith(u8, result.view.unified[0].text, " [\u{2026}]"));
}

test "build: collapsed added decl hides its source dump" {
    const before = "pub fn a() void {}\n";
    const after = "pub fn a() void {}\npub fn b() void {\n    return;\n}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();
    for (fd.entries) |e| if (e == .added) {
        _ = try state.toggle(declId(e.added.decl));
    };

    var result = try build(testing.allocator, &fd, .unified, &state);
    defer result.deinit();

    var saw_added_header = false;
    for (result.view.unified) |ln| {
        try testing.expect(!(ln.marker == .added and ln.kind == .source));
        if (ln.marker == .added and ln.kind == .decl_header) {
            try testing.expect(std.mem.endsWith(u8, ln.text, " [\u{2026}]"));
            saw_added_header = true;
        }
    }
    try testing.expect(saw_added_header);
}

test "build: collapsed removed decl hides its source dump" {
    const before = "pub fn a() void {}\npub fn gone() void { return; }\n";
    const after = "pub fn a() void {}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();
    for (fd.entries) |e| if (e == .removed) {
        _ = try state.toggle(declId(e.removed.decl));
    };

    var result = try build(testing.allocator, &fd, .unified, &state);
    defer result.deinit();

    for (result.view.unified) |ln| {
        try testing.expect(!(ln.marker == .removed and ln.kind == .source));
    }
}

test "build split: collapsed changed leaf hides body on both panes" {
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();
    _ = try state.toggle(declId(firstChanged(fd.entries)));

    var result = try build(testing.allocator, &fd, .split, &state);
    defer result.deinit();

    // Only the changed header pair survives.
    try testing.expectEqual(@as(usize, 1), result.view.split.len);
    const pair = result.view.split[0];
    try testing.expectEqual(LineKind.decl_header, pair.left.kind);
    try testing.expectEqual(LineKind.decl_header, pair.right.kind);
    try testing.expect(std.mem.endsWith(u8, pair.left.text, " [\u{2026}]"));
    try testing.expect(std.mem.endsWith(u8, pair.right.text, " [\u{2026}]"));
}

test "build: decl_header lines carry a decl_id; source/blank lines do not" {
    const before = "pub fn a() u32 { return 1; }\n";
    const after = "pub fn a() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var header_count: usize = 0;
    for (result.view.unified) |ln| switch (ln.kind) {
        .decl_header => {
            try testing.expect(ln.decl_id != null);
            header_count += 1;
        },
        .source, .blank => try testing.expectEqual(
            @as(?DeclId, null),
            ln.decl_id,
        ),
        // Decl-axis builder never emits these; they are exclusive to
        // `file_view.zig`.
        .decl_anchor, .elided => unreachable,
    };
    try testing.expect(header_count >= 1);
}

// ── syntax highlighting (Option 1 — tree-sitter queries task) ───────────

/// Collect the text of every highlighted token on `-` / `+` / ` ` source
/// lines whose class is `want`. Return values are concatenated in source
/// order. This is the most direct way to assert "keyword X shows up as a
/// keyword" without coupling to exact byte offsets.
fn collectHighlightedByClass(
    arena: std.mem.Allocator,
    lines: []const StyledLine,
    want: TokenClass,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lines) |ln| {
        if (ln.kind != .source) continue;
        for (ln.highlights) |h| {
            if (h.class != want) continue;
            try out.append(arena, ln.text[h.start..h.end]);
        }
    }
    return try out.toOwnedSlice(arena);
}

fn sliceContainsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

test "highlights: Rust added fn — `fn`, `pub`, `let` classified as keywords; strings distinct" {
    // Acceptance case from the task description.
    const before = "pub fn keep() {}\n";
    const after =
        \\pub fn keep() {}
        \\pub fn greet(name: &str) -> String {
        \\    let prefix = "hello, ";
        \\    let mut out = String::from(prefix);
        \\    out.push_str(name);
        \\    out
        \\}
    ;

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const keywords = try collectHighlightedByClass(a, result.view.unified, .keyword);
    try testing.expect(sliceContainsString(keywords, "fn"));
    try testing.expect(sliceContainsString(keywords, "pub"));
    try testing.expect(sliceContainsString(keywords, "let"));

    const strings = try collectHighlightedByClass(a, result.view.unified, .string);
    try testing.expect(sliceContainsString(strings, "\"hello, \""));

    const types = try collectHighlightedByClass(a, result.view.unified, .type);
    try testing.expect(sliceContainsString(types, "String"));
    // `str` is a Rust primitive.
    try testing.expect(sliceContainsString(types, "str"));
}

test "highlights: added decl body lines carry highlight spans" {
    // Added decls emit source lines; verify their highlights populate.
    // (Unchanged decls don't emit source lines today, so there's nothing
    // to highlight on them.)
    const before = "pub fn a() {}\n";
    const after = "pub fn a() {}\npub fn b() -> u32 { 42 }\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var saw_number_highlight = false;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        for (ln.highlights) |h| {
            if (h.class == .number and std.mem.eql(u8, ln.text[h.start..h.end], "42")) {
                saw_number_highlight = true;
            }
        }
    }
    try testing.expect(saw_number_highlight);
}

test "highlights: decl headers and blanks carry no highlights" {
    const before = "pub fn a() -> u32 { 1 }\n";
    const after = "pub fn a() -> u32 { 2 }\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    for (result.view.unified) |ln| switch (ln.kind) {
        .decl_header, .blank => try testing.expectEqual(@as(usize, 0), ln.highlights.len),
        .source => {},
        // Decl-axis builder never emits these; they are exclusive to
        // `file_view.zig`.
        .decl_anchor, .elided => unreachable,
    };
}

test "highlights: offsets are in display coordinates (tab expansion respected)" {
    // Leading `\t` shifts raw offsets by `tab_width - 1`. Highlight offsets
    // on the emitted line must land on the expanded positions so the
    // renderer draws them at the right cells.
    const before = "pub fn a() -> u32 { 1 }\n";
    const after = "pub fn a() -> u32 {\n\tlet x = 99;\n\tx\n}\n";

    var fd = try rv.diffSources(testing.allocator, .rust, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var hit: ?StyledLine = null;
    for (result.view.unified) |ln| {
        if (ln.kind != .source) continue;
        if (std.mem.indexOf(u8, ln.text, "let") == null) continue;
        hit = ln;
        break;
    }
    try testing.expect(hit != null);
    const ln = hit.?;
    try testing.expect(std.mem.startsWith(u8, ln.text, "    let "));

    // `let` is the keyword we expect to tint, starting at column 4 (after
    // the expanded tab).
    var found_let_at_4 = false;
    for (ln.highlights) |h| {
        if (h.class != .keyword) continue;
        if (!std.mem.eql(u8, ln.text[h.start..h.end], "let")) continue;
        try testing.expectEqual(@as(u32, 4), h.start);
        try testing.expectEqual(@as(u32, 7), h.end);
        found_let_at_4 = true;
    }
    try testing.expect(found_let_at_4);
}

test "highlights: Zig changed leaf classifies `const` and `return` as keywords" {
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 {\n    const x: u32 = 2;\n    return x;\n}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const keywords = try collectHighlightedByClass(a, result.view.unified, .keyword);
    try testing.expect(sliceContainsString(keywords, "const"));
    try testing.expect(sliceContainsString(keywords, "return"));
    try testing.expect(sliceContainsString(keywords, "pub"));
    try testing.expect(sliceContainsString(keywords, "fn"));

    const types = try collectHighlightedByClass(a, result.view.unified, .type);
    try testing.expect(sliceContainsString(types, "u32"));
}

test "highlights: split mode populates highlights on both panes" {
    const before = "pub fn greet() u32 { return 1; }\n";
    const after = "pub fn greet() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .split);
    defer result.deinit();

    var left_has_keyword = false;
    var right_has_keyword = false;
    for (result.view.split) |p| {
        if (p.left.kind == .source) {
            for (p.left.highlights) |h| if (h.class == .keyword) {
                left_has_keyword = true;
            };
        }
        if (p.right.kind == .source) {
            for (p.right.highlights) |h| if (h.class == .keyword) {
                right_has_keyword = true;
            };
        }
    }
    try testing.expect(left_has_keyword);
    try testing.expect(right_has_keyword);
}

test "mapHighlightsToLine: drops spans outside the line, clips at line end" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const raw = "hello world"; // 11 bytes at abs [100, 111)
    const highlights = [_]HighlightSpan{
        .{ .start = 50, .end = 60, .class = .keyword }, // before
        .{ .start = 102, .end = 107, .class = .ident }, // "llo w" inside
        .{ .start = 108, .end = 200, .class = .number }, // clip at 111
        .{ .start = 500, .end = 600, .class = .keyword }, // after
    };
    const got = try mapHighlightsToLine(a, raw, 100, &highlights);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(u32, 2), got[0].start);
    try testing.expectEqual(@as(u32, 7), got[0].end);
    try testing.expectEqual(TokenClass.ident, got[0].class);
    try testing.expectEqual(@as(u32, 8), got[1].start);
    try testing.expectEqual(@as(u32, 11), got[1].end);
    try testing.expectEqual(TokenClass.number, got[1].class);
}

// ── decl_index ───────────────────────────────────────────────────────────────────

test "build: decl_index lists every header row with a `changed` flag" {
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

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    // Three decl headers total: unchanged `keep`, changed `tweak`, added
    // `added`.
    try testing.expectEqual(@as(usize, 3), result.decl_index.len);

    // Every index entry actually points at a decl_header row.
    for (result.decl_index) |e| {
        try testing.expectEqual(LineKind.decl_header, result.view.unified[e.row].kind);
    }

    // Changed flags line up with the header markers.
    var changed_count: usize = 0;
    var unchanged_count: usize = 0;
    for (result.decl_index) |e| {
        const marker = result.view.unified[e.row].marker;
        if (e.changed) {
            try testing.expect(marker == .added or marker == .removed or marker == .changed);
            changed_count += 1;
        } else {
            try testing.expectEqual(Marker.unchanged, marker);
            unchanged_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), changed_count); // tweak + added
    try testing.expectEqual(@as(usize, 1), unchanged_count); // keep
}

test "build split: decl_index covers both mirrored and single-sided headers" {
    const before = "pub fn a() void {}\npub fn gone() void { return; }\n";
    const after = "pub fn a() void {}\npub fn fresh() void { return; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .split);
    defer result.deinit();

    // Three decls (unchanged a, removed gone, added fresh) → three entries.
    try testing.expectEqual(@as(usize, 3), result.decl_index.len);

    // Each entry's row resolves to a pair with a decl_header on at least
    // one side; `changed` matches whichever side holds the header.
    for (result.decl_index) |e| {
        const side = result.view.split[e.row].headerSide() orelse unreachable;
        const expect_changed = side.marker == .added or
            side.marker == .removed or
            side.marker == .changed;
        try testing.expectEqual(expect_changed, e.changed);
    }
}

test "build: decl_index row order is strictly ascending" {
    const before =
        \\pub fn a() void {}
        \\pub const Thing = struct {
        \\    pub fn one() void {}
        \\};
    ;
    const after =
        \\pub fn a() u32 { return 1; }
        \\pub const Thing = struct {
        \\    pub fn one() u32 { return 1; }
        \\    pub fn two() void {}
        \\};
    ;

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var result = try buildForTest(testing.allocator, &fd, .unified);
    defer result.deinit();

    try testing.expect(result.decl_index.len > 1);
    var prev: usize = 0;
    for (result.decl_index, 0..) |e, i| {
        if (i > 0) try testing.expect(e.row > prev);
        prev = e.row;
    }
}

// ── buildImportGroupLine ────────────────────────────────────────────────

fn buildImportGroupLineForTest(
    arena: std.mem.Allocator,
    group: rv.ImportGroupDiff,
) !StyledLine {
    return buildImportGroupLine(arena, group, 0);
}

fn findHighlight(line: StyledLine, want: []const u8) ?HighlightSpan {
    for (line.highlights) |h| {
        if (std.mem.eql(u8, line.text[h.start..h.end], want)) return h;
    }
    return null;
}

test "buildImportGroupLine: brace form when an addition mixes with kept symbols" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]rv.ImportSymbolEntry{
        .{ .added = .{ .text = "Deserialize" } },
        .{ .kept = .{ .text = "Serialize" } },
    };
    const line = try buildImportGroupLineForTest(a, .{ .prefix = "serde", .entries = &entries });

    try testing.expectEqualStrings("use serde::{Deserialize, Serialize};", line.text);
    try testing.expectEqual(Marker.changed, line.marker);
    try testing.expectEqual(LineKind.source, line.kind);

    const added = findHighlight(line, "Deserialize") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.import_symbol_added, added.class);

    const kept = findHighlight(line, "Serialize") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.ident, kept.class);
}

test "buildImportGroupLine: removed-only entries surface as a trailing suffix" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]rv.ImportSymbolEntry{
        .{ .kept = .{ .text = "a" } },
        .{ .removed = .{ .text = "b" } },
        .{ .kept = .{ .text = "c" } },
    };
    const line = try buildImportGroupLineForTest(a, .{ .prefix = "foo", .entries = &entries });

    try testing.expectEqualStrings("use foo::{a, c}; removed: b", line.text);
    const removed = findHighlight(line, "b") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.import_symbol_removed, removed.class);
    const label = findHighlight(line, "removed:") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.comment, label.class);
}

test "buildImportGroupLine: add and remove combined" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]rv.ImportSymbolEntry{
        .{ .kept = .{ .text = "a" } },
        .{ .removed = .{ .text = "b" } },
        .{ .added = .{ .text = "c" } },
    };
    const line = try buildImportGroupLineForTest(a, .{ .prefix = "foo", .entries = &entries });

    try testing.expectEqualStrings("use foo::{a, c}; removed: b", line.text);
    const c_span = findHighlight(line, "c") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.import_symbol_added, c_span.class);
    const b_span = findHighlight(line, "b") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.import_symbol_removed, b_span.class);
}

test "buildImportGroupLine: single kept symbol uses single-symbol form" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]rv.ImportSymbolEntry{
        .{ .kept = .{ .text = "Bar" } },
    };
    const line = try buildImportGroupLineForTest(a, .{ .prefix = "foo", .entries = &entries });

    try testing.expectEqualStrings("use foo::Bar;", line.text);
}

test "buildImportGroupLine: single added symbol uses single-symbol form" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]rv.ImportSymbolEntry{
        .{ .added = .{ .text = "Bar" } },
    };
    const line = try buildImportGroupLineForTest(a, .{ .prefix = "foo", .entries = &entries });

    try testing.expectEqualStrings("use foo::Bar;", line.text);
    const span = findHighlight(line, "Bar") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.import_symbol_added, span.class);
}

test "buildImportGroupLine: all-removed degenerate case yields empty brace and full suffix" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]rv.ImportSymbolEntry{
        .{ .removed = .{ .text = "a" } },
        .{ .removed = .{ .text = "b" } },
    };
    const line = try buildImportGroupLineForTest(a, .{ .prefix = "foo", .entries = &entries });

    try testing.expectEqualStrings("use foo::{}; removed: a, b", line.text);
}

test "buildImportGroupLine: aliases are kept verbatim and tagged correctly" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]rv.ImportSymbolEntry{
        .{ .kept = .{ .text = "Bar as Baz" } },
        .{ .added = .{ .text = "Qux" } },
    };
    const line = try buildImportGroupLineForTest(a, .{ .prefix = "foo", .entries = &entries });

    try testing.expectEqualStrings("use foo::{Bar as Baz, Qux};", line.text);
    const qux = findHighlight(line, "Qux") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.import_symbol_added, qux.class);
    const aliased = findHighlight(line, "Bar as Baz") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.ident, aliased.class);
}

test "buildImportGroupLine: self symbol is just another entry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]rv.ImportSymbolEntry{
        .{ .added = .{ .text = "self" } },
        .{ .kept = .{ .text = "Bar" } },
    };
    const line = try buildImportGroupLineForTest(a, .{ .prefix = "foo", .entries = &entries });

    try testing.expectEqualStrings("use foo::{self, Bar};", line.text);
    const self_span = findHighlight(line, "self") orelse return error.MissingHighlight;
    try testing.expectEqual(TokenClass.import_symbol_added, self_span.class);
}

//! Vaxis-backed event loop and renderer for the diff view.
//!
//! The pure line-building logic is in `line.zig`; this module is responsible
//! for:
//!
//! - Setting up Tty + Vaxis + Loop
//! - UI state (`AppState`): scroll offset, cursor row, collapsed decl set
//! - Key handling: j/k/arrows move the cursor (scroll follows), PgUp/PgDn
//!   page the cursor, Home/End jump to ends, space/enter toggles collapse
//!   on the focused decl, `[` collapses every decl with a body, `]`
//!   expands everything, `v` toggles split vs unified,
//!   `n`/`p` jumps to the next/previous decl header (any kind),
//!   `N`/`P` jumps between *changed* decls (skipping unchanged ones),
//!   `g`/`G` jumps to the first/last decl, q / Ctrl-C quit.
//!   `n`/`p`/`N`/`P` wrap around the file; all decl jumps center the
//!   target in the top third of the viewport so the decl body stays
//!   visible below.
//! - Mouse handling: wheel scroll + click-to-focus. Terminals without
//!   mouse support simply never deliver mouse events, so keyboard
//!   navigation stays intact. Drag-select is deferred because our mouse
//!   handling conflicts with the terminal's own selection; users who
//!   want to copy text can hold Shift while clicking/dragging to bypass
//!   vaxis and use the terminal's native selection.
//! - Drawing the header strip and visible lines each frame in either the
//!   unified or side-by-side layout. The focused row's gutter is replaced
//!   by `>` to show where collapse toggles will land.

const std = @import("std");
const vaxis = @import("vaxis");

const rv = @import("rv");
const file_view_mod = @import("file_view.zig");
const line_mod = @import("line.zig");
const summary = @import("summary.zig");
const theme = @import("theme.zig");

const Allocator = std.mem.Allocator;

const StyledLine = line_mod.StyledLine;
const LinePair = line_mod.LinePair;
const Marker = line_mod.Marker;
const LineKind = line_mod.LineKind;
const Mode = line_mod.Mode;
const View = line_mod.View;
const BuildResult = line_mod.BuildResult;
const DeclIndexEntry = line_mod.DeclIndexEntry;
const AppState = line_mod.AppState;
const DeclId = line_mod.DeclId;
const GapId = line_mod.GapId;

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
};

/// Rectangle inside the root window where `drawDiffPane` paints. Offsets
/// are window-relative; width/height span the full pane including the
/// `header_rows`-tall header strip reserved at the top.
pub const PaneSize = struct {
    x_off: u16,
    y_off: u16,
    width: u16,
    height: u16,
};

/// Optional header to render in the top rows of the pane. Null means the
/// caller owns the header area (e.g. the session draws its own).
pub const DiffHeader = struct {
    title: []const u8,
    stats: []const u8,
};

/// Pluggable line builder. Both `line.build` and `file_view.build`
/// satisfy this signature, so callers (path mode in `app.run`, repo
/// mode in `session.zig`) can pick the right axis without `app.zig`
/// taking a dependency on the higher-level pane classification.
pub const BuildFn = *const fn (
    gpa: Allocator,
    file_diff: *const rv.FileDiff,
    mode: line_mod.Mode,
    state: *const AppState,
) anyerror!BuildResult;

/// Run the diff UI to completion. Returns when the user quits.
///
/// `before_path` and `after_path` are shown in the header; they are not
/// re-read. `file_diff` is borrowed.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    file_diff: *const rv.FileDiff,
    before_path: []const u8,
    after_path: []const u8,
) !void {
    var state = AppState.init(gpa);
    defer state.deinit();

    // Header labels (title + stats) outlive any single view rebuild, so they
    // live in a dedicated arena. Vaxis cells store grapheme bytes by
    // *reference*, so these slices must stay alive until the last render.
    var label_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer label_arena_state.deinit();
    const la = label_arena_state.allocator();

    const pe_label: []const u8 = if (file_diff.parse_errors.len > 0) "  [parse errors]" else "";
    const title = try std.fmt.allocPrint(la, "rv  {s}  →  {s}{s}", .{
        before_path, after_path, pe_label,
    });

    var mode: Mode = .unified;
    // Path mode always treats the two arbitrary files as a single
    // "modified" comparison, so we use the file-wide builder unconditionally.
    // The same builder is reused on every rebuild via `handleDiffPaneKey`.
    const build_fn: BuildFn = &file_view_mod.build;
    var current = try build_fn(gpa, file_diff, mode, &state);
    defer current.deinit();

    // Stats are a property of the underlying FileDiff, not of the collapse
    // state or mode, so we format the legend exactly once.
    const stats_text = try summary.formatModifiedHeader(la, file_diff.entries);

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, env_map, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    // `setMouseMode` inspects `vx.caps.sgr_pixels` (populated by
    // `queryTerminal`) and picks pixel-precision reporting when available,
    // falling back to cell-precision otherwise.
    try vx.setMouseMode(tty.writer(), true);

    while (true) {
        const event = try loop.nextEvent();
        const viewport = viewportHeight(vx.window());
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) break;
                if (key.matches('q', .{})) break;
                try handleDiffPaneKey(gpa, key, &current, file_diff, &state, &mode, viewport, build_fn);
            },
            .mouse => |m| handleDiffPaneMouse(&state, m, viewport, current.rowCount()),
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
        }

        const win = vx.window();
        win.clear();
        const pane: PaneSize = .{
            .x_off = 0,
            .y_off = 0,
            .width = win.width,
            .height = win.height,
        };
        switch (mode) {
            .unified => drawDiffPane(
                win,
                pane,
                current,
                &state,
                mode,
                true,
                .{ .title = title, .stats = stats_text },
            ),
            .split => {
                // Split mode keeps the legacy two-pane header (`before_path`
                // on the left, `after_path` on the right) because a single
                // `DiffHeader.title` can't represent that layout. The session
                // UI draws its own header either way, so `drawDiffPane`
                // doesn't need to know about this case.
                drawSplitLegacyHeader(win, pane, before_path, after_path, stats_text);
                drawDiffPane(win, pane, current, &state, mode, true, null);
            },
        }

        try vx.render(tty.writer());
        try tty.writer().flush();
    }
}

// ── extracted pane API ────────────────────────────────────────────────────

/// Paint the diff pane (optional header + body) into a sub-rectangle of `win`.
///
/// `size` gives the pane rectangle including the `header_rows`-tall header
/// strip at the top. When `header` is non-null `drawDiffPane` paints
/// `title` / `stats` into those rows; when null the caller owns them
/// (e.g. the repo session paints a per-file label there). Body rendering
/// starts at `size.y_off + header_rows` either way, so split-mode's
/// separator lines up across header and body.
///
/// `focused` toggles the cursor marker: when false the `>` highlight is
/// suppressed so a background pane reads as non-interactive while another
/// pane (e.g. the sidebar) holds focus.
pub fn drawDiffPane(
    win: vaxis.Window,
    size: PaneSize,
    built: BuildResult,
    state: *const AppState,
    mode: Mode,
    focused: bool,
    header: ?DiffHeader,
) void {
    const pane = win.child(.{
        .x_off = size.x_off,
        .y_off = size.y_off,
        .width = size.width,
        .height = size.height,
    });
    if (header) |h| drawHeader(pane, h.title, h.stats);
    switch (mode) {
        .unified => drawUnifiedBody(pane, built, state, focused),
        .split => drawSplitBody(pane, built, state, focused),
    }
}

/// Apply one keypress to the diff-pane state. Same key set as `run`'s
/// original switch minus the quit keys (`q`, ctrl-c), which stay in the
/// caller so the session can decide whether quit exits the app or just
/// closes the pane.
///
/// On fold / mode / collapse-all / expand-all keys this rebuilds `built`
/// in place and re-anchors the cursor against the new view.
pub fn handleDiffPaneKey(
    gpa: Allocator,
    key: vaxis.Key,
    built: *BuildResult,
    file_diff: *const rv.FileDiff,
    state: *AppState,
    mode: *Mode,
    viewport: u16,
    build_fn: BuildFn,
) !void {
    if (key.matches('v', .{})) {
        const anchor = focusedDeclId(built.view, state.cursor_y);
        mode.* = if (mode.* == .unified) .split else .unified;
        try rebuild(gpa, built, file_diff, mode.*, state, build_fn);
        relocateCursor(state, built.view, anchor, viewport);
    } else if (key.matches(vaxis.Key.space, .{}) or key.matches(vaxis.Key.enter, .{})) {
        // Elided rows expand/collapse via the gap-id channel; everything
        // else falls through to the existing decl collapse-toggle path.
        if (focusedRowKind(built.view, state.cursor_y) == .elided) {
            try toggleFocusedGap(gpa, built, file_diff, state, mode.*, viewport, build_fn);
        } else if (focusedDeclId(built.view, state.cursor_y)) |id| {
            _ = try state.toggle(id);
            try rebuild(gpa, built, file_diff, mode.*, state, build_fn);
            relocateCursor(state, built.view, id, viewport);
        }
    } else if (key.matches('[', .{})) {
        const anchor = focusedDeclId(built.view, state.cursor_y);
        try state.collapseAll(file_diff);
        state.collapseAllGaps();
        try rebuild(gpa, built, file_diff, mode.*, state, build_fn);
        relocateCursor(state, built.view, anchor, viewport);
    } else if (key.matches(']', .{})) {
        const anchor = focusedDeclId(built.view, state.cursor_y);
        state.expandAll();
        try state.expandAllGaps(built.view);
        try rebuild(gpa, built, file_diff, mode.*, state, build_fn);
        relocateCursor(state, built.view, anchor, viewport);
    } else if (key.matches('n', .{})) {
        jumpDecl(state, built.decl_index, .forward, false, viewport, built.rowCount());
    } else if (key.matches('p', .{})) {
        jumpDecl(state, built.decl_index, .backward, false, viewport, built.rowCount());
    } else if (key.matches('N', .{})) {
        jumpDecl(state, built.decl_index, .forward, true, viewport, built.rowCount());
    } else if (key.matches('P', .{})) {
        jumpDecl(state, built.decl_index, .backward, true, viewport, built.rowCount());
    } else if (key.matches('g', .{})) {
        jumpToEnd(state, built.decl_index, .first, viewport, built.rowCount());
    } else if (key.matches('G', .{})) {
        jumpToEnd(state, built.decl_index, .last, viewport, built.rowCount());
    } else {
        applyNavigationKey(state, key, viewport, built.rowCount());
    }
}

/// Pure mouse handler for the diff pane. The caller is responsible for
/// only passing mouse events whose `row` / `col` fall inside the pane
/// rectangle; offsets are interpreted relative to the pane's header strip.
pub fn handleDiffPaneMouse(
    state: *AppState,
    mouse: vaxis.Mouse,
    viewport: u16,
    total: usize,
) void {
    applyMouse(state, mouse, viewport, total);
}

fn rebuild(
    gpa: std.mem.Allocator,
    current: *BuildResult,
    file_diff: *const rv.FileDiff,
    mode: Mode,
    state: *const AppState,
    build_fn: BuildFn,
) !void {
    // Build the replacement *before* freeing the old one so a mid-build
    // failure leaves `current` intact and the `defer current.deinit()` in
    // `run` still frees something valid.
    var next = try build_fn(gpa, file_diff, mode, state);
    current.deinit();
    current.* = next;
    next = undefined;
}

// ── layout constants ──────────────────────────────────────────────────────

const header_rows: u16 = 2; // path line + stats line

fn viewportHeight(win: vaxis.Window) u16 {
    return bodyHeight(win.height);
}

/// Body height for a pane whose total height is `pane_height`. The top
/// `header_rows` rows are reserved for the header strip (whether or not
/// the caller actually draws into them), so any pane shorter than that
/// has zero body rows.
fn bodyHeight(pane_height: u16) u16 {
    return if (pane_height > header_rows) pane_height - header_rows else 0;
}

// ── cursor-driven navigation ──────────────────────────────────────────────

/// Mutate `state.cursor_y` / `state.scroll_y` in response to a movement
/// key. Unknown keys leave state alone. Scroll follows the cursor: we move
/// `scroll_y` just enough to keep the cursor inside the viewport.
fn applyNavigationKey(
    state: *AppState,
    key: vaxis.Key,
    viewport: u16,
    total: usize,
) void {
    if (total == 0) {
        state.scroll_y = 0;
        state.cursor_y = 0;
        return;
    }
    const last: usize = total - 1;

    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        state.cursor_y -|= 1;
    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        state.cursor_y = @min(state.cursor_y + 1, last);
    } else if (key.matches(vaxis.Key.page_up, .{})) {
        state.cursor_y -|= viewport;
    } else if (key.matches(vaxis.Key.page_down, .{})) {
        state.cursor_y = @min(state.cursor_y +| viewport, last);
    } else if (key.matches(vaxis.Key.home, .{})) {
        state.cursor_y = 0;
    } else if (key.matches(vaxis.Key.end, .{})) {
        state.cursor_y = last;
    } else {
        return; // unknown key; leave scroll/cursor alone
    }

    followCursor(state, viewport, total);
}

/// After a cursor move or rebuild, nudge `scroll_y` just enough to keep the
/// cursor within `[scroll_y, scroll_y + viewport)`, then clamp.
fn followCursor(state: *AppState, viewport: u16, total: usize) void {
    if (state.cursor_y < state.scroll_y) {
        state.scroll_y = state.cursor_y;
    } else if (viewport > 0 and state.cursor_y >= state.scroll_y + viewport) {
        state.scroll_y = state.cursor_y - viewport + 1;
    }
    const max_scroll = if (total > viewport) total - viewport else 0;
    state.scroll_y = @min(state.scroll_y, max_scroll);
}

// ── mouse ──────────────────────────────────────────────────────────────────

/// Lines scrolled per wheel tick. Matches the typical terminal default and
/// keeps wheel scrolling distinguishable from arrow-key scrolling.
const wheel_step: usize = 3;

/// Pure mouse handler: wheel ticks move `scroll_y`, left-button presses
/// snap `cursor_y` onto the absolute row under the pointer. Clicks inside
/// the header strip, past the end of content, or outside the window are
/// ignored so a stray click never places the cursor on an empty row.
/// Split view is handled transparently: vertical offset is shared across
/// panes, and the absolute row is the same whether the click landed left
/// or right of the separator.
fn applyMouse(
    state: *AppState,
    m: vaxis.Mouse,
    viewport: u16,
    total: usize,
) void {
    if (total == 0) return;
    const max_scroll = if (total > viewport) total - viewport else 0;

    if (m.type == .press) switch (m.button) {
        .wheel_up => state.scroll_y -|= wheel_step,
        .wheel_down => state.scroll_y +|= wheel_step,
        .left => if (m.row >= 0) {
            const row_u: u16 = @intCast(m.row);
            if (row_u >= header_rows) {
                const in_body: usize = row_u - header_rows;
                const abs_row = state.scroll_y + in_body;
                if (abs_row < total) state.cursor_y = abs_row;
            }
        },
        else => {},
    };

    state.scroll_y = @min(state.scroll_y, max_scroll);
}

// ── focused decl / relocation ─────────────────────────────────────────────

/// Walk backward from `cursor_y` until we hit a decl header, and return its
/// `DeclId`. Lines above any header (or an empty view) map to `null`.
fn focusedDeclId(view: View, cursor_y: usize) ?DeclId {
    return switch (view) {
        .unified => |lines| focusedDeclIdLines(lines, cursor_y),
        .split => |pairs| focusedDeclIdPairs(pairs, cursor_y),
    };
}

fn focusedDeclIdLines(lines: []const StyledLine, cursor_y: usize) ?DeclId {
    if (lines.len == 0) return null;
    var i: usize = @min(cursor_y, lines.len - 1) + 1;
    while (i > 0) {
        i -= 1;
        if (!isDeclRepresentativeKind(lines[i])) continue;
        if (lines[i].decl_id) |id| return id;
    }
    return null;
}

fn focusedDeclIdPairs(pairs: []const LinePair, cursor_y: usize) ?DeclId {
    if (pairs.len == 0) return null;
    var i: usize = @min(cursor_y, pairs.len - 1) + 1;
    while (i > 0) {
        i -= 1;
        if (declRepresentativeSide(pairs[i])) |side| if (side.decl_id) |id| return id;
    }
    return null;
}

/// A row "represents" the enclosing decl when:
///
/// - It is a `.decl_header` (decl-axis builder) or `.decl_anchor`
///   (file-wide builder for collapsed decls), OR
/// - It is an annotated `.source` row (file-wide builder for expanded
///   decls, where the inline annotation replaces the dropped anchor
///   row).
///
/// Walking back from the cursor through rows that satisfy this predicate
/// lands on the same logical "decl landmark" regardless of which
/// builder produced the view.
fn isDeclRepresentativeKind(ln: StyledLine) bool {
    if (ln.kind == .decl_header or ln.kind == .decl_anchor) return true;
    if (ln.kind == .source and ln.decl_annotation != null) return true;
    return false;
}

/// Split-mode counterpart of `LinePair.headerSide` that matches every
/// representative-row kind. Picks the right side first so mirrored
/// representatives keep their existing right-side preference.
fn declRepresentativeSide(p: LinePair) ?StyledLine {
    if (isDeclRepresentativeKind(p.right)) return p.right;
    if (isDeclRepresentativeKind(p.left)) return p.left;
    return null;
}

fn findDeclRow(view: View, id: DeclId) ?usize {
    return switch (view) {
        .unified => |lines| blk: {
            for (lines, 0..) |ln, i| {
                if (!isDeclRepresentativeKind(ln)) continue;
                if (ln.decl_id) |did| if (did == id) break :blk i;
            }
            break :blk null;
        },
        .split => |pairs| blk: {
            for (pairs, 0..) |p, i| {
                const side = declRepresentativeSide(p) orelse continue;
                if (side.decl_id) |did| if (did == id) break :blk i;
            }
            break :blk null;
        },
    };
}

/// `LineKind` of the row currently under the cursor, or `null` when the
/// view is empty / the cursor sits past the end. In split mode an active
/// non-blank side wins so an `.added` anchor on the right still reads as
/// `.decl_anchor` even though its left filler has `.kind = .blank`.
fn focusedRowKind(view: View, cursor_y: usize) ?LineKind {
    return switch (view) {
        .unified => |lines| if (cursor_y < lines.len) lines[cursor_y].kind else null,
        .split => |pairs| if (cursor_y < pairs.len) blk: {
            const p = pairs[cursor_y];
            if (p.right.kind != .blank) break :blk p.right.kind;
            break :blk p.left.kind;
        } else null,
    };
}

/// `gap_id` of the row under the cursor when it is an `.elided` row, else
/// `null`. Split mode mirrors `.elided` rows on both sides; either side's
/// id is fine, but we prefer the right (post-image) for symmetry with
/// `focusedRowKind`.
fn focusedGapId(view: View, cursor_y: usize) ?GapId {
    return switch (view) {
        .unified => |lines| if (cursor_y < lines.len) lines[cursor_y].gap_id else null,
        .split => |pairs| if (cursor_y < pairs.len) blk: {
            const p = pairs[cursor_y];
            if (p.right.kind == .elided) break :blk p.right.gap_id;
            if (p.left.kind == .elided) break :blk p.left.gap_id;
            break :blk null;
        } else null,
    };
}

/// Find the row of the `.elided` row whose `gap_id` matches `id`, or
/// `null` if the gap is no longer collapsed (was just expanded).
fn findGapRow(view: View, id: GapId) ?usize {
    return switch (view) {
        .unified => |lines| blk: {
            for (lines, 0..) |ln, i| {
                if (ln.kind != .elided) continue;
                if (ln.gap_id) |gid| if (gid == id) break :blk i;
            }
            break :blk null;
        },
        .split => |pairs| blk: {
            for (pairs, 0..) |p, i| {
                if (p.right.kind == .elided) {
                    if (p.right.gap_id) |gid| if (gid == id) break :blk i;
                }
                if (p.left.kind == .elided) {
                    if (p.left.gap_id) |gid| if (gid == id) break :blk i;
                }
            }
            break :blk null;
        },
    };
}

/// Flip the focused gap's expansion state, rebuild the view, and snap the
/// cursor onto the row that the toggled gap now occupies. When the gap is
/// expanded the synthetic `.elided` row vanishes; the cursor stays at the
/// same row index (which is now the first revealed source line). When the
/// gap is re-collapsed the cursor lands back on the new `.elided` row.
fn toggleFocusedGap(
    gpa: Allocator,
    built: *BuildResult,
    file_diff: *const rv.FileDiff,
    state: *AppState,
    mode: Mode,
    viewport: u16,
    build_fn: BuildFn,
) !void {
    const gap_id = focusedGapId(built.view, state.cursor_y) orelse return;
    _ = try state.toggleGap(gap_id);
    try rebuild(gpa, built, file_diff, mode, state, build_fn);

    const total = rowCountOfView(built.view);
    if (total == 0) {
        state.cursor_y = 0;
        state.scroll_y = 0;
        return;
    }
    if (findGapRow(built.view, gap_id)) |row| {
        state.cursor_y = row;
    } else {
        state.cursor_y = @min(state.cursor_y, total - 1);
    }
    followCursor(state, viewport, total);
}

fn rowCountOfView(view: View) usize {
    return switch (view) {
        .unified => |ls| ls.len,
        .split => |ps| ps.len,
    };
}

/// After a rebuild, snap the cursor back onto `anchor` (if it still exists)
/// and adjust scroll so the cursor stays visible. If `anchor` is null or
/// can't be located (e.g. nested under a now-collapsed container), clamp
/// the existing cursor/scroll into the new row count.
fn relocateCursor(
    state: *AppState,
    view: View,
    anchor: ?DeclId,
    viewport: u16,
) void {
    const total = rowCountOfView(view);
    if (total == 0) {
        state.cursor_y = 0;
        state.scroll_y = 0;
        return;
    }

    if (anchor) |id| if (findDeclRow(view, id)) |row| {
        state.cursor_y = row;
        followCursor(state, viewport, total);
        return;
    };

    state.cursor_y = @min(state.cursor_y, total - 1);
    followCursor(state, viewport, total);
}

// ── jump-to-decl navigation ───────────────────────────────────────────────

const Direction = enum { forward, backward };
const Bound = enum { first, last };

/// Jump the cursor to the next (or previous) decl header in the index.
/// When `changed_only` is true, headers whose `changed` flag is false
/// (i.e. `unchanged` decls) are skipped. The search wraps around the
/// end of the file, so repeatedly pressing `N` on the last changed decl
/// brings the cursor back to the first changed decl - documented in
/// the module header.
///
/// Lands on the header row regardless of whether the target decl is
/// collapsed; `centerOnRow` then biases `scroll_y` so the decl's body
/// (if any) is visible in the rows below.
fn jumpDecl(
    state: *AppState,
    decl_index: []const DeclIndexEntry,
    dir: Direction,
    changed_only: bool,
    viewport: u16,
    total: usize,
) void {
    const target = switch (dir) {
        .forward => nextDeclRow(decl_index, state.cursor_y, changed_only),
        .backward => prevDeclRow(decl_index, state.cursor_y, changed_only),
    } orelse return;
    centerOnRow(state, target, viewport, total);
}

/// Jump to the first or last decl in the index. No-op on an empty
/// index. Useful to escape out of long leading/trailing blank regions
/// without paging.
fn jumpToEnd(
    state: *AppState,
    decl_index: []const DeclIndexEntry,
    bound: Bound,
    viewport: u16,
    total: usize,
) void {
    if (decl_index.len == 0) return;
    const target = switch (bound) {
        .first => decl_index[0].row,
        .last => decl_index[decl_index.len - 1].row,
    };
    centerOnRow(state, target, viewport, total);
}

/// Linear scan for the first index entry strictly after `cursor_row`,
/// wrapping to the start of the list when none exists. Decl indexes
/// are short (one entry per decl, not per line) so the scan is
/// cheaper than the binary-search + wrap logic hinted at in the task.
fn nextDeclRow(decl_index: []const DeclIndexEntry, cursor_row: usize, changed_only: bool) ?usize {
    if (decl_index.len == 0) return null;
    for (decl_index) |e| {
        if (e.row <= cursor_row) continue;
        if (changed_only and !e.changed) continue;
        return e.row;
    }
    for (decl_index) |e| {
        if (changed_only and !e.changed) continue;
        return e.row;
    }
    return null;
}

fn prevDeclRow(decl_index: []const DeclIndexEntry, cursor_row: usize, changed_only: bool) ?usize {
    if (decl_index.len == 0) return null;
    var i: usize = decl_index.len;
    while (i > 0) {
        i -= 1;
        const e = decl_index[i];
        if (e.row >= cursor_row) continue;
        if (changed_only and !e.changed) continue;
        return e.row;
    }
    i = decl_index.len;
    while (i > 0) {
        i -= 1;
        const e = decl_index[i];
        if (changed_only and !e.changed) continue;
        return e.row;
    }
    return null;
}

/// Place `target` roughly one-third of the way down the viewport so the
/// decl body below the header stays visible. Clamped like `followCursor`
/// so we never scroll past the end of the file. Safe when `viewport` is
/// zero (e.g. during a resize): no divide-by-zero, and the cursor still
/// lands on `target` so a subsequent resize restores a sensible view.
fn centerOnRow(state: *AppState, target: usize, viewport: u16, total: usize) void {
    state.cursor_y = target;
    const bias: usize = viewport / 3;
    state.scroll_y = if (target > bias) target - bias else 0;
    const max_scroll = if (total > viewport) total - viewport else 0;
    state.scroll_y = @min(state.scroll_y, max_scroll);
}

// ── draw: unified ──────────────────────────────────────────────────────────

fn drawUnifiedBody(
    pane: vaxis.Window,
    built: BuildResult,
    state: *const AppState,
    focused: bool,
) void {
    const body = pane.child(.{
        .x_off = 0,
        .y_off = header_rows,
        .width = pane.width,
        .height = bodyHeight(pane.height),
    });

    const lines = built.view.unified;
    const end = @min(state.scroll_y + body.height, lines.len);
    var row: u16 = 0;
    var i: usize = state.scroll_y;
    while (i < end) : (i += 1) {
        drawLine(body, row, lines[i], focused and i == state.cursor_y);
        row += 1;
    }
}

fn drawHeader(win: vaxis.Window, title: []const u8, stats_text: []const u8) void {
    _ = win.print(&.{.{
        .text = title,
        .style = .{ .bold = true },
    }}, .{ .row_offset = 0, .wrap = .none });

    _ = win.print(&.{.{
        .text = stats_text,
        .style = .{ .dim = true },
    }}, .{ .row_offset = 1, .wrap = .none });
}

/// Legacy two-pane header used by `run` in split mode: the two file paths
/// sit above their respective panes on row 0, and the stats line spans the
/// full pane width on row 1. Kept private; `drawDiffPane` doesn't emit this
/// shape because `DiffHeader` only carries a single title.
fn drawSplitLegacyHeader(
    win: vaxis.Window,
    size: PaneSize,
    before_path: []const u8,
    after_path: []const u8,
    stats_text: []const u8,
) void {
    const pane = win.child(.{
        .x_off = size.x_off,
        .y_off = size.y_off,
        .width = size.width,
        .height = size.height,
    });
    const layout = splitLayout(pane.width) orelse return;

    const left_header = pane.child(.{ .x_off = 0, .y_off = 0, .width = layout.left_w, .height = 1 });
    const right_header = pane.child(.{ .x_off = layout.sep_col + separator_cols, .y_off = 0, .width = layout.right_w, .height = 1 });

    _ = left_header.print(&.{.{ .text = before_path, .style = .{ .bold = true } }}, .{ .wrap = .none });
    _ = right_header.print(&.{.{ .text = after_path, .style = .{ .bold = true } }}, .{ .wrap = .none });

    _ = pane.print(
        &.{.{ .text = stats_text, .style = .{ .dim = true } }},
        .{ .row_offset = 1, .wrap = .none },
    );
}

// ── draw: split ────────────────────────────────────────────────────────────

/// Column reserved for the vertical separator between panes.
const separator_cols: u16 = 1;

/// Split-mode pane geometry shared by the header and body renderers so the
/// vertical separator lines up across both. Returns null when the pane is
/// too narrow to fit two panes plus the separator; callers should skip
/// rendering in that case.
const SplitLayout = struct { left_w: u16, right_w: u16, sep_col: u16 };
fn splitLayout(total_w: u16) ?SplitLayout {
    if (total_w < 2) return null;
    const usable = total_w - separator_cols;
    const left_w: u16 = usable / 2;
    return .{ .left_w = left_w, .right_w = usable - left_w, .sep_col = left_w };
}

fn drawSplitBody(
    pane: vaxis.Window,
    built: BuildResult,
    state: *const AppState,
    focused: bool,
) void {
    const layout = splitLayout(pane.width) orelse return;

    const body_h = bodyHeight(pane.height);
    const left_body = pane.child(.{
        .x_off = 0,
        .y_off = header_rows,
        .width = layout.left_w,
        .height = body_h,
    });
    const right_body = pane.child(.{
        .x_off = layout.sep_col + separator_cols,
        .y_off = header_rows,
        .width = layout.right_w,
        .height = body_h,
    });

    // Vertical separator down the full pane height. Drawn after the header
    // so the middle column of the header row reads as part of the separator
    // (matches the pre-refactor look where the separator overdraws the
    // stats-line character).
    const sep: vaxis.Cell = .{
        .char = .{ .grapheme = "│", .width = 1 },
        .style = .{ .dim = true },
    };
    var r: u16 = 0;
    while (r < pane.height) : (r += 1) {
        pane.writeCell(layout.sep_col, r, sep);
    }

    const pairs = built.view.split;
    const end = @min(state.scroll_y + body_h, pairs.len);
    var row: u16 = 0;
    var i: usize = state.scroll_y;
    while (i < end) : (i += 1) {
        const is_cursor = focused and i == state.cursor_y;
        // Cursor marker is only drawn on the left pane so the right pane's
        // gutter stays readable.
        drawLine(left_body, row, pairs[i].left, is_cursor);
        drawLine(right_body, row, pairs[i].right, false);
        row += 1;
    }
}

// ── draw: shared ───────────────────────────────────────────────────────────

fn drawLine(body: vaxis.Window, row: u16, sl: StyledLine, cursor: bool) void {
    if (sl.kind == .elided) {
        drawElidedLine(body, row, sl, cursor);
        return;
    }
    if (sl.kind == .decl_anchor) {
        drawDeclAnchor(body, row, sl, cursor);
        return;
    }
    if (sl.marker == .blank and sl.kind == .blank) {
        if (cursor) {
            _ = body.print(&.{.{
                .text = ">",
                .style = .{ .bold = true },
            }}, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
        }
        return;
    }

    const base_style = styleFor(sl);

    // Gutter: 1-char cursor or marker + space. Overlaying the marker on the
    // focused row keeps the existing layout (no extra column reserved for
    // the cursor) while still giving a subtle visual anchor.
    const gutter_char: []const u8 = if (cursor) ">" else sl.marker.gutter();
    _ = body.print(&.{.{
        .text = gutter_char,
        .style = base_style,
    }}, .{ .row_offset = row, .col_offset = 0, .wrap = .none });

    // Indent columns (2 per level) start after the gutter + space.
    const indent_cols: u16 = @as(u16, @intCast(sl.indent)) * 2;
    const text_col: u16 = 2 + indent_cols;

    drawStyledText(body, row, text_col, sl, base_style);
    drawDeclAnnotation(body, row, text_col, sl);
}

/// Render `sl.decl_annotation` as a trailing dim suffix to the right of
/// the source text. Inlined annotation on the decl's first source row
/// replaces the dedicated `.decl_anchor` landmark row in the file-wide
/// view. No-op when `sl.decl_annotation == null`.
fn drawDeclAnnotation(
    body: vaxis.Window,
    row: u16,
    text_col: u16,
    sl: StyledLine,
) void {
    const annotation = sl.decl_annotation orelse return;

    const text_cols: u16 = vaxis.gwidth.gwidth(sl.text, .unicode);
    // 2-cell gap between the source text and the annotation so the
    // annotation reads as a separate landmark, not a continuation of
    // the line. Skip drawing entirely if the gap alone would push us
    // past the body width.
    const gap_cols: u16 = 2;
    const start_col_u32: u32 = @as(u32, text_col) + @as(u32, text_cols) + @as(u32, gap_cols);
    if (start_col_u32 >= body.width) return;
    const start_col: u16 = @intCast(start_col_u32);

    _ = body.print(&.{.{
        .text = annotation,
        .style = .{ .dim = true },
    }}, .{ .row_offset = row, .col_offset = start_col, .wrap = .none });
}

/// Render a `… N unchanged lines …` row. Centred dim italic text with a
/// `⋯` gutter to read as a structural break rather than a source line.
/// When focused, the gutter swaps to `>` and the body text loses the dim
/// bit so it reads as "press space to expand".
fn drawElidedLine(body: vaxis.Window, row: u16, sl: StyledLine, cursor: bool) void {
    const gutter_char: []const u8 = if (cursor) ">" else "\u{22EF}";
    const gutter_style: vaxis.Style = if (cursor)
        .{ .bold = true }
    else
        .{ .dim = true };
    _ = body.print(&.{.{
        .text = gutter_char,
        .style = gutter_style,
    }}, .{ .row_offset = row, .col_offset = 0, .wrap = .none });

    const text_style: vaxis.Style = if (cursor)
        .{ .italic = true, .bold = true }
    else
        .{ .dim = true, .italic = true };

    // Centre `sl.text` inside the body width past the gutter+space prefix.
    // Use vaxis's grapheme-width function so the multi-byte ellipsis
    // (`\u{2026}`) counts as one column rather than three (its UTF-8 byte
    // length); without this the text would drift right of centre.
    const prefix_cols: u16 = 2;
    const avail: u16 = if (body.width > prefix_cols) body.width - prefix_cols else 0;
    const text_cols: u16 = @min(avail, vaxis.gwidth.gwidth(sl.text, .unicode));
    const pad: u16 = if (avail > text_cols) (avail - text_cols) / 2 else 0;
    const text_col: u16 = prefix_cols + pad;
    _ = body.print(&.{.{
        .text = sl.text,
        .style = text_style,
    }}, .{ .row_offset = row, .col_offset = text_col, .wrap = .none });
}

/// Render a `.decl_anchor` landmark row above a decl's first source line.
/// Dim italic so it reads as annotation, not a source line. Marker colour
/// (added/removed/changed) tints the gutter and text. The fixed `\u{25B8}`
/// gutter (right-pointing triangle) keeps it visually distinct from
/// `.decl_header`'s `=`/`+`/`-`/`~` gutter.
fn drawDeclAnchor(body: vaxis.Window, row: u16, sl: StyledLine, cursor: bool) void {
    const base_style = styleFor(sl);
    const gutter_char: []const u8 = if (cursor) ">" else "\u{25B8}";
    _ = body.print(&.{.{
        .text = gutter_char,
        .style = base_style,
    }}, .{ .row_offset = row, .col_offset = 0, .wrap = .none });

    const indent_cols: u16 = @as(u16, @intCast(sl.indent)) * 2;
    const text_col: u16 = 2 + indent_cols;
    _ = body.print(&.{.{
        .text = sl.text,
        .style = base_style,
    }}, .{ .row_offset = row, .col_offset = text_col, .wrap = .none });
}

/// Paint the text portion of a StyledLine, layering (in priority order):
///
///   1. Syntax-highlight spans from `sl.highlights` → per-token fg.
///   2. Novel-range overlay from `sl.novel_spans` → reverse-video on top.
///   3. Base marker style for any byte not covered by a highlight.
///
/// The rendering walks the line one display-byte at a time in O(n) with a
/// two-cursor sweep over the (sorted, non-overlapping) highlight and
/// novel-span arrays. Runs with the same effective style are coalesced so
/// we emit one `print` call per visual segment.
fn drawStyledText(
    body: vaxis.Window,
    row: u16,
    text_col: u16,
    sl: StyledLine,
    base_style: vaxis.Style,
) void {
    if (sl.text.len == 0) return;

    // Fast path: no decoration → single print.
    if (sl.highlights.len == 0 and sl.novel_spans.len == 0) {
        _ = body.print(&.{.{ .text = sl.text, .style = base_style }}, .{
            .row_offset = row,
            .col_offset = text_col,
            .wrap = .none,
        });
        return;
    }

    var hl_i: usize = 0;
    var nv_i: usize = 0;
    var pos: usize = 0;
    var run_start: usize = 0;
    var run_style: vaxis.Style = effectiveStyle(sl, base_style, pos, &hl_i, &nv_i);

    pos = 1;
    while (pos < sl.text.len) : (pos += 1) {
        const s = effectiveStyle(sl, base_style, pos, &hl_i, &nv_i);
        if (!s.eql(run_style)) {
            _ = body.print(&.{.{
                .text = sl.text[run_start..pos],
                .style = run_style,
            }}, .{
                .row_offset = row,
                .col_offset = text_col + @as(u16, @intCast(run_start)),
                .wrap = .none,
            });
            run_start = pos;
            run_style = s;
        }
    }
    _ = body.print(&.{.{
        .text = sl.text[run_start..pos],
        .style = run_style,
    }}, .{
        .row_offset = row,
        .col_offset = text_col + @as(u16, @intCast(run_start)),
        .wrap = .none,
    });
}

/// Compute the per-byte effective style. `hl_i` / `nv_i` are monotonic
/// cursors into the sorted span arrays and are advanced past spans that
/// end at or before `pos`.
fn effectiveStyle(
    sl: StyledLine,
    base_style: vaxis.Style,
    pos: usize,
    hl_i: *usize,
    nv_i: *usize,
) vaxis.Style {
    while (hl_i.* < sl.highlights.len and sl.highlights[hl_i.*].end <= pos) hl_i.* += 1;
    while (nv_i.* < sl.novel_spans.len and sl.novel_spans[nv_i.*].end <= pos) nv_i.* += 1;

    var style = base_style;
    if (hl_i.* < sl.highlights.len) {
        const h = sl.highlights[hl_i.*];
        if (pos >= h.start and pos < h.end) {
            style = theme.style(h.class, base_style);
        }
    }
    if (nv_i.* < sl.novel_spans.len) {
        const n = sl.novel_spans[nv_i.*];
        if (pos >= n.start and pos < n.end) {
            style = novelStyleFor(style);
        }
    }
    return style;
}

/// Stronger variant of `base` for atom-level novel ranges. Reverse video
/// keeps the highlight legible regardless of the user's palette while
/// preserving the +/-/~ colour as the background tint.
fn novelStyleFor(base: vaxis.Style) vaxis.Style {
    var s = base;
    s.reverse = true;
    // A dimmed base would cancel out under reverse (background dimming looks
    // like a muddy block); force it off inside the novel range so the
    // differing bytes pop even inside otherwise-dim unchanged context.
    s.dim = false;
    return s;
}

/// Colour choice: indexed ANSI so we inherit the user's terminal palette.
/// Decl headers are bold; source lines are regular weight with a tinted fg.
/// Decl anchors and elided rows are explicit arms - they read as
/// annotations rather than source/headers, so they get dim italic with
/// just enough marker colour to identify added/removed/changed anchors.
fn styleFor(sl: StyledLine) vaxis.Style {
    if (sl.kind == .elided) {
        return .{ .dim = true, .italic = true };
    }
    if (sl.kind == .decl_anchor) {
        return switch (sl.marker) {
            .added => .{ .fg = .{ .index = 2 }, .dim = true, .italic = true },
            .removed => .{ .fg = .{ .index = 1 }, .dim = true, .italic = true },
            .changed => .{ .fg = .{ .index = 3 }, .dim = true, .italic = true },
            .unchanged, .context, .blank => .{ .dim = true, .italic = true },
        };
    }
    const bold = sl.kind == .decl_header;
    return switch (sl.marker) {
        .added => .{ .fg = .{ .index = 2 }, .bold = bold },
        .removed => .{ .fg = .{ .index = 1 }, .bold = bold },
        .changed => .{ .fg = .{ .index = 3 }, .bold = bold },
        .unchanged => .{ .dim = true, .bold = bold },
        .context => .{ .dim = true },
        .blank => .{},
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeState(scroll: usize, cursor: usize) AppState {
    var s = AppState.init(testing.allocator);
    s.scroll_y = scroll;
    s.cursor_y = cursor;
    return s;
}

fn keyCp(cp: u21) vaxis.Key {
    return .{ .codepoint = cp, .base_layout_codepoint = cp, .shifted_codepoint = cp, .text = null, .mods = .{} };
}

fn mouseEvent(
    button: vaxis.Mouse.Button,
    kind: vaxis.Mouse.Type,
    row: i16,
    col: i16,
) vaxis.Mouse {
    return .{
        .col = col,
        .row = row,
        .button = button,
        .mods = .{},
        .type = kind,
    };
}

test "applyNavigationKey: j moves cursor down, scroll follows when cursor leaves viewport" {
    var state = makeState(0, 19);
    defer state.deinit();

    applyNavigationKey(&state, keyCp('j'), 20, 100);
    // cursor=20, viewport=20, so scroll must advance to 1 to keep it visible.
    try testing.expectEqual(@as(usize, 20), state.cursor_y);
    try testing.expectEqual(@as(usize, 1), state.scroll_y);
}

test "applyNavigationKey: k moves cursor up, clamps at 0" {
    var state = makeState(5, 5);
    defer state.deinit();

    applyNavigationKey(&state, keyCp('k'), 20, 100);
    try testing.expectEqual(@as(usize, 4), state.cursor_y);
    try testing.expectEqual(@as(usize, 4), state.scroll_y);

    var state2 = makeState(0, 0);
    defer state2.deinit();
    applyNavigationKey(&state2, keyCp('k'), 20, 100);
    try testing.expectEqual(@as(usize, 0), state2.cursor_y);
}

test "applyNavigationKey: page_down moves cursor by viewport, clamps at last row" {
    var state = makeState(0, 0);
    defer state.deinit();

    applyNavigationKey(&state, keyCp(vaxis.Key.page_down), 20, 100);
    try testing.expectEqual(@as(usize, 20), state.cursor_y);

    // Second page-down overshoots; clamp at 99.
    for (0..10) |_| applyNavigationKey(&state, keyCp(vaxis.Key.page_down), 20, 100);
    try testing.expectEqual(@as(usize, 99), state.cursor_y);
}

test "applyNavigationKey: home/end jump to first/last row" {
    var state = makeState(50, 50);
    defer state.deinit();

    applyNavigationKey(&state, keyCp(vaxis.Key.home), 20, 100);
    try testing.expectEqual(@as(usize, 0), state.cursor_y);
    try testing.expectEqual(@as(usize, 0), state.scroll_y);

    applyNavigationKey(&state, keyCp(vaxis.Key.end), 20, 100);
    try testing.expectEqual(@as(usize, 99), state.cursor_y);
    // Scroll positions the last row at the bottom of the viewport.
    try testing.expectEqual(@as(usize, 80), state.scroll_y);
}

test "applyNavigationKey: unknown key leaves state untouched" {
    var state = makeState(3, 7);
    defer state.deinit();

    applyNavigationKey(&state, keyCp('x'), 20, 100);
    try testing.expectEqual(@as(usize, 7), state.cursor_y);
    try testing.expectEqual(@as(usize, 3), state.scroll_y);
}

test "applyMouse: wheel_up scrolls by wheel_step, clamps at 0; cursor untouched" {
    var state = makeState(10, 42);
    defer state.deinit();
    applyMouse(&state, mouseEvent(.wheel_up, .press, 5, 0), 20, 100);
    try testing.expectEqual(@as(usize, 7), state.scroll_y);
    try testing.expectEqual(@as(usize, 42), state.cursor_y);

    var state2 = makeState(1, 0);
    defer state2.deinit();
    applyMouse(&state2, mouseEvent(.wheel_up, .press, 5, 0), 20, 100);
    try testing.expectEqual(@as(usize, 0), state2.scroll_y);
}

test "applyMouse: wheel_down scrolls by wheel_step, clamps at max_scroll" {
    var state = makeState(79, 0);
    defer state.deinit();
    applyMouse(&state, mouseEvent(.wheel_down, .press, 5, 0), 20, 100);
    try testing.expectEqual(@as(usize, 80), state.scroll_y);
}

test "applyMouse: left click in body sets cursor to absolute row" {
    var state = makeState(10, 0);
    defer state.deinit();
    applyMouse(&state, mouseEvent(.left, .press, 5, 0), 20, 100);
    // header_rows=2, click row 5 → in-body 3 → abs 13.
    try testing.expectEqual(@as(usize, 13), state.cursor_y);
    try testing.expectEqual(@as(usize, 10), state.scroll_y);
}

test "applyMouse: left click inside header strip is ignored" {
    var state = makeState(10, 7);
    defer state.deinit();
    applyMouse(&state, mouseEvent(.left, .press, 0, 0), 20, 100);
    try testing.expectEqual(@as(usize, 7), state.cursor_y);
    applyMouse(&state, mouseEvent(.left, .press, 1, 0), 20, 100);
    try testing.expectEqual(@as(usize, 7), state.cursor_y);
}

test "applyMouse: left click past end of content leaves cursor unchanged" {
    // total=5, viewport=20, click viewport row 12 → abs 10, out of bounds.
    var state = makeState(0, 3);
    defer state.deinit();
    applyMouse(&state, mouseEvent(.left, .press, 12, 0), 20, 5);
    try testing.expectEqual(@as(usize, 3), state.cursor_y);
}

test "applyMouse: non-left, non-wheel buttons are ignored" {
    var state = makeState(10, 7);
    defer state.deinit();
    applyMouse(&state, mouseEvent(.right, .press, 5, 0), 20, 100);
    try testing.expectEqual(@as(usize, 10), state.scroll_y);
    try testing.expectEqual(@as(usize, 7), state.cursor_y);
}

test "applyMouse: non-press events do not mutate state" {
    var state = makeState(10, 7);
    defer state.deinit();
    applyMouse(&state, mouseEvent(.left, .release, 5, 0), 20, 100);
    try testing.expectEqual(@as(usize, 10), state.scroll_y);
    try testing.expectEqual(@as(usize, 7), state.cursor_y);

    applyMouse(&state, mouseEvent(.left, .drag, 5, 0), 20, 100);
    try testing.expectEqual(@as(usize, 10), state.scroll_y);
    try testing.expectEqual(@as(usize, 7), state.cursor_y);
}

test "focusedDeclId: returns id of nearest decl_header at or above cursor" {
    const id_a: DeclId = 0xAAA;
    const id_b: DeclId = 0xBBB;
    const lines = [_]StyledLine{
        .{ .indent = 0, .marker = .changed, .kind = .decl_header, .text = "a", .decl_id = id_a },
        .{ .indent = 1, .marker = .removed, .kind = .source, .text = "  old" },
        .{ .indent = 1, .marker = .added, .kind = .source, .text = "  new" },
        .{ .indent = 0, .marker = .added, .kind = .decl_header, .text = "b", .decl_id = id_b },
        .{ .indent = 1, .marker = .added, .kind = .source, .text = "  body" },
    };
    const view: View = .{ .unified = lines[0..] };

    try testing.expectEqual(@as(?DeclId, id_a), focusedDeclId(view, 0));
    try testing.expectEqual(@as(?DeclId, id_a), focusedDeclId(view, 2)); // source of a
    try testing.expectEqual(@as(?DeclId, id_b), focusedDeclId(view, 3));
    try testing.expectEqual(@as(?DeclId, id_b), focusedDeclId(view, 4)); // source of b
}

test "focusedDeclId: empty view → null" {
    const view: View = .{ .unified = &.{} };
    try testing.expectEqual(@as(?DeclId, null), focusedDeclId(view, 0));
}

test "focusedDeclId: returns the anchor's decl_id when cursor is on a decl_anchor or a source row beneath it" {
    // File-wide builder emits `.decl_anchor` instead of `.decl_header`.
    // Walking back from a source row must treat anchors as the enclosing
    // decl landmark.
    const id_a: DeclId = 0xA1;
    const id_b: DeclId = 0xB2;
    const lines = [_]StyledLine{
        .{ .indent = 0, .marker = .changed, .kind = .decl_anchor, .text = "fn:a", .decl_id = id_a },
        .{ .indent = 1, .marker = .unchanged, .kind = .source, .text = "  body", .decl_id = id_a },
        .{ .indent = 1, .marker = .removed, .kind = .source, .text = "  old", .decl_id = id_a },
        .{ .indent = 0, .marker = .added, .kind = .decl_anchor, .text = "fn:b", .decl_id = id_b },
        .{ .indent = 1, .marker = .added, .kind = .source, .text = "  body", .decl_id = id_b },
    };
    const view: View = .{ .unified = lines[0..] };

    // Cursor directly on the anchor row.
    try testing.expectEqual(@as(?DeclId, id_a), focusedDeclId(view, 0));
    // Cursor on a source row beneath the anchor.
    try testing.expectEqual(@as(?DeclId, id_a), focusedDeclId(view, 1));
    try testing.expectEqual(@as(?DeclId, id_a), focusedDeclId(view, 2));
    // Cursor on the next anchor.
    try testing.expectEqual(@as(?DeclId, id_b), focusedDeclId(view, 3));
    try testing.expectEqual(@as(?DeclId, id_b), focusedDeclId(view, 4));
}

test "focusedDeclId split: anchors on either side resolve like headers" {
    // `.added` anchor sits on the right with a blank on the left;
    // mirrored anchors sit on both sides.
    const id_add: DeclId = 0xAD;
    const id_x: DeclId = 0xC1;
    const blank: StyledLine = .{ .indent = 0, .marker = .blank, .kind = .blank, .text = "" };
    const pairs = [_]LinePair{
        .{
            .left = blank,
            .right = .{ .indent = 0, .marker = .added, .kind = .decl_anchor, .text = "fn:add", .decl_id = id_add },
        },
        .{
            .left = .{ .indent = 1, .marker = .added, .kind = .source, .text = "", .decl_id = id_add },
            .right = .{ .indent = 1, .marker = .added, .kind = .source, .text = "  body", .decl_id = id_add },
        },
        .{
            .left = .{ .indent = 0, .marker = .changed, .kind = .decl_anchor, .text = "fn:x", .decl_id = id_x },
            .right = .{ .indent = 0, .marker = .changed, .kind = .decl_anchor, .text = "fn:x", .decl_id = id_x },
        },
    };
    const view: View = .{ .split = pairs[0..] };
    try testing.expectEqual(@as(?DeclId, id_add), focusedDeclId(view, 0));
    try testing.expectEqual(@as(?DeclId, id_add), focusedDeclId(view, 1));
    try testing.expectEqual(@as(?DeclId, id_x), focusedDeclId(view, 2));
}

test "relocateCursor: anchor still in view → cursor snaps onto new row" {
    const id: DeclId = 0xCAFE;
    const lines = [_]StyledLine{
        .{ .indent = 0, .marker = .unchanged, .kind = .decl_header, .text = "x", .decl_id = 0x111 },
        .{ .indent = 0, .marker = .changed, .kind = .decl_header, .text = "y", .decl_id = id },
        .{ .indent = 1, .marker = .added, .kind = .source, .text = "  body" },
    };
    var state = makeState(0, 2);
    defer state.deinit();
    relocateCursor(&state, .{ .unified = lines[0..] }, id, 20);
    try testing.expectEqual(@as(usize, 1), state.cursor_y);
}

test "relocateCursor: empty view → cursor and scroll reset to 0" {
    var state = makeState(99, 99);
    defer state.deinit();
    relocateCursor(&state, .{ .unified = &.{} }, null, 20);
    try testing.expectEqual(@as(usize, 0), state.cursor_y);
    try testing.expectEqual(@as(usize, 0), state.scroll_y);
}

test "relocateCursor: anchor gone (collapse hid it) → clamp cursor into new view" {
    const lines = [_]StyledLine{
        .{ .indent = 0, .marker = .changed, .kind = .decl_header, .text = "a", .decl_id = 0x1 },
    };
    var state = makeState(0, 5); // cursor was pointing past end
    defer state.deinit();
    relocateCursor(&state, .{ .unified = lines[0..] }, 0xDEAD, 20);
    try testing.expectEqual(@as(usize, 0), state.cursor_y);
}

// Integration-ish test: end-to-end collapse across a rebuild, verifying that
// cursor tracking keeps the focused decl on-screen and that the acceptance
// criterion "scroll only counts visible lines" holds. We drive the pure
// helpers directly instead of standing up a tty.
test "collapse integration: rebuild preserves focus, scroll counts visible lines only" {
    const before =
        \\pub fn first() u32 { return 1; }
        \\pub fn second() u32 { return 2; }
    ;
    const after =
        \\pub fn first() u32 { return 10; }
        \\pub fn second() u32 { return 20; }
    ;

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();

    var current = try line_mod.build(testing.allocator, &fd, .unified, &state);
    defer current.deinit();

    const expanded_rows = current.rowCount();

    // Focus the second decl (walk to its header).
    var second_id: ?DeclId = null;
    for (current.view.unified, 0..) |ln, i| {
        if (ln.kind == .decl_header and std.mem.startsWith(u8, ln.text, "second")) {
            state.cursor_y = i;
            second_id = ln.decl_id;
            break;
        }
    }
    try testing.expect(second_id != null);
    const focused = focusedDeclId(current.view, state.cursor_y).?;
    try testing.expectEqual(second_id.?, focused);

    // Toggle it collapsed and rebuild.
    _ = try state.toggle(focused);
    try rebuild(testing.allocator, &current, &fd, .unified, &state, &line_mod.build);
    relocateCursor(&state, current.view, focused, 20);

    // Row count dropped (body lines hidden) and cursor still points at
    // `second`'s now-collapsed header.
    try testing.expect(current.rowCount() < expanded_rows);
    const row_after = findDeclRow(current.view, focused).?;
    try testing.expectEqual(row_after, state.cursor_y);
    // Header now has the `[…]` suffix.
    try testing.expect(std.mem.endsWith(
        u8,
        current.view.unified[row_after].text,
        " [\u{2026}]",
    ));

    // Expand-all restores full row count.
    state.expandAll();
    try rebuild(testing.allocator, &current, &fd, .unified, &state, &line_mod.build);
    try testing.expectEqual(expanded_rows, current.rowCount());
}

test "collapse integration: [ collapses all changed decls, ] expands" {
    const before = "pub fn a() u32 { return 1; }\npub fn b() u32 { return 1; }\n";
    const after = "pub fn a() u32 { return 2; }\npub fn b() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();

    var current = try line_mod.build(testing.allocator, &fd, .unified, &state);
    defer current.deinit();

    try state.collapseAll(&fd);
    try rebuild(testing.allocator, &current, &fd, .unified, &state, &line_mod.build);

    // Only headers remain.
    for (current.view.unified) |ln| try testing.expectEqual(LineKind.decl_header, ln.kind);
    try testing.expect(current.view.unified.len >= 2);

    state.expandAll();
    try rebuild(testing.allocator, &current, &fd, .unified, &state, &line_mod.build);

    var saw_source = false;
    for (current.view.unified) |ln| if (ln.kind == .source) {
        saw_source = true;
    };
    try testing.expect(saw_source);
}

// ── jump-to-decl ─────────────────────────────────────────────────────────────────────

test "nextDeclRow: walks forward, wraps to start at end of file" {
    const idx = [_]DeclIndexEntry{
        .{ .row = 0, .changed = false },
        .{ .row = 5, .changed = true },
        .{ .row = 12, .changed = false },
        .{ .row = 20, .changed = true },
    };
    try testing.expectEqual(@as(?usize, 5), nextDeclRow(idx[0..], 0, false));
    try testing.expectEqual(@as(?usize, 12), nextDeclRow(idx[0..], 5, false));
    try testing.expectEqual(@as(?usize, 12), nextDeclRow(idx[0..], 8, false));
    try testing.expectEqual(@as(?usize, 20), nextDeclRow(idx[0..], 15, false));
    // Past the last row → wrap to first.
    try testing.expectEqual(@as(?usize, 0), nextDeclRow(idx[0..], 20, false));
    try testing.expectEqual(@as(?usize, 0), nextDeclRow(idx[0..], 999, false));
}

test "nextDeclRow: changed_only skips unchanged entries, wraps to first changed" {
    const idx = [_]DeclIndexEntry{
        .{ .row = 0, .changed = false },
        .{ .row = 5, .changed = true },
        .{ .row = 12, .changed = false },
        .{ .row = 20, .changed = true },
        .{ .row = 30, .changed = false },
    };
    // From row 0, first changed is at 5.
    try testing.expectEqual(@as(?usize, 5), nextDeclRow(idx[0..], 0, true));
    // From row 5, skip the row-12 unchanged and land on 20.
    try testing.expectEqual(@as(?usize, 20), nextDeclRow(idx[0..], 5, true));
    // From past-the-last, wrap back to the first *changed* row (5, not 0).
    try testing.expectEqual(@as(?usize, 5), nextDeclRow(idx[0..], 999, true));
}

test "nextDeclRow: empty or all-unchanged with changed_only → null" {
    try testing.expectEqual(@as(?usize, null), nextDeclRow(&.{}, 0, false));
    const only_unchanged = [_]DeclIndexEntry{
        .{ .row = 0, .changed = false },
        .{ .row = 5, .changed = false },
    };
    try testing.expectEqual(@as(?usize, null), nextDeclRow(only_unchanged[0..], 0, true));
    // changed_only=false still walks through unchanged entries.
    try testing.expectEqual(@as(?usize, 5), nextDeclRow(only_unchanged[0..], 0, false));
}

test "prevDeclRow: walks backward, wraps to last at start of file" {
    const idx = [_]DeclIndexEntry{
        .{ .row = 0, .changed = false },
        .{ .row = 5, .changed = true },
        .{ .row = 12, .changed = false },
        .{ .row = 20, .changed = true },
    };
    try testing.expectEqual(@as(?usize, 12), prevDeclRow(idx[0..], 20, false));
    try testing.expectEqual(@as(?usize, 5), prevDeclRow(idx[0..], 10, false));
    try testing.expectEqual(@as(?usize, 0), prevDeclRow(idx[0..], 5, false));
    // Before the first row → wrap to last.
    try testing.expectEqual(@as(?usize, 20), prevDeclRow(idx[0..], 0, false));
}

test "prevDeclRow: changed_only skips unchanged entries" {
    const idx = [_]DeclIndexEntry{
        .{ .row = 0, .changed = false },
        .{ .row = 5, .changed = true },
        .{ .row = 12, .changed = false },
        .{ .row = 20, .changed = true },
    };
    // From row 20 (changed), previous changed is 5 (skip row 12 unchanged).
    try testing.expectEqual(@as(?usize, 5), prevDeclRow(idx[0..], 20, true));
    // Before any changed row → wrap to the last changed (20).
    try testing.expectEqual(@as(?usize, 20), prevDeclRow(idx[0..], 0, true));
}

test "centerOnRow: places target in top third of viewport, clamps at zero" {
    var state = makeState(0, 0);
    defer state.deinit();
    // viewport=30, bias=10 → scroll=target-10.
    centerOnRow(&state, 50, 30, 200);
    try testing.expectEqual(@as(usize, 50), state.cursor_y);
    try testing.expectEqual(@as(usize, 40), state.scroll_y);

    // Target inside the bias window → scroll clamps to 0.
    centerOnRow(&state, 3, 30, 200);
    try testing.expectEqual(@as(usize, 3), state.cursor_y);
    try testing.expectEqual(@as(usize, 0), state.scroll_y);
}

test "centerOnRow: never scrolls past the end of the file" {
    var state = makeState(0, 0);
    defer state.deinit();
    // Target near the end: raw scroll would be 195-10=185, but max_scroll=170.
    centerOnRow(&state, 195, 30, 200);
    try testing.expectEqual(@as(usize, 195), state.cursor_y);
    try testing.expectEqual(@as(usize, 170), state.scroll_y);
}

test "jumpDecl: from unchanged cursor, N lands on first changed decl" {
    // Simulate a file where decls sit at rows 0, 10, 20, 30 with only row
    // 20 being changed. Pressing `N` from the top should jump straight to
    // row 20, skipping row 10's unchanged header.
    const idx = [_]DeclIndexEntry{
        .{ .row = 0, .changed = false },
        .{ .row = 10, .changed = false },
        .{ .row = 20, .changed = true },
        .{ .row = 30, .changed = false },
    };
    var state = makeState(0, 0);
    defer state.deinit();
    jumpDecl(&state, idx[0..], .forward, true, 20, 100);
    try testing.expectEqual(@as(usize, 20), state.cursor_y);

    // From row 20, N wraps back to row 20 itself (it's the only changed decl).
    // Forward-strict semantics wrap to the first changed hit, which here is 20.
    jumpDecl(&state, idx[0..], .forward, true, 20, 100);
    try testing.expectEqual(@as(usize, 20), state.cursor_y);
}

test "jumpToEnd: first/last bounds land on boundary decls" {
    const idx = [_]DeclIndexEntry{
        .{ .row = 3, .changed = false },
        .{ .row = 15, .changed = true },
        .{ .row = 42, .changed = false },
    };
    var state = makeState(10, 20);
    defer state.deinit();
    jumpToEnd(&state, idx[0..], .first, 10, 100);
    try testing.expectEqual(@as(usize, 3), state.cursor_y);

    jumpToEnd(&state, idx[0..], .last, 10, 100);
    try testing.expectEqual(@as(usize, 42), state.cursor_y);

    // Empty index leaves state alone.
    const empty: []const DeclIndexEntry = &.{};
    state.cursor_y = 7;
    state.scroll_y = 3;
    jumpToEnd(&state, empty, .first, 10, 100);
    try testing.expectEqual(@as(usize, 7), state.cursor_y);
    try testing.expectEqual(@as(usize, 3), state.scroll_y);
}

// Integration test against a real FileDiff: decl_index is built correctly
// and N skips unchanged decls to reach the first changed one. Mirrors the
// acceptance criterion "Pressing N on a file with many decls but a few
// changes jumps cleanly from one change to the next."
test "jump-to-decl integration: N skips unchanged decls, lands on changed" {
    const before =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() u32 { return 1; }
        \\pub fn d() void {}
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() u32 { return 2; }
        \\pub fn d() void {}
    ;

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();

    var current = try line_mod.build(testing.allocator, &fd, .unified, &state);
    defer current.deinit();

    // Index has exactly four entries, one per decl.
    try testing.expectEqual(@as(usize, 4), current.decl_index.len);
    // Only `c` is changed.
    var changed_count: usize = 0;
    for (current.decl_index) |e| if (e.changed) {
        changed_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), changed_count);

    // From cursor at top, N jumps to the changed row.
    state.cursor_y = 0;
    jumpDecl(&state, current.decl_index, .forward, true, 20, current.rowCount());
    // Cursor now sits on a changed decl header.
    const at_cursor = current.view.unified[state.cursor_y];
    try testing.expectEqual(LineKind.decl_header, at_cursor.kind);
    try testing.expectEqual(Marker.changed, at_cursor.marker);
}

test "jump-to-decl integration: jumping to a collapsed decl leaves it collapsed" {
    const before = "pub fn a() u32 { return 1; }\npub fn b() u32 { return 1; }\n";
    const after = "pub fn a() u32 { return 2; }\npub fn b() u32 { return 2; }\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();

    // Collapse everything up-front, then rebuild.
    try state.collapseAll(&fd);
    var current = try line_mod.build(testing.allocator, &fd, .unified, &state);
    defer current.deinit();

    // Body lines are hidden; only decl headers remain.
    for (current.view.unified) |ln| try testing.expectEqual(LineKind.decl_header, ln.kind);

    state.cursor_y = 0;
    jumpDecl(&state, current.decl_index, .forward, false, 30, current.rowCount());

    // Landed on the second decl header, still collapsed ("…" suffix).
    const at = current.view.unified[state.cursor_y];
    try testing.expectEqual(LineKind.decl_header, at.kind);
    try testing.expect(std.mem.endsWith(u8, at.text, " [\u{2026}]"));
}

// ── drawDiffPane offset math ─────────────────────────────────────────────────

test "bodyHeight reserves header_rows at the top of the pane" {
    // Pane too short to hold the header gets zero body rows.
    try testing.expectEqual(@as(u16, 0), bodyHeight(0));
    try testing.expectEqual(@as(u16, 0), bodyHeight(1));
    try testing.expectEqual(@as(u16, 0), bodyHeight(2));
    // Otherwise body gets everything past the 2-row header strip.
    try testing.expectEqual(@as(u16, 1), bodyHeight(3));
    try testing.expectEqual(@as(u16, 18), bodyHeight(20));
}

test "drawDiffPane: body lines land at PaneSize offset plus header_rows" {
    // Build a throwaway screen so we can inspect absolute cell positions
    // after a draw. The pane we draw into sits at (5, 3) with a 30×5 rect,
    // so the header lands on absolute rows 3-4 and the body on rows 5-7.
    var screen = try vaxis.Screen.init(testing.allocator, .{
        .cols = 40,
        .rows = 8,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(testing.allocator);

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 8,
        .screen = &screen,
    };
    // Match what `run` does each frame: clear the window so cells outside
    // the paint region carry `.default = true`, giving us a reliable
    // "untouched" sentinel to assert against below.
    win.clear();

    // Minimal BuildResult: one unified line sitting at row 0 of the body.
    // Arena setup lives in a block so the errdefer only fires on in-block
    // errors; once ownership moves to `built`, `defer built.deinit()` below
    // is the sole freer and there's no risk of double-free on assertion
    // failures further down.
    var built: BuildResult = blk: {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const lines = try a.alloc(StyledLine, 1);
        lines[0] = .{ .indent = 0, .marker = .added, .kind = .source, .text = "hello" };
        break :blk .{
            .view = .{ .unified = lines },
            .stats = .{},
            .decl_index = &.{},
            .arena = arena,
        };
    };
    defer built.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();

    const pane: PaneSize = .{ .x_off = 5, .y_off = 3, .width = 30, .height = 5 };
    drawDiffPane(win, pane, built, &state, .unified, false, .{
        .title = "T",
        .stats = "S",
    });

    // Header row 0 of pane → absolute (5, 3). Header is bold.
    const header_cell = screen.readCell(5, 3).?;
    try testing.expectEqualStrings("T", header_cell.char.grapheme);
    try testing.expect(header_cell.style.bold);

    // Stats row 1 of pane → absolute (5, 4).
    const stats_cell = screen.readCell(5, 4).?;
    try testing.expectEqualStrings("S", stats_cell.char.grapheme);

    // Body row 0 of pane → absolute (5, 3 + header_rows) = (5, 5). Gutter `+`.
    const gutter = screen.readCell(5, 5).?;
    try testing.expectEqualStrings("+", gutter.char.grapheme);

    // Outside the pane (absolute row 2, above y_off=3) must stay pristine.
    const outside = screen.readCell(5, 2).?;
    try testing.expect(outside.default);
}

test "drawDiffPane: null header leaves the top header rows untouched" {
    var screen = try vaxis.Screen.init(testing.allocator, .{
        .cols = 20,
        .rows = 6,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(testing.allocator);

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 6,
        .screen = &screen,
    };
    win.clear();

    var built: BuildResult = blk: {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const lines = try a.alloc(StyledLine, 1);
        lines[0] = .{ .indent = 0, .marker = .added, .kind = .source, .text = "x" };
        break :blk .{
            .view = .{ .unified = lines },
            .stats = .{},
            .decl_index = &.{},
            .arena = arena,
        };
    };
    defer built.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();

    const pane: PaneSize = .{ .x_off = 0, .y_off = 0, .width = 20, .height = 6 };
    drawDiffPane(win, pane, built, &state, .unified, false, null);

    // Header rows stay the default (blank) cell.
    try testing.expect(screen.readCell(0, 0).?.default);
    try testing.expect(screen.readCell(0, 1).?.default);
    // Body still paints at row header_rows = 2.
    try testing.expectEqualStrings("+", screen.readCell(0, 2).?.char.grapheme);
}

// ── decl_anchor / elided integration ────────────────────────────────────

/// Build a real file-wide BuildResult from two source strings so the tests
/// below exercise the same code paths the runtime uses (anchors emitted
/// by `file_view.zig`, gaps emitted by `elide.zig`).
fn buildFileViewForTest(
    fd: *const rv.FileDiff,
    state: *const AppState,
) !BuildResult {
    return file_view_mod.build(testing.allocator, fd, .unified, state);
}

/// Index of the first `.elided` row in a unified view, or null when the
/// view contains no elided rows (e.g. a tiny file with no gaps).
fn firstElidedRow(lines: []const StyledLine) ?usize {
    for (lines, 0..) |ln, i| if (ln.kind == .elided) return i;
    return null;
}

test "nextDeclRow / prevDeclRow: jump across decl rows in file-wide view" {
    // file_view.zig populates `decl_index` from each decl's representative
    // row — annotated `.source` for expanded decls, `.decl_anchor` for
    // collapsed ones — so the existing forward/backward walk should land
    // on those rows just like it does on `.decl_header` rows in the
    // decl-axis view.
    const before =
        \\pub fn a() void {}
        \\pub fn b() u32 { return 1; }
        \\pub fn c() void {}
    ;
    const after =
        \\pub fn a() void {}
        \\pub fn b() u32 { return 2; }
        \\pub fn c() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();
    var built = try buildFileViewForTest(&fd, &state);
    defer built.deinit();

    // Three decls → three navigable rows in the index.
    try testing.expectEqual(@as(usize, 3), built.decl_index.len);
    for (built.decl_index) |e| {
        const ln = built.view.unified[e.row];
        // Expanded decls are anchored on their first source row (which
        // carries the inline `(name, ts_kind)` annotation); collapsed
        // decls would be anchored on a `.decl_anchor` row instead.
        try testing.expectEqual(LineKind.source, ln.kind);
        try testing.expect(ln.decl_annotation != null);
    }

    // Forward walk visits each anchor in row order and wraps to the first.
    const r0 = built.decl_index[0].row;
    const r1 = built.decl_index[1].row;
    const r2 = built.decl_index[2].row;
    try testing.expectEqual(@as(?usize, r1), nextDeclRow(built.decl_index, r0, false));
    try testing.expectEqual(@as(?usize, r2), nextDeclRow(built.decl_index, r1, false));
    try testing.expectEqual(@as(?usize, r0), nextDeclRow(built.decl_index, r2, false));

    // Backward walk mirrors the forward case.
    try testing.expectEqual(@as(?usize, r1), prevDeclRow(built.decl_index, r2, false));
    try testing.expectEqual(@as(?usize, r0), prevDeclRow(built.decl_index, r1, false));
    try testing.expectEqual(@as(?usize, r2), prevDeclRow(built.decl_index, r0, false));
}

test "handleDiffPaneKey: space on `.elided` row toggles state.expanded_gaps" {
    // Long file with one tiny change in the middle so `elide.zig` emits
    // both leading and trailing `.elided` rows.
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

    var state = AppState.init(testing.allocator);
    defer state.deinit();
    var built = try buildFileViewForTest(&fd, &state);
    defer built.deinit();

    const elided_row = firstElidedRow(built.view.unified) orelse return error.MissingElided;
    const elided_gap = built.view.unified[elided_row].gap_id orelse return error.MissingGapId;
    state.cursor_y = elided_row;

    // Pre-condition: gap is collapsed (default state).
    try testing.expect(!state.isGapExpanded(elided_gap));

    var mode: Mode = .unified;
    try handleDiffPaneKey(testing.allocator, keyCp(vaxis.Key.space), &built, &fd, &state, &mode, 30, &file_view_mod.build);

    // Post-condition: gap is now expanded.
    try testing.expect(state.isGapExpanded(elided_gap));
}

test "handleDiffPaneKey: `[` clears state.expanded_gaps in addition to collapsing decls" {
    const before = "pub fn a() void {}\npub fn b() u32 { return 1; }\n";
    const after = "pub fn a() void {}\npub fn b() u32 { return 2; }\n";
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();

    // Pre-populate `expanded_gaps` with two arbitrary ids so we can verify
    // `[` empties the set even when the current view has no `.elided` rows
    // (decl-axis view via line_mod.build's rebuild, or any other reason).
    _ = try state.toggleGap(0xAA);
    _ = try state.toggleGap(0xBB);
    try testing.expectEqual(@as(usize, 2), state.expanded_gaps.count());

    var built = try buildFileViewForTest(&fd, &state);
    defer built.deinit();

    var mode: Mode = .unified;
    try handleDiffPaneKey(testing.allocator, keyCp('['), &built, &fd, &state, &mode, 30, &file_view_mod.build);

    // `expanded_gaps` is now empty and the changed decl is collapsed.
    try testing.expectEqual(@as(usize, 0), state.expanded_gaps.count());
    var any_collapsed = false;
    for (fd.entries) |e| if (e == .changed) {
        if (state.isCollapsed(line_mod.declId(e.changed.new))) any_collapsed = true;
    };
    try testing.expect(any_collapsed);
}

test "handleDiffPaneKey: `]` expands every gap currently in the view" {
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

    var state = AppState.init(testing.allocator);
    defer state.deinit();
    var built = try buildFileViewForTest(&fd, &state);
    defer built.deinit();

    // Collect every gap_id currently in the (collapsed) view.
    var gap_ids: std.ArrayList(GapId) = .empty;
    defer gap_ids.deinit(testing.allocator);
    for (built.view.unified) |ln| if (ln.kind == .elided) {
        if (ln.gap_id) |id| try gap_ids.append(testing.allocator, id);
    };
    try testing.expect(gap_ids.items.len >= 1);

    var mode: Mode = .unified;
    try handleDiffPaneKey(testing.allocator, keyCp(']'), &built, &fd, &state, &mode, 30, &file_view_mod.build);

    // Every gap that was in the original view is now flagged expanded.
    for (gap_ids.items) |id| try testing.expect(state.isGapExpanded(id));
}

test "toggleFocusedGap: cursor on non-elided row is a no-op" {
    // Cursor not on an elided row → `focusedGapId` returns null and the
    // helper short-circuits without touching state. Belt-and-suspenders
    // check so handleDiffPaneKey's dispatch can rely on the early exit.
    const before = "pub fn a() void {}\n";
    const after = "pub fn a() u32 { return 1; }\n";
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();
    var built = try buildFileViewForTest(&fd, &state);
    defer built.deinit();

    // Park the cursor on the changed decl's first source row — with the
    // inline annotation, that row replaces the old `.decl_anchor`
    // landmark and is the natural "on the decl" cursor position.
    state.cursor_y = 0;
    try testing.expectEqual(LineKind.source, built.view.unified[0].kind);
    try testing.expect(built.view.unified[0].decl_annotation != null);

    try toggleFocusedGap(testing.allocator, &built, &fd, &state, .unified, 30, &file_view_mod.build);
    try testing.expectEqual(@as(usize, 0), state.expanded_gaps.count());
}

// ── decl annotation rendering ────────────────────────────────────────────

test "drawDeclAnnotation: no-op when sl.decl_annotation is null" {
    // Render with no annotation; the cells past `text_col + text width`
    // must stay default (untouched).
    var screen = try vaxis.Screen.init(testing.allocator, .{
        .cols = 40,
        .rows = 4,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(testing.allocator);

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 4,
        .screen = &screen,
    };
    win.clear();

    const sl: StyledLine = .{
        .indent = 0,
        .marker = .unchanged,
        .kind = .source,
        .text = "hello",
        .decl_annotation = null,
    };
    drawDeclAnnotation(win, 0, 2, sl);

    // Every column on row 0 stays at the default (cleared) state.
    var col: u16 = 0;
    while (col < win.width) : (col += 1) {
        try testing.expect(screen.readCell(col, 0).?.default);
    }
}

test "drawDeclAnnotation: prints the annotation past the source text in dim style" {
    var screen = try vaxis.Screen.init(testing.allocator, .{
        .cols = 60,
        .rows = 4,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(testing.allocator);

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 60,
        .height = 4,
        .screen = &screen,
    };
    win.clear();

    const annotation = "(greet, function_declaration)";
    const sl: StyledLine = .{
        .indent = 0,
        .marker = .added,
        .kind = .source,
        .text = "pub fn greet() void {",
        .decl_annotation = annotation,
    };
    // text_col=2 (after gutter+space). text width=21. 2-cell gap.
    const text_col: u16 = 2;
    const expected_start: u16 = text_col + 21 + 2;
    drawDeclAnnotation(win, 0, text_col, sl);

    // First annotation char lands at the expected column with `dim`.
    const head = screen.readCell(expected_start, 0).?;
    try testing.expectEqualStrings("(", head.char.grapheme);
    try testing.expect(head.style.dim);

    // The cell just before the annotation stays default (the 2-cell gap).
    try testing.expect(screen.readCell(expected_start - 1, 0).?.default);
}

test "focusedDeclId: annotated source row reports its own decl_id without walking back" {
    // File-wide builder for an expanded decl: the first source row
    // carries both `decl_id` and `decl_annotation`. Cursor on that row
    // (or any source row beneath it) maps directly to the decl without
    // needing a separate `.decl_anchor` landmark.
    const id_a: DeclId = 0xA1;
    const id_b: DeclId = 0xB2;
    const lines = [_]StyledLine{
        .{
            .indent = 0,
            .marker = .added,
            .kind = .source,
            .text = "pub fn fresh() void {",
            .decl_id = id_a,
            .decl_annotation = "(fresh, function_declaration)",
        },
        .{
            .indent = 0,
            .marker = .added,
            .kind = .source,
            .text = "    return;",
            .decl_id = id_a,
        },
        .{
            .indent = 0,
            .marker = .changed,
            .kind = .source,
            .text = "pub fn other() u32 { return 1; }",
            .decl_id = id_b,
            .decl_annotation = "(other, function_declaration)",
        },
    };
    const view: View = .{ .unified = lines[0..] };

    try testing.expectEqual(@as(?DeclId, id_a), focusedDeclId(view, 0));
    try testing.expectEqual(@as(?DeclId, id_a), focusedDeclId(view, 1));
    try testing.expectEqual(@as(?DeclId, id_b), focusedDeclId(view, 2));
}

test "findDeclRow: lands on annotated source row for expanded decls, anchor row for collapsed" {
    const id_expanded: DeclId = 0xEE;
    const id_collapsed: DeclId = 0xCC;
    const lines = [_]StyledLine{
        // Expanded decl: first source row carries the annotation.
        .{
            .indent = 0,
            .marker = .added,
            .kind = .source,
            .text = "pub fn fresh() void {",
            .decl_id = id_expanded,
            .decl_annotation = "(fresh, function_declaration)",
        },
        .{
            .indent = 0,
            .marker = .added,
            .kind = .source,
            .text = "}",
            .decl_id = id_expanded,
        },
        // Collapsed decl: anchor row + synthetic elided body.
        .{
            .indent = 0,
            .marker = .changed,
            .kind = .decl_anchor,
            .text = "tweak  (function_declaration)",
            .decl_id = id_collapsed,
        },
        .{
            .indent = 0,
            .marker = .blank,
            .kind = .elided,
            .text = "\u{2026} body of tweak (1 lines) \u{2026}",
        },
    };
    const view: View = .{ .unified = lines[0..] };

    // Expanded: lands on the annotated source row, not a body row.
    try testing.expectEqual(@as(?usize, 0), findDeclRow(view, id_expanded));
    // Collapsed: lands on the anchor row, not the elided body.
    try testing.expectEqual(@as(?usize, 2), findDeclRow(view, id_collapsed));
}

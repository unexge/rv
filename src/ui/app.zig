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
//!   expands everything, `v` toggles split vs unified, q / Ctrl-C quit.
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
const line_mod = @import("line.zig");
const theme = @import("theme.zig");

const StyledLine = line_mod.StyledLine;
const LinePair = line_mod.LinePair;
const Marker = line_mod.Marker;
const LineKind = line_mod.LineKind;
const Mode = line_mod.Mode;
const View = line_mod.View;
const BuildResult = line_mod.BuildResult;
const AppState = line_mod.AppState;
const DeclId = line_mod.DeclId;

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
};

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
    var current = try line_mod.build(gpa, file_diff, mode, &state);
    defer current.deinit();

    // Stats are a property of the underlying FileDiff, not of the collapse
    // state or mode, so we format the legend exactly once.
    const stats_text = try std.fmt.allocPrint(
        la,
        " +{d}  -{d}  ~{d}  ={d}    (j/k: move, space: fold, [: fold all, ]: unfold, v: split, q: quit)",
        .{
            current.stats.added,
            current.stats.removed,
            current.stats.changed,
            current.stats.unchanged,
        },
    );

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

                if (key.matches('v', .{})) {
                    const anchor = focusedDeclId(current.view, state.cursor_y);
                    mode = if (mode == .unified) .split else .unified;
                    try rebuild(gpa, &current, file_diff, mode, &state);
                    relocateCursor(&state, current.view, anchor, viewport);
                } else if (key.matches(vaxis.Key.space, .{}) or key.matches(vaxis.Key.enter, .{})) {
                    if (focusedDeclId(current.view, state.cursor_y)) |id| {
                        _ = try state.toggle(id);
                        try rebuild(gpa, &current, file_diff, mode, &state);
                        relocateCursor(&state, current.view, id, viewport);
                    }
                } else if (key.matches('[', .{})) {
                    const anchor = focusedDeclId(current.view, state.cursor_y);
                    try state.collapseAll(file_diff);
                    try rebuild(gpa, &current, file_diff, mode, &state);
                    relocateCursor(&state, current.view, anchor, viewport);
                } else if (key.matches(']', .{})) {
                    const anchor = focusedDeclId(current.view, state.cursor_y);
                    state.expandAll();
                    try rebuild(gpa, &current, file_diff, mode, &state);
                    relocateCursor(&state, current.view, anchor, viewport);
                } else {
                    applyNavigationKey(&state, key, viewport, current.rowCount());
                }
            },
            .mouse => |m| applyMouse(&state, m, viewport, current.rowCount()),
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
        }

        const win = vx.window();
        win.clear();
        switch (mode) {
            .unified => drawUnified(win, current, &state, title, stats_text),
            .split => drawSplit(win, current, &state, before_path, after_path, stats_text),
        }

        try vx.render(tty.writer());
        try tty.writer().flush();
    }
}

fn rebuild(
    gpa: std.mem.Allocator,
    current: *BuildResult,
    file_diff: *const rv.FileDiff,
    mode: Mode,
    state: *const AppState,
) !void {
    // Build the replacement *before* freeing the old one so a mid-build
    // failure leaves `current` intact and the `defer current.deinit()` in
    // `run` still frees something valid.
    var next = try line_mod.build(gpa, file_diff, mode, state);
    current.deinit();
    current.* = next;
    next = undefined;
}

// ── layout constants ──────────────────────────────────────────────────────

const header_rows: u16 = 2; // path line + stats line

fn viewportHeight(win: vaxis.Window) u16 {
    return if (win.height > header_rows) win.height - header_rows else 0;
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
        if (lines[i].kind == .decl_header) {
            if (lines[i].decl_id) |id| return id;
        }
    }
    return null;
}

fn focusedDeclIdPairs(pairs: []const LinePair, cursor_y: usize) ?DeclId {
    if (pairs.len == 0) return null;
    var i: usize = @min(cursor_y, pairs.len - 1) + 1;
    while (i > 0) {
        i -= 1;
        if (pairs[i].headerSide()) |side| if (side.decl_id) |id| return id;
    }
    return null;
}

fn findDeclRow(view: View, id: DeclId) ?usize {
    return switch (view) {
        .unified => |lines| blk: {
            for (lines, 0..) |ln, i| {
                if (ln.kind != .decl_header) continue;
                if (ln.decl_id) |did| if (did == id) break :blk i;
            }
            break :blk null;
        },
        .split => |pairs| blk: {
            for (pairs, 0..) |p, i| {
                const side = p.headerSide() orelse continue;
                if (side.decl_id) |did| if (did == id) break :blk i;
            }
            break :blk null;
        },
    };
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

// ── draw: unified ──────────────────────────────────────────────────────────

fn drawUnified(
    win: vaxis.Window,
    built: BuildResult,
    state: *const AppState,
    title: []const u8,
    stats_text: []const u8,
) void {
    drawHeader(win, title, stats_text);

    const body = win.child(.{
        .y_off = header_rows,
        .height = viewportHeight(win),
    });

    const lines = built.view.unified;
    const end = @min(state.scroll_y + body.height, lines.len);
    var row: u16 = 0;
    var i: usize = state.scroll_y;
    while (i < end) : (i += 1) {
        drawLine(body, row, lines[i], i == state.cursor_y);
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

// ── draw: split ────────────────────────────────────────────────────────────

/// Column reserved for the vertical separator between panes.
const separator_cols: u16 = 1;

fn drawSplit(
    win: vaxis.Window,
    built: BuildResult,
    state: *const AppState,
    before_path: []const u8,
    after_path: []const u8,
    stats_text: []const u8,
) void {
    // Pane widths: integer split of the remaining columns after the separator.
    const total_w = win.width;
    if (total_w < 2) return;
    const usable = total_w - separator_cols;
    const left_w: u16 = usable / 2;
    const right_w: u16 = usable - left_w;
    const sep_col: u16 = left_w;

    const left_pane_header = win.child(.{ .x_off = 0, .y_off = 0, .width = left_w, .height = 1 });
    const right_pane_header = win.child(.{ .x_off = sep_col + separator_cols, .y_off = 0, .width = right_w, .height = 1 });

    _ = left_pane_header.print(&.{.{ .text = before_path, .style = .{ .bold = true } }}, .{ .wrap = .none });
    _ = right_pane_header.print(&.{.{ .text = after_path, .style = .{ .bold = true } }}, .{ .wrap = .none });

    _ = win.print(
        &.{.{ .text = stats_text, .style = .{ .dim = true } }},
        .{ .row_offset = 1, .wrap = .none },
    );

    const body_h = viewportHeight(win);
    const left_body = win.child(.{
        .x_off = 0,
        .y_off = header_rows,
        .width = left_w,
        .height = body_h,
    });
    const right_body = win.child(.{
        .x_off = sep_col + separator_cols,
        .y_off = header_rows,
        .width = right_w,
        .height = body_h,
    });

    // Vertical separator down the full window height.
    const sep: vaxis.Cell = .{
        .char = .{ .grapheme = "│", .width = 1 },
        .style = .{ .dim = true },
    };
    var r: u16 = 0;
    while (r < win.height) : (r += 1) {
        win.writeCell(sep_col, r, sep);
    }

    const pairs = built.view.split;
    const end = @min(state.scroll_y + body_h, pairs.len);
    var row: u16 = 0;
    var i: usize = state.scroll_y;
    while (i < end) : (i += 1) {
        const is_cursor = i == state.cursor_y;
        // Cursor marker is only drawn on the left pane so the right pane's
        // gutter stays readable.
        drawLine(left_body, row, pairs[i].left, is_cursor);
        drawLine(right_body, row, pairs[i].right, false);
        row += 1;
    }
}

// ── draw: shared ───────────────────────────────────────────────────────────

fn drawLine(body: vaxis.Window, row: u16, sl: StyledLine, cursor: bool) void {
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
fn styleFor(sl: StyledLine) vaxis.Style {
    const bold = sl.kind == .decl_header;
    const dim = sl.marker == .unchanged;
    return switch (sl.marker) {
        .added => .{ .fg = .{ .index = 2 }, .bold = bold },
        .removed => .{ .fg = .{ .index = 1 }, .bold = bold },
        .changed => .{ .fg = .{ .index = 3 }, .bold = bold },
        .unchanged => .{ .dim = dim, .bold = bold },
        .header => .{ .bold = true },
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
    try rebuild(testing.allocator, &current, &fd, .unified, &state);
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
    try rebuild(testing.allocator, &current, &fd, .unified, &state);
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
    try rebuild(testing.allocator, &current, &fd, .unified, &state);

    // Only headers remain.
    for (current.view.unified) |ln| try testing.expectEqual(LineKind.decl_header, ln.kind);
    try testing.expect(current.view.unified.len >= 2);

    state.expandAll();
    try rebuild(testing.allocator, &current, &fd, .unified, &state);

    var saw_source = false;
    for (current.view.unified) |ln| if (ln.kind == .source) {
        saw_source = true;
    };
    try testing.expect(saw_source);
}

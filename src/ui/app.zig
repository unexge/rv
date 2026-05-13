//! Vaxis-backed event loop and renderer for the diff view.
//!
//! The pure line-building logic is in `line.zig`; this module is responsible
//! for:
//!
//! - Setting up Tty + Vaxis + Loop
//! - Scroll state (single vertical offset shared across both panes in split
//!   mode)
//! - Key handling: arrows, PgUp/PgDn, Home/End, q, Ctrl-C, v (toggle view)
//! - Drawing the header strip and visible lines each frame in either the
//!   unified or side-by-side layout

const std = @import("std");
const vaxis = @import("vaxis");

const rv = @import("rv");
const line_mod = @import("line.zig");

const StyledLine = line_mod.StyledLine;
const LinePair = line_mod.LinePair;
const Marker = line_mod.Marker;
const LineKind = line_mod.LineKind;
const Mode = line_mod.Mode;

const Event = union(enum) {
    key_press: vaxis.Key,
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
    // Both views are built up front. Toggling `v` just swaps which one we
    // render; rebuilding on every keypress would throw away the current
    // scroll anchor and make `v` feel laggy for large files.
    var unified = try line_mod.build(gpa, file_diff, .unified);
    defer unified.deinit();
    var split = try line_mod.build(gpa, file_diff, .split);
    defer split.deinit();

    // Vaxis cells store grapheme bytes by *reference* into the caller's
    // segment text. Header strings must therefore outlive every render, so
    // we pre-format them into the same arena as the body lines.
    const u_arena = unified.arena.allocator();
    const pe_label: []const u8 = if (file_diff.parse_errors.len > 0) "  [parse errors]" else "";
    const title = try std.fmt.allocPrint(u_arena, "rv  {s}  →  {s}{s}", .{
        before_path, after_path, pe_label,
    });
    const stats_text = try std.fmt.allocPrint(
        u_arena,
        " +{d}  -{d}  ~{d}  ={d}    (arrows/PgUp/PgDn/Home/End, v: toggle split, q: quit)",
        .{
            unified.stats.added,
            unified.stats.removed,
            unified.stats.changed,
            unified.stats.unchanged,
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

    var mode: Mode = .unified;
    var scroll_y: usize = 0;

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) break;
                if (key.matches('q', .{})) break;
                if (key.matches('v', .{})) {
                    scroll_y = switchMode(&mode, scroll_y, unified, split);
                } else {
                    const total = switch (mode) {
                        .unified => unified.rowCount(),
                        .split => split.rowCount(),
                    };
                    scroll_y = applyScroll(scroll_y, key, viewportHeight(vx.window()), total);
                }
            },
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
        }

        const win = vx.window();
        win.clear();
        switch (mode) {
            .unified => drawUnified(win, unified, scroll_y, title, stats_text),
            .split => drawSplit(win, split, scroll_y, before_path, after_path, stats_text),
        }

        try vx.render(tty.writer());
        try tty.writer().flush();
    }
}

// ── scroll ─────────────────────────────────────────────────────────────────

const header_rows: u16 = 2; // path line + stats line

fn viewportHeight(win: vaxis.Window) u16 {
    return if (win.height > header_rows) win.height - header_rows else 0;
}

fn applyScroll(current: usize, key: vaxis.Key, viewport: u16, total: usize) usize {
    const max_scroll = if (total > viewport) total - viewport else 0;

    var next = current;
    if (key.matches(vaxis.Key.up, .{})) next -|= 1
    else if (key.matches(vaxis.Key.down, .{})) next +|= 1
    else if (key.matches(vaxis.Key.page_up, .{})) next -|= viewport
    else if (key.matches(vaxis.Key.page_down, .{})) next +|= viewport
    else if (key.matches(vaxis.Key.home, .{})) next = 0
    else if (key.matches(vaxis.Key.end, .{})) next = max_scroll;

    return @min(next, max_scroll);
}

// ── view toggle (`v`) ──────────────────────────────────────────────────────

/// Identity of the decl whose body the viewport is sitting in. Used as an
/// anchor when switching modes: rows don't map 1:1 (split pads blanks,
/// unified concatenates `-` then `+`), so we snap back to the enclosing
/// decl header.
const Anchor = struct {
    marker: Marker,
    indent: u8,
    text: []const u8,
};

fn switchMode(
    mode: *Mode,
    scroll_y: usize,
    unified: line_mod.BuildResult,
    split: line_mod.BuildResult,
) usize {
    const anchor = switch (mode.*) {
        .unified => findAnchorUnified(unified.view.unified, scroll_y),
        .split => findAnchorSplit(split.view.split, scroll_y),
    };

    mode.* = switch (mode.*) {
        .unified => .split,
        .split => .unified,
    };

    const new_total = switch (mode.*) {
        .unified => unified.rowCount(),
        .split => split.rowCount(),
    };

    if (anchor) |a| {
        if (switch (mode.*) {
            .unified => locateAnchorUnified(unified.view.unified, a),
            .split => locateAnchorSplit(split.view.split, a),
        }) |idx| return idx;
    }
    // No anchor found (scrolled past the last decl). Keep scroll but clamp
    // so the draw loop still has something to show.
    return @min(scroll_y, new_total -| 1);
}

// Both `findAnchor*` helpers scan *backward* from the viewport top so a user
// mid-body of a decl anchors onto that decl's header, not the next one below.

fn findAnchorUnified(lines: []const StyledLine, start: usize) ?Anchor {
    if (lines.len == 0) return null;
    var i: usize = @min(start, lines.len - 1) + 1;
    while (i > 0) {
        i -= 1;
        if (lines[i].kind == .decl_header) {
            return .{
                .marker = lines[i].marker,
                .indent = lines[i].indent,
                .text = lines[i].text,
            };
        }
    }
    return null;
}

fn findAnchorSplit(pairs: []const LinePair, start: usize) ?Anchor {
    if (pairs.len == 0) return null;
    var i: usize = @min(start, pairs.len - 1) + 1;
    while (i > 0) {
        i -= 1;
        if (pairs[i].headerSide()) |side| {
            return .{
                .marker = side.marker,
                .indent = side.indent,
                .text = side.text,
            };
        }
    }
    return null;
}

fn locateAnchorUnified(lines: []const StyledLine, a: Anchor) ?usize {
    for (lines, 0..) |ln, i| {
        if (ln.kind != .decl_header) continue;
        if (ln.marker == a.marker and ln.indent == a.indent and
            std.mem.eql(u8, ln.text, a.text)) return i;
    }
    return null;
}

fn locateAnchorSplit(pairs: []const LinePair, a: Anchor) ?usize {
    for (pairs, 0..) |p, i| {
        const side = p.headerSide() orelse continue;
        if (side.marker == a.marker and side.indent == a.indent and
            std.mem.eql(u8, side.text, a.text)) return i;
    }
    return null;
}

// ── draw: unified ──────────────────────────────────────────────────────────

fn drawUnified(
    win: vaxis.Window,
    built: line_mod.BuildResult,
    scroll_y: usize,
    title: []const u8,
    stats_text: []const u8,
) void {
    drawHeader(win, title, stats_text);

    const body = win.child(.{
        .y_off = header_rows,
        .height = viewportHeight(win),
    });

    const lines = built.view.unified;
    const end = @min(scroll_y + body.height, lines.len);
    var row: u16 = 0;
    var i: usize = scroll_y;
    while (i < end) : (i += 1) {
        drawLine(body, row, lines[i]);
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
    built: line_mod.BuildResult,
    scroll_y: usize,
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
    const end = @min(scroll_y + body_h, pairs.len);
    var row: u16 = 0;
    var i: usize = scroll_y;
    while (i < end) : (i += 1) {
        drawLine(left_body, row, pairs[i].left);
        drawLine(right_body, row, pairs[i].right);
        row += 1;
    }
}

// ── draw: shared ───────────────────────────────────────────────────────────

fn drawLine(body: vaxis.Window, row: u16, sl: StyledLine) void {
    if (sl.marker == .blank and sl.kind == .blank) return;

    const base_style = styleFor(sl);

    // Gutter: 1-char marker + space.
    _ = body.print(&.{.{
        .text = sl.marker.gutter(),
        .style = base_style,
    }}, .{ .row_offset = row, .col_offset = 0, .wrap = .none });

    // Indent columns (2 per level) start after the gutter + space.
    const indent_cols: u16 = @as(u16, @intCast(sl.indent)) * 2;
    const text_col: u16 = 2 + indent_cols;

    if (sl.novel_spans.len == 0) {
        _ = body.print(&.{.{
            .text = sl.text,
            .style = base_style,
        }}, .{ .row_offset = row, .col_offset = text_col, .wrap = .none });
        return;
    }

    // Novel-range highlighting (Option C): walk the sorted non-overlapping
    // spans and emit alternating base / novel segments. Column tracking is
    // byte-count based, which matches the ASCII-cell assumption elsewhere
    // in this renderer (tab expansion to spaces happens at build time).
    const novel_style = novelStyleFor(base_style);
    var cursor: usize = 0;
    var col: u16 = text_col;
    for (sl.novel_spans) |s| {
        if (s.start > cursor) {
            const seg = sl.text[cursor..s.start];
            _ = body.print(&.{.{ .text = seg, .style = base_style }}, .{
                .row_offset = row,
                .col_offset = col,
                .wrap = .none,
            });
            col += @intCast(seg.len);
        }
        if (s.end > s.start) {
            const seg = sl.text[s.start..s.end];
            _ = body.print(&.{.{ .text = seg, .style = novel_style }}, .{
                .row_offset = row,
                .col_offset = col,
                .wrap = .none,
            });
            col += @intCast(seg.len);
        }
        cursor = s.end;
    }
    if (cursor < sl.text.len) {
        const tail = sl.text[cursor..];
        _ = body.print(&.{.{ .text = tail, .style = base_style }}, .{
            .row_offset = row,
            .col_offset = col,
            .wrap = .none,
        });
    }
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

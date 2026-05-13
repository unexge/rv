//! Vaxis-backed event loop and renderer for the unified diff view.
//!
//! The pure line-building logic is in `line.zig`; this module is responsible
//! for:
//!
//! - Setting up Tty + Vaxis + Loop
//! - Scroll state (single vertical offset)
//! - Key handling: arrows, PgUp/PgDn, Home/End, q, Ctrl-C
//! - Drawing the header strip and visible lines each frame

const std = @import("std");
const vaxis = @import("vaxis");

const rv = @import("rv");
const line_mod = @import("line.zig");

const StyledLine = line_mod.StyledLine;
const Marker = line_mod.Marker;
const LineKind = line_mod.LineKind;

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
    var built = try line_mod.build(gpa, file_diff);
    defer built.deinit();

    // Vaxis cells store grapheme bytes by *reference* into the caller's
    // segment text. Header strings must therefore outlive every render, so
    // we pre-format them into the same arena as the body lines.
    const arena = built.arena.allocator();
    const pe_label: []const u8 = if (file_diff.parse_errors.len > 0) "  [parse errors]" else "";
    const title = try std.fmt.allocPrint(arena, "rv  {s}  →  {s}{s}", .{
        before_path, after_path, pe_label,
    });
    const stats_text = try std.fmt.allocPrint(
        arena,
        " +{d}  -{d}  ~{d}  ={d}    (arrows/PgUp/PgDn/Home/End, q: quit)",
        .{
            built.stats.added,
            built.stats.removed,
            built.stats.changed,
            built.stats.unchanged,
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

    var scroll_y: usize = 0;

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) break;
                if (key.matches('q', .{})) break;
                scroll_y = applyScroll(scroll_y, key, viewportHeight(vx.window()), built.lines.len);
            },
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
        }

        const win = vx.window();
        win.clear();
        drawFrame(win, built, scroll_y, title, stats_text);

        try vx.render(tty.writer());
        try tty.writer().flush();
    }
}

// ── scroll ─────────────────────────────────────────────────────────────────

const header_rows: u16 = 2; // file/path line + stats line

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

// ── draw ───────────────────────────────────────────────────────────────────

fn drawFrame(
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

    const end = @min(scroll_y + body.height, built.lines.len);
    var row: u16 = 0;
    var i: usize = scroll_y;
    while (i < end) : (i += 1) {
        drawLine(body, row, built.lines[i]);
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

fn drawLine(body: vaxis.Window, row: u16, sl: StyledLine) void {
    const style = styleFor(sl);

    // Gutter: 1-char marker + space.
    _ = body.print(&.{.{
        .text = sl.marker.gutter(),
        .style = style,
    }}, .{ .row_offset = row, .col_offset = 0, .wrap = .none });

    // Indent columns (2 per level) start after the gutter + space.
    const indent_cols: u16 = @as(u16, @intCast(sl.indent)) * 2;
    const text_col: u16 = 2 + indent_cols;

    _ = body.print(&.{.{
        .text = sl.text,
        .style = style,
    }}, .{ .row_offset = row, .col_offset = text_col, .wrap = .none });
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

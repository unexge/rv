//! Sidebar pane for the repo-mode UI: pure presentation of a list of
//! changed files. Owns only the cursor / scroll state plus one `draw`
//! function. No I/O, no engine or git calls — `session.zig` wires the
//! entries in and ticks the cursor.
//!
//! Row layout (single line, truncated to the window's width):
//!
//!     <marker> <path> <stat>
//!
//! - `marker`: `~` modified, `+` added, `-` deleted, `R` renamed,
//!   `×` binary, `?` unsupported.
//! - `path`: `new_path` for modified / added / binary / unsupported,
//!   `old_path` for deleted, `old → new` for renamed.
//! - `stat`: if `summary` is set → `<a>+ <r>- <c>~` (zero counts
//!   omitted). Else `+<added> -<removed>` from `line_stat` for text
//!   files. Else `(binary)` / `(unsupported)`.
//!
//! The row under `cursor` renders with reverse video; the header line
//! reads `Files (<n>)`, bold when `focused`, dim otherwise.

const std = @import("std");
const vaxis = @import("vaxis");
const vcs = @import("../vcs/mod.zig");

pub const DeclSummary = struct {
    added: u32,
    removed: u32,
    changed: u32,
};

pub const Entry = struct {
    change: vcs.FileChange,
    summary: ?DeclSummary,
};

/// Sidebar state. `entries` is borrowed — the owner (session) is
/// responsible for the slice's lifetime and for keeping `cursor` /
/// `scroll` inside it when the list is replaced.
pub const ListState = struct {
    entries: []Entry,
    cursor: usize = 0,
    scroll: usize = 0,

    /// `&entries[cursor]` when the list is non-empty, else null.
    pub fn selected(self: *const ListState) ?*Entry {
        if (self.entries.len == 0) return null;
        return &self.entries[self.cursor];
    }

    /// Move the cursor one row up (clamped at 0) and nudge `scroll`
    /// just enough to keep the cursor inside `[scroll, scroll + viewport)`.
    /// No-op on an empty list.
    pub fn moveUp(self: *ListState, viewport: u16) void {
        if (self.entries.len == 0) return;
        self.cursor -|= 1;
        followCursor(self, viewport);
    }

    /// Move the cursor one row down (clamped at `entries.len - 1`) and
    /// nudge `scroll`. No-op on an empty list.
    pub fn moveDown(self: *ListState, viewport: u16) void {
        if (self.entries.len == 0) return;
        const last = self.entries.len - 1;
        self.cursor = @min(self.cursor + 1, last);
        followCursor(self, viewport);
    }
};

fn followCursor(state: *ListState, viewport: u16) void {
    if (state.cursor < state.scroll) {
        state.scroll = state.cursor;
    } else if (viewport > 0 and state.cursor >= state.scroll + viewport) {
        state.scroll = state.cursor - viewport + 1;
    }
    const total = state.entries.len;
    const max_scroll = if (total > viewport) total - viewport else 0;
    state.scroll = @min(state.scroll, max_scroll);
}

// ── drawing ───────────────────────────────────────────────────────────────

const header_rows: u16 = 1;

/// `arena` must remain alive through the frame's render call because vaxis
/// stores formatted grapheme slices by reference.
pub fn draw(
    win: vaxis.Window,
    state: *const ListState,
    focused: bool,
    arena: std.mem.Allocator,
) !void {
    if (win.width == 0 or win.height == 0) return;

    const header_text = try std.fmt.allocPrint(arena, "Files ({d})", .{state.entries.len});
    const header_style: vaxis.Style = if (focused)
        .{ .bold = true }
    else
        .{ .dim = true };
    _ = win.print(&.{.{ .text = header_text, .style = header_style }}, .{
        .row_offset = 0,
        .wrap = .none,
    });

    if (win.height <= header_rows) return;
    const body_h: u16 = win.height - header_rows;
    const end = @min(state.scroll + body_h, state.entries.len);

    var row: u16 = 0;
    var i: usize = state.scroll;
    while (i < end) : (i += 1) {
        try drawRow(
            win,
            header_rows + row,
            state.entries[i],
            i == state.cursor,
            focused,
            arena,
        );
        row += 1;
    }
}

fn drawRow(
    win: vaxis.Window,
    row: u16,
    entry: Entry,
    selected_row: bool,
    focused: bool,
    a: std.mem.Allocator,
) !void {
    const text = try formatRow(a, entry);
    const base: vaxis.Style = if (selected_row) .{ .reverse = true } else .{};
    const style = dimUnlessFocused(base, focused);

    const result = win.print(&.{.{ .text = text, .style = style }}, .{
        .row_offset = row,
        .wrap = .none,
    });

    // Extend the reverse-video bar to the full sidebar width so the
    // selection reads as a bar rather than just coloured text.
    if (selected_row and result.col < win.width) {
        const pad: vaxis.Cell = .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style,
        };
        var col: u16 = result.col;
        while (col < win.width) : (col += 1) {
            win.writeCell(col, row, pad);
        }
    }
}

/// OR `.dim = true` into `style` when `focused` is false; identity
/// otherwise. Mirrors `app.dimUnlessFocused` so the sidebar matches the
/// diff pane's focus shading.
fn dimUnlessFocused(style: vaxis.Style, focused: bool) vaxis.Style {
    if (focused) return style;
    var s = style;
    s.dim = true;
    return s;
}

fn formatRow(a: std.mem.Allocator, entry: Entry) ![]u8 {
    const marker = markerFor(entry.change.kind);
    const path = try formatPath(a, entry.change);
    const stat = try formatStat(a, entry);
    if (stat.len == 0) return std.fmt.allocPrint(a, "{s} {s}", .{ marker, path });
    return std.fmt.allocPrint(a, "{s} {s} {s}", .{ marker, path, stat });
}

fn markerFor(kind: vcs.ChangeKind) []const u8 {
    return switch (kind) {
        .modified => "~",
        .added => "+",
        .deleted => "-",
        .renamed => "R",
        .binary => "×",
        .unsupported => "?",
        .unavailable => "!",
    };
}

fn formatPath(a: std.mem.Allocator, change: vcs.FileChange) ![]u8 {
    return switch (change.kind) {
        .deleted => a.dupe(u8, change.old_path orelse ""),
        .renamed => std.fmt.allocPrint(a, "{s} → {s}", .{
            change.old_path orelse "",
            change.new_path orelse "",
        }),
        // modified / added / binary / unsupported all prefer new_path; fall
        // back to old_path if for some reason new_path is null.
        else => a.dupe(u8, change.new_path orelse change.old_path orelse ""),
    };
}

fn formatStat(a: std.mem.Allocator, entry: Entry) ![]u8 {
    if (entry.summary) |s| return formatSummary(a, s);
    return switch (entry.change.kind) {
        .binary => a.dupe(u8, "(binary)"),
        .unsupported => a.dupe(u8, "(unsupported)"),
        .unavailable => a.dupe(u8, "(unavailable)"),
        else => std.fmt.allocPrint(a, "+{d} -{d}", .{
            entry.change.line_stat.added,
            entry.change.line_stat.removed,
        }),
    };
}

fn formatSummary(a: std.mem.Allocator, s: DeclSummary) ![]u8 {
    // "<a>+ <r>- <c>~" with zero counts omitted. If every count is zero
    // the stat collapses to an empty string and `formatRow` drops the
    // trailing space.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    if (s.added > 0) try out.print(a, "{d}+", .{s.added});
    if (s.removed > 0) {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.print(a, "{d}-", .{s.removed});
    }
    if (s.changed > 0) {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.print(a, "{d}~", .{s.changed});
    }
    return out.toOwnedSlice(a);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn entryOf(kind: vcs.ChangeKind, path: []const u8, added: u32, removed: u32) Entry {
    return .{
        .change = .{
            .kind = kind,
            .old_path = if (kind == .added) null else path,
            .new_path = if (kind == .deleted) null else path,
            .line_stat = .{ .added = added, .removed = removed },
        },
        .summary = null,
    };
}

test "selected: empty list returns null" {
    var entries = [_]Entry{};
    const state: ListState = .{ .entries = entries[0..] };
    try testing.expect(state.selected() == null);
}

test "selected: returns pointer at cursor" {
    var entries = [_]Entry{
        entryOf(.modified, "a.zig", 0, 0),
        entryOf(.modified, "b.zig", 0, 0),
        entryOf(.modified, "c.zig", 0, 0),
    };
    const state: ListState = .{ .entries = entries[0..], .cursor = 2 };
    const sel = state.selected().?;
    try testing.expectEqualStrings("c.zig", sel.change.new_path.?);
}

test "moveUp / moveDown: no-op on empty list" {
    var entries = [_]Entry{};
    var state: ListState = .{ .entries = entries[0..], .cursor = 0, .scroll = 0 };
    state.moveUp(10);
    state.moveDown(10);
    try testing.expectEqual(@as(usize, 0), state.cursor);
    try testing.expectEqual(@as(usize, 0), state.scroll);
    try testing.expect(state.selected() == null);
}

test "moveDown: clamps at entries.len - 1" {
    var entries = [_]Entry{
        entryOf(.modified, "a.zig", 0, 0),
        entryOf(.modified, "b.zig", 0, 0),
        entryOf(.modified, "c.zig", 0, 0),
    };
    var state: ListState = .{ .entries = entries[0..] };
    var i: usize = 0;
    while (i < 10) : (i += 1) state.moveDown(10);
    try testing.expectEqual(@as(usize, 2), state.cursor);
}

test "moveUp: clamps at 0" {
    var entries = [_]Entry{
        entryOf(.modified, "a.zig", 0, 0),
        entryOf(.modified, "b.zig", 0, 0),
    };
    var state: ListState = .{ .entries = entries[0..], .cursor = 0 };
    state.moveUp(10);
    try testing.expectEqual(@as(usize, 0), state.cursor);
    try testing.expectEqual(@as(usize, 0), state.scroll);
}

test "moveDown: scroll follows cursor past viewport" {
    var entries: [5]Entry = undefined;
    for (&entries) |*e| e.* = entryOf(.modified, "x.zig", 0, 0);
    var state: ListState = .{ .entries = entries[0..], .cursor = 2 };

    // Viewport=3, cursor=2 is still in [0, 3); moving down to 3 forces
    // scroll to 1 so the cursor stays inside the viewport.
    state.moveDown(3);
    try testing.expectEqual(@as(usize, 3), state.cursor);
    try testing.expectEqual(@as(usize, 1), state.scroll);

    state.moveDown(3);
    try testing.expectEqual(@as(usize, 4), state.cursor);
    try testing.expectEqual(@as(usize, 2), state.scroll);
}

test "moveUp: scroll follows cursor back up" {
    var entries: [5]Entry = undefined;
    for (&entries) |*e| e.* = entryOf(.modified, "x.zig", 0, 0);
    var state: ListState = .{ .entries = entries[0..], .cursor = 4, .scroll = 2 };

    // Viewport=3, cursor=4 → scroll=2 (visible). Moving up to 3 keeps
    // scroll at 2; moving to 1 pulls scroll to 1.
    state.moveUp(3);
    try testing.expectEqual(@as(usize, 3), state.cursor);
    try testing.expectEqual(@as(usize, 2), state.scroll);

    state.moveUp(3);
    state.moveUp(3);
    try testing.expectEqual(@as(usize, 1), state.cursor);
    try testing.expectEqual(@as(usize, 1), state.scroll);
}

test "selected: reflects cursor after movement" {
    var entries = [_]Entry{
        entryOf(.modified, "a.zig", 0, 0),
        entryOf(.modified, "b.zig", 0, 0),
        entryOf(.modified, "c.zig", 0, 0),
    };
    var state: ListState = .{ .entries = entries[0..] };
    state.moveDown(10);
    state.moveDown(10);
    try testing.expectEqualStrings("c.zig", state.selected().?.change.new_path.?);
    state.moveUp(10);
    try testing.expectEqualStrings("b.zig", state.selected().?.change.new_path.?);
}

// `formatRow` allocates intermediate path / stat slices that only the
// final string references; in production the caller-supplied allocator is
// a FixedBufferAllocator over the module's scratch buffer, so those
// intermediates are freed when the FBA resets on the next draw. Tests
// using the general-purpose allocator need an arena to mirror that
// reset-the-world lifetime.
fn expectRow(entry: Entry, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try formatRow(arena.allocator(), entry);
    try testing.expectEqualStrings(expected, got);
}

test "formatRow: modified uses new_path + line_stat" {
    try expectRow(entryOf(.modified, "src/a.zig", 3, 1), "~ src/a.zig +3 -1");
}

test "formatRow: added uses new_path" {
    try expectRow(entryOf(.added, "src/new.zig", 42, 0), "+ src/new.zig +42 -0");
}

test "formatRow: deleted uses old_path" {
    try expectRow(entryOf(.deleted, "src/gone.zig", 0, 7), "- src/gone.zig +0 -7");
}

test "formatRow: renamed uses old → new" {
    const change: vcs.FileChange = .{
        .kind = .renamed,
        .old_path = "old.zig",
        .new_path = "new.zig",
        .line_stat = .{ .added = 0, .removed = 0 },
    };
    try expectRow(.{ .change = change, .summary = null }, "R old.zig → new.zig +0 -0");
}

test "formatRow: binary and unsupported use placeholder stats" {
    try expectRow(entryOf(.binary, "img.png", 0, 0), "× img.png (binary)");
    try expectRow(entryOf(.unsupported, "notes.xyz", 0, 0), "? notes.xyz (unsupported)");
}

test "formatRow: summary overrides line_stat, zero counts omitted" {
    var e = entryOf(.modified, "a.zig", 99, 99);
    e.summary = .{ .added = 2, .removed = 0, .changed = 1 };
    try expectRow(e, "~ a.zig 2+ 1~");
}

test "formatRow: summary with all-zero counts collapses stat" {
    var e = entryOf(.modified, "a.zig", 5, 5);
    e.summary = .{ .added = 0, .removed = 0, .changed = 0 };
    try expectRow(e, "~ a.zig");
}

//! Multi-file repo-mode session.
//!
//! Enumerates changed files via `vcs.Repo`, renders a sidebar on the
//! left with the diff pane (reused from `ui/app.zig`) on the right, and
//! lazy-loads each file's `FileDiff` on first visit. Per-file
//! `AppState` lives inside `FileState` so scroll / cursor / collapse
//! state persists across file switches.
//!
//! Layout:
//!
//!     ┌────────────┬────────────────────────────────────┐
//!     │ Files (n)  │ header                             │
//!     │ ~ a.zig    │ ────────────────────────────────── │
//!     │ + b.zig    │ diff body                          │
//!     │ - c.zig    │                                    │
//!     └────────────┴────────────────────────────────────┘
//!
//! The sidebar width is `min(40, (width * 3) / 10)`. A 1-col vertical
//! separator sits between the two panes. Focus starts on the sidebar;
//! `Tab` cycles between sidebar and diff pane.

const std = @import("std");
const vaxis = @import("vaxis");

const rv = @import("rv");
const vcs = @import("../vcs/mod.zig");

const app = @import("app.zig");
const file_list = @import("file_list.zig");
const line_mod = @import("line.zig");

const Allocator = std.mem.Allocator;

pub const Focus = enum { file_list, diff };

pub const SummaryDirection = enum { added, removed };

/// Classified, draw-ready view of the currently-selected file. Values
/// are valid until the next `currentView` call.
pub const PaneView = union(enum) {
    diff: *const rv.FileDiff,
    summary: struct { diff: *const rv.FileDiff, direction: SummaryDirection },
    /// Placeholder text for binary / unsupported files.
    placeholder: []const u8,
};

/// Per-file lazy cache. `diff` is `null` until `ensureLoaded` runs (and
/// stays `null` forever for binary / unsupported entries). `old_source`
/// / `new_source` back the borrowed slices inside `diff` and must
/// outlive it.
pub const FileState = struct {
    diff: ?rv.FileDiff,
    old_source: ?[]u8,
    new_source: ?[]u8,
    app_state: line_mod.AppState,

    pub fn deinit(self: *FileState, gpa: Allocator) void {
        if (self.diff) |*d| d.deinit();
        if (self.old_source) |s| gpa.free(s);
        if (self.new_source) |s| gpa.free(s);
        self.app_state.deinit();
    }
};

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    repo: vcs.Repo,
    /// Parallel to `states`. Owned by the session.
    entries: []file_list.Entry,
    states: []FileState,
    list: file_list.ListState,
    focus: Focus,
    mode: line_mod.Mode,
    /// Scratch buffer for short-lived placeholder strings returned by
    /// `currentView` (e.g. `"No language support for .xyz"`).
    /// Overwritten on every call; callers must not hold the slice
    /// across frames.
    scratch: [128]u8,

    /// Discover the enclosing git repo and enumerate its changed files.
    /// No file contents are read; `ensureLoaded` pulls those in lazily.
    pub fn init(gpa: Allocator, io: std.Io) !Session {
        var repo = try vcs.Repo.discover(gpa, io);
        errdefer repo.deinit();

        const changes = try repo.listChanges();

        const entries = try gpa.alloc(file_list.Entry, changes.len);
        errdefer gpa.free(entries);

        const states = try gpa.alloc(FileState, changes.len);
        errdefer gpa.free(states);

        for (changes, 0..) |c, i| {
            entries[i] = .{ .change = c, .summary = null };
            states[i] = .{
                .diff = null,
                .old_source = null,
                .new_source = null,
                .app_state = line_mod.AppState.init(gpa),
            };
        }

        return .{
            .gpa = gpa,
            .io = io,
            .repo = repo,
            .entries = entries,
            .states = states,
            .list = .{ .entries = entries },
            .focus = .file_list,
            .mode = .unified,
            .scratch = undefined,
        };
    }

    pub fn deinit(self: *Session) void {
        for (self.states) |*s| s.deinit(self.gpa);
        self.gpa.free(self.states);
        self.gpa.free(self.entries);
        self.repo.deinit();
    }

    /// Idempotent: load `HEAD` + worktree bytes for `idx`, diff them,
    /// and store the result on `states[idx]`. No-op once loaded, or for
    /// binary / unsupported entries.
    ///
    /// Also populates `entries[idx].summary` from the freshly-built
    /// `FileDiff` so the sidebar can show decl-level counts after the
    /// first visit.
    ///
    /// For `.added` / `.deleted` entries the per-file `AppState` is
    /// pre-collapsed so the summary view opens with every decl folded
    /// to a single header line; users can still expand individual decls
    /// with space/enter afterwards.
    pub fn ensureLoaded(self: *Session, idx: usize) !void {
        if (idx >= self.entries.len) return;
        const entry = &self.entries[idx];
        const state = &self.states[idx];

        if (state.diff != null) return;
        switch (entry.change.kind) {
            .binary, .unsupported => return,
            else => {},
        }

        const probe_path = entry.change.new_path orelse entry.change.old_path orelse return;
        const lang = rv.languageFromPath(probe_path) orelse return;

        const old_bytes: []u8 = if (entry.change.old_path != null)
            try self.repo.loadOld(self.gpa, entry.change)
        else
            try self.gpa.alloc(u8, 0);
        errdefer self.gpa.free(old_bytes);

        const new_bytes: []u8 = if (entry.change.new_path != null)
            try self.repo.loadNew(self.gpa, entry.change)
        else
            try self.gpa.alloc(u8, 0);
        errdefer self.gpa.free(new_bytes);

        var fd = try rv.diffSources(self.gpa, lang, old_bytes, new_bytes);
        errdefer fd.deinit();

        switch (entry.change.kind) {
            .added, .deleted => try state.app_state.collapseAll(&fd),
            else => {},
        }

        state.old_source = old_bytes;
        state.new_source = new_bytes;
        state.diff = fd;
        entry.summary = summarize(fd.entries);
    }

    /// Ensure the current selection is loaded, then classify it into a
    /// `PaneView` variant. Returned `.placeholder` slices live in
    /// `self.scratch` and are only valid until the next call.
    pub fn currentView(self: *Session) !PaneView {
        if (self.entries.len == 0) return .{ .placeholder = "no changes" };
        const idx = self.list.cursor;
        try self.ensureLoaded(idx);
        return self.classify(idx);
    }

    fn classify(self: *Session, idx: usize) PaneView {
        const entry = self.entries[idx];
        const state = &self.states[idx];

        return switch (entry.change.kind) {
            .binary => .{ .placeholder = "Binary file, not shown" },
            .unsupported => .{ .placeholder = self.unsupportedMessage(entry.change) },
            .modified, .renamed => if (state.diff) |*d|
                .{ .diff = d }
            else
                .{ .placeholder = "failed to load" },
            .added => if (state.diff) |*d|
                .{ .summary = .{ .diff = d, .direction = .added } }
            else
                .{ .placeholder = "failed to load" },
            .deleted => if (state.diff) |*d|
                .{ .summary = .{ .diff = d, .direction = .removed } }
            else
                .{ .placeholder = "failed to load" },
        };
    }

    fn unsupportedMessage(self: *Session, change: vcs.FileChange) []const u8 {
        const path = change.new_path orelse change.old_path orelse "";
        const ext = std.fs.path.extension(path);
        const msg = std.fmt.bufPrint(&self.scratch, "No language support for {s}", .{ext}) catch
            return "No language support";
        return msg;
    }
};

/// Count top-level variants of `entries` into a sidebar `DeclSummary`.
/// Nested containers are deliberately not recursed; the sidebar shows a
/// file-level summary, not a full tree.
fn summarize(entries: []const rv.DeclDiff) file_list.DeclSummary {
    var s: file_list.DeclSummary = .{ .added = 0, .removed = 0, .changed = 0 };
    for (entries) |e| switch (e) {
        .unchanged => {},
        .added => s.added += 1,
        .removed => s.removed += 1,
        .changed => s.changed += 1,
    };
    return s;
}

// ── event loop ────────────────────────────────────────────────────────────

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
};

/// Run the multi-file session to completion. Returns when the user
/// quits (`q` / Ctrl-C).
pub fn run(
    gpa: Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    session: *Session,
) !void {
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
    try vx.setMouseMode(tty.writer(), true);

    // The diff-pane BuildResult is rebuilt whenever the selected file
    // changes, or whenever `handleDiffPaneKey` toggles collapse/mode.
    // Keeping it between frames avoids re-walking the FileDiff on every
    // arrow-key tick.
    var built: ?line_mod.BuildResult = null;
    defer if (built) |*b| b.deinit();
    var built_idx: usize = std.math.maxInt(usize);

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) break;
                if (key.matches('q', .{})) break;
                if (key.matches(vaxis.Key.tab, .{})) {
                    session.focus = switch (session.focus) {
                        .file_list => .diff,
                        .diff => .file_list,
                    };
                    continue;
                }
                const height = vx.window().height;
                switch (session.focus) {
                    .file_list => handleListKey(session, key, listBodyHeight(height)),
                    .diff => try handleDiffKey(
                        gpa,
                        session,
                        key,
                        &built,
                        built_idx,
                        paneBodyHeight(height),
                    ),
                }
            },
            .mouse => {}, // mouse support for the session UI is deferred
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
        }

        // Selection may have moved; drop the stale build.
        const idx = session.list.cursor;
        if (idx != built_idx) {
            if (built) |*b| b.deinit();
            built = null;
            built_idx = idx;
        }

        const view = try session.currentView();

        // `.placeholder` panes render a single line of static text, so
        // there's nothing to build; skipping the build also means
        // `handleDiffKey` short-circuits on those selections (see the
        // `built.* == null` guard) and diff-pane keys can't mutate
        // invisible cursor state behind a placeholder.
        //
        // `.summary` reuses the standard diff renderer (with every decl
        // pre-collapsed in `ensureLoaded`), so it builds like `.diff`.
        if (built == null) {
            const fd: ?*const rv.FileDiff = switch (view) {
                .diff => |d| d,
                .summary => |s| s.diff,
                .placeholder => null,
            };
            if (fd) |d| built = try line_mod.build(
                gpa,
                d,
                session.mode,
                &session.states[idx].app_state,
            );
        }

        // Per-frame arena for title / stats strings. vaxis copies
        // graphemes into InternalScreen during render, so the slices
        // only need to survive the upcoming render+flush.
        var frame_arena: std.heap.ArenaAllocator = .init(gpa);
        defer frame_arena.deinit();

        // Fetch the window *after* the event switch so a `.winsize`
        // event's resize is reflected in this frame's geometry.
        const win = vx.window();
        const layout = paneLayout(win.width);
        win.clear();
        try draw(session, win, layout, view, built, frame_arena.allocator());

        try vx.render(tty.writer());
        try tty.writer().flush();
    }
}

fn handleListKey(session: *Session, key: vaxis.Key, viewport: u16) void {
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        session.list.moveDown(viewport);
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        session.list.moveUp(viewport);
    } else if (key.matches(vaxis.Key.enter, .{}) or
        key.matches(vaxis.Key.right, .{}) or
        key.matches('l', .{}))
    {
        session.focus = .diff;
    }
}

fn handleDiffKey(
    gpa: Allocator,
    session: *Session,
    key: vaxis.Key,
    built: *?line_mod.BuildResult,
    built_idx: usize,
    viewport: u16,
) !void {
    if (key.matches(vaxis.Key.left, .{}) or
        key.matches('h', .{}) or
        key.matches(vaxis.Key.escape, .{}))
    {
        session.focus = .file_list;
        return;
    }
    // `handleDiffPaneKey` needs a live BuildResult + FileDiff, which we
    // only have for `.diff` / `.summary` selections. Placeholder panes
    // swallow diff keys.
    if (built.* == null) return;
    const idx = built_idx;
    const state = &session.states[idx];
    const fd = if (state.diff) |*d| d else return;
    try app.handleDiffPaneKey(
        gpa,
        key,
        &built.*.?,
        fd,
        &state.app_state,
        &session.mode,
        viewport,
    );
}

// ── layout ────────────────────────────────────────────────────────────────

const separator_cols: u16 = 1;
const sidebar_header_rows: u16 = 1;
const pane_header_rows: u16 = 2;

const Layout = struct {
    sidebar_w: u16,
    sep_col: u16,
    pane_x: u16,
    pane_w: u16,
};

fn paneLayout(total_w: u16) Layout {
    // Sidebar width = min(40, (total * 3) / 10). Pinned to at least 1
    // column so a really narrow terminal still renders *something*
    // sensible on each side.
    const raw: u16 = @min(40, (total_w * 3) / 10);
    const sidebar_w: u16 = if (raw == 0) 1 else raw;
    const sep_col = sidebar_w;
    const pane_x = sidebar_w + separator_cols;
    const pane_w: u16 = if (total_w > pane_x) total_w - pane_x else 0;
    return .{
        .sidebar_w = sidebar_w,
        .sep_col = sep_col,
        .pane_x = pane_x,
        .pane_w = pane_w,
    };
}

fn listBodyHeight(total_h: u16) u16 {
    return if (total_h > sidebar_header_rows) total_h - sidebar_header_rows else 0;
}

fn paneBodyHeight(total_h: u16) u16 {
    return if (total_h > pane_header_rows) total_h - pane_header_rows else 0;
}

// ── drawing ───────────────────────────────────────────────────────────────

fn draw(
    session: *Session,
    win: vaxis.Window,
    layout: Layout,
    view: PaneView,
    built: ?line_mod.BuildResult,
    frame_alloc: Allocator,
) !void {
    const sidebar = win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = layout.sidebar_w,
        .height = win.height,
    });
    file_list.draw(sidebar, &session.list, session.focus == .file_list);

    drawSeparator(win, layout);

    const pane_size: app.PaneSize = .{
        .x_off = layout.pane_x,
        .y_off = 0,
        .width = layout.pane_w,
        .height = win.height,
    };
    try drawRightPane(session, win, pane_size, view, built, frame_alloc);
}

fn drawSeparator(win: vaxis.Window, layout: Layout) void {
    const sep: vaxis.Cell = .{
        .char = .{ .grapheme = "│", .width = 1 },
        .style = .{ .dim = true },
    };
    var r: u16 = 0;
    while (r < win.height) : (r += 1) win.writeCell(layout.sep_col, r, sep);
}

fn drawRightPane(
    session: *Session,
    win: vaxis.Window,
    pane_size: app.PaneSize,
    view: PaneView,
    built: ?line_mod.BuildResult,
    frame_alloc: Allocator,
) !void {
    if (pane_size.width == 0) return;
    switch (view) {
        .diff => {
            const b = built orelse return;
            const idx = session.list.cursor;
            const header = try fileHeader(frame_alloc, session.entries[idx], b);
            app.drawDiffPane(
                win,
                pane_size,
                b,
                &session.states[idx].app_state,
                session.mode,
                session.focus == .diff,
                header,
            );
        },
        .summary => |s| {
            const b = built orelse return;
            const idx = session.list.cursor;
            const header = try summaryHeader(
                frame_alloc,
                session.entries[idx],
                s.diff.entries,
                s.direction,
            );
            app.drawDiffPane(
                win,
                pane_size,
                b,
                &session.states[idx].app_state,
                session.mode,
                session.focus == .diff,
                header,
            );
        },
        .placeholder => |msg| drawPlaceholderPane(win, pane_size, msg),
    }
}

fn drawPlaceholderPane(win: vaxis.Window, size: app.PaneSize, msg: []const u8) void {
    const pane = win.child(.{
        .x_off = size.x_off,
        .y_off = size.y_off,
        .width = size.width,
        .height = size.height,
    });
    // Centre the message both horizontally and vertically. Long messages
    // that don't fit horizontally fall back to left-aligned; truncation
    // is left to vaxis's `wrap = .none` clipping.
    const msg_len: u16 = @intCast(@min(msg.len, std.math.maxInt(u16)));
    const col: u16 = if (pane.width > msg_len) (pane.width - msg_len) / 2 else 0;
    const row: u16 = pane.height / 2;
    _ = pane.print(
        &.{.{ .text = msg, .style = .{ .dim = true } }},
        .{ .row_offset = row, .col_offset = col, .wrap = .none },
    );
}

fn fileHeader(
    arena: Allocator,
    entry: file_list.Entry,
    built: line_mod.BuildResult,
) !app.DiffHeader {
    // `path` is owned by the repo arena and outlives the frame, so the
    // header can borrow it directly instead of copying.
    const title = entry.change.new_path orelse entry.change.old_path orelse "<?>";
    const stats = try std.fmt.allocPrint(
        arena,
        " +{d}  -{d}  ~{d}  ={d}    (Tab: focus, j/k: move, q: quit)",
        .{ built.stats.added, built.stats.removed, built.stats.changed, built.stats.unchanged },
    );
    return .{ .title = title, .stats = stats };
}

// ── summary header ────────────────────────────────────────────────────────

/// Counts of top-level `DeclDiff` entries grouped by `Decl.kind`.
/// Only the three most common kinds get their own slot; everything else
/// (imports, test cases, containers, language-specific `other`) is
/// folded into `other`.
const DeclKindCounts = struct {
    function: u32 = 0,
    binding: u32 = 0,
    type_alias: u32 = 0,
    other: u32 = 0,
};

/// Walk top-level `DeclDiff` entries and tally them by `Decl.kind`.
/// Only entries matching `direction` contribute: `.added` counts
/// `.added` variants, `.removed` counts `.removed` variants. Nested
/// containers aren't recursed - the summary reflects the file-level
/// change, not a full decl tree.
fn countDeclKinds(
    entries: []const rv.DeclDiff,
    direction: SummaryDirection,
) DeclKindCounts {
    var c: DeclKindCounts = .{};
    for (entries) |e| {
        const decl: ?rv.Decl = switch (e) {
            .added => |a| if (direction == .added) a.decl else null,
            .removed => |r| if (direction == .removed) r.decl else null,
            .unchanged, .changed => null,
        };
        const d = decl orelse continue;
        switch (d.kind) {
            .function => c.function += 1,
            .binding => c.binding += 1,
            .type_alias => c.type_alias += 1,
            else => c.other += 1,
        }
    }
    return c;
}

/// Format a count string like `"3 fns, 2 consts added"` or
/// `"1 type removed"`. Zero-count categories are collapsed; if every
/// category is zero (e.g. an added file with no recognised decls) the
/// output falls back to just the direction word (`"added"`/`"removed"`).
fn formatSummaryHeader(
    arena: Allocator,
    counts: DeclKindCounts,
    direction: SummaryDirection,
) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;

    const entries = [_]struct { count: u32, singular: []const u8, plural: []const u8 }{
        .{ .count = counts.function, .singular = "fn", .plural = "fns" },
        .{ .count = counts.binding, .singular = "const", .plural = "consts" },
        .{ .count = counts.type_alias, .singular = "type", .plural = "types" },
        .{ .count = counts.other, .singular = "other", .plural = "others" },
    };
    for (entries) |e| {
        if (e.count == 0) continue;
        const word = if (e.count == 1) e.singular else e.plural;
        try parts.append(arena, try std.fmt.allocPrint(arena, "{d} {s}", .{ e.count, word }));
    }

    const dir_word: []const u8 = switch (direction) {
        .added => "added",
        .removed => "removed",
    };

    if (parts.items.len == 0) return arena.dupe(u8, dir_word);

    const joined = try std.mem.join(arena, ", ", parts.items);
    return std.fmt.allocPrint(arena, "{s} {s}", .{ joined, dir_word });
}

fn summaryHeader(
    arena: Allocator,
    entry: file_list.Entry,
    entries: []const rv.DeclDiff,
    direction: SummaryDirection,
) !app.DiffHeader {
    const title = entry.change.new_path orelse entry.change.old_path orelse "<?>";
    const counts = countDeclKinds(entries, direction);
    const stats = try formatSummaryHeader(arena, counts, direction);
    return .{ .title = title, .stats = stats };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "summarize: counts added / removed / changed, skips unchanged" {
    // Synthetic FileDiff built from `diffSources` on two tiny Zig
    // snippets. Exercises one entry per top-level variant.
    const before =
        \\pub fn keep() void {}
        \\pub fn gone() void {}
        \\pub fn mod() u32 { return 1; }
    ;
    const after =
        \\pub fn keep() void {}
        \\pub fn mod() u32 { return 2; }
        \\pub fn fresh() void {}
    ;
    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    const s = summarize(fd.entries);
    try testing.expectEqual(@as(u32, 1), s.added);
    try testing.expectEqual(@as(u32, 1), s.removed);
    try testing.expectEqual(@as(u32, 1), s.changed);
}

test "summarize: all unchanged → zero counts" {
    const src = "pub fn a() void {}\npub fn b() void {}\n";
    var fd = try rv.diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();

    const s = summarize(fd.entries);
    try testing.expectEqual(@as(u32, 0), s.added);
    try testing.expectEqual(@as(u32, 0), s.removed);
    try testing.expectEqual(@as(u32, 0), s.changed);
}

/// Hand-build a FileState + entry with a pre-populated `FileDiff` so
/// `ensureLoaded` has nothing to do. Exercises the idempotency path
/// without needing a real repo.
fn stubSession(gpa: Allocator, change: vcs.FileChange, fd: rv.FileDiff) !Session {
    const entries = try gpa.alloc(file_list.Entry, 1);
    errdefer gpa.free(entries);
    const states = try gpa.alloc(FileState, 1);
    errdefer gpa.free(states);

    entries[0] = .{ .change = change, .summary = null };
    states[0] = .{
        .diff = fd,
        .old_source = null,
        .new_source = null,
        .app_state = line_mod.AppState.init(gpa),
    };
    // We deliberately skip `vcs.Repo.discover` — the tests never touch
    // `session.repo`, so a zeroed handle is fine. `deinit` is not
    // called on this stub; the caller frees the slices manually.
    return .{
        .gpa = gpa,
        .io = undefined,
        .repo = undefined,
        .entries = entries,
        .states = states,
        .list = .{ .entries = entries },
        .focus = .file_list,
        .mode = .unified,
        .scratch = undefined,
    };
}

fn freeStub(session: *Session) void {
    for (session.states) |*s| s.deinit(session.gpa);
    session.gpa.free(session.states);
    session.gpa.free(session.entries);
}

/// Like `stubSession` but for changes that never load a `FileDiff`
/// (binary / unsupported). Accepts any number of changes so tests can
/// exercise multi-entry paths without repeating the allocation boilerplate.
fn emptyStubSession(gpa: Allocator, changes: []const vcs.FileChange) !Session {
    const entries = try gpa.alloc(file_list.Entry, changes.len);
    errdefer gpa.free(entries);
    const states = try gpa.alloc(FileState, changes.len);
    errdefer gpa.free(states);

    for (changes, 0..) |c, i| {
        entries[i] = .{ .change = c, .summary = null };
        states[i] = .{
            .diff = null,
            .old_source = null,
            .new_source = null,
            .app_state = line_mod.AppState.init(gpa),
        };
    }
    return .{
        .gpa = gpa,
        .io = undefined,
        .repo = undefined,
        .entries = entries,
        .states = states,
        .list = .{ .entries = entries },
        .focus = .file_list,
        .mode = .unified,
        .scratch = undefined,
    };
}

test "ensureLoaded: idempotent when diff is already populated" {
    const src = "pub fn a() void {}\n";
    const fd = try rv.diffSources(testing.allocator, .zig, src, src);

    const change: vcs.FileChange = .{
        .kind = .modified,
        .old_path = "a.zig",
        .new_path = "a.zig",
        .line_stat = .{ .added = 0, .removed = 0 },
    };

    var session = try stubSession(testing.allocator, change, fd);
    defer freeStub(&session);

    try session.ensureLoaded(0);

    // The stub left `old_source` / `new_source` null; the reload path
    // would have populated both, so their still-null state is the
    // witness that ensureLoaded short-circuited.
    try testing.expect(session.states[0].old_source == null);
    try testing.expect(session.states[0].new_source == null);
}

test "ensureLoaded: binary and unsupported are silent no-ops" {
    // No pre-populated FileDiff; ensureLoaded must not try to call git.
    var session = try emptyStubSession(testing.allocator, &.{
        .{
            .kind = .binary,
            .old_path = "img.png",
            .new_path = "img.png",
            .line_stat = .{ .added = 0, .removed = 0 },
        },
        .{
            .kind = .unsupported,
            .old_path = "notes.xyz",
            .new_path = "notes.xyz",
            .line_stat = .{ .added = 0, .removed = 0 },
        },
    });
    defer freeStub(&session);

    try session.ensureLoaded(0);
    try session.ensureLoaded(1);
    try testing.expect(session.states[0].diff == null);
    try testing.expect(session.states[1].diff == null);
}

test "classify: modified → diff variant" {
    const src = "pub fn a() void {}\n";
    const fd = try rv.diffSources(testing.allocator, .zig, src, src);

    const change: vcs.FileChange = .{
        .kind = .modified,
        .old_path = "a.zig",
        .new_path = "a.zig",
        .line_stat = .{ .added = 0, .removed = 0 },
    };

    var session = try stubSession(testing.allocator, change, fd);
    defer freeStub(&session);

    const view = session.classify(0);
    try testing.expect(view == .diff);
}

test "classify: added → summary direction=added" {
    const src = "pub fn a() void {}\n";
    const fd = try rv.diffSources(testing.allocator, .zig, "", src);

    const change: vcs.FileChange = .{
        .kind = .added,
        .old_path = null,
        .new_path = "a.zig",
        .line_stat = .{ .added = 1, .removed = 0 },
    };

    var session = try stubSession(testing.allocator, change, fd);
    defer freeStub(&session);

    const view = session.classify(0);
    try testing.expect(view == .summary);
    try testing.expectEqual(SummaryDirection.added, view.summary.direction);
}

test "classify: deleted → summary direction=removed" {
    const src = "pub fn a() void {}\n";
    const fd = try rv.diffSources(testing.allocator, .zig, src, "");

    const change: vcs.FileChange = .{
        .kind = .deleted,
        .old_path = "a.zig",
        .new_path = null,
        .line_stat = .{ .added = 0, .removed = 1 },
    };

    var session = try stubSession(testing.allocator, change, fd);
    defer freeStub(&session);

    const view = session.classify(0);
    try testing.expect(view == .summary);
    try testing.expectEqual(SummaryDirection.removed, view.summary.direction);
}

test "classify: binary → placeholder 'Binary file, not shown'" {
    var session = try emptyStubSession(testing.allocator, &.{.{
        .kind = .binary,
        .old_path = "img.png",
        .new_path = "img.png",
        .line_stat = .{ .added = 0, .removed = 0 },
    }});
    defer freeStub(&session);

    const view = session.classify(0);
    try testing.expect(view == .placeholder);
    try testing.expectEqualStrings("Binary file, not shown", view.placeholder);
}

test "classify: unsupported → placeholder carries extension" {
    var session = try emptyStubSession(testing.allocator, &.{.{
        .kind = .unsupported,
        .old_path = "notes.xyz",
        .new_path = "notes.xyz",
        .line_stat = .{ .added = 0, .removed = 0 },
    }});
    defer freeStub(&session);

    const view = session.classify(0);
    try testing.expect(view == .placeholder);
    try testing.expectEqualStrings("No language support for .xyz", view.placeholder);
}

test "paneLayout: sidebar width capped at 40 and at (width * 3) / 10" {
    // Narrow: width * 3 / 10 is the binding constraint.
    const narrow = paneLayout(50);
    try testing.expectEqual(@as(u16, 15), narrow.sidebar_w);
    try testing.expectEqual(@as(u16, 15), narrow.sep_col);
    try testing.expectEqual(@as(u16, 16), narrow.pane_x);
    try testing.expectEqual(@as(u16, 34), narrow.pane_w);

    // Wide: 40-col cap kicks in.
    const wide = paneLayout(200);
    try testing.expectEqual(@as(u16, 40), wide.sidebar_w);
    try testing.expectEqual(@as(u16, 159), wide.pane_w);
}

// ── summary header formatting ─────────────────────────────────────

test "formatSummaryHeader: plural and singular words, comma separated" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "3 fns, 2 consts added",
        try formatSummaryHeader(a, .{ .function = 3, .binding = 2 }, .added),
    );
    try testing.expectEqualStrings(
        "1 type removed",
        try formatSummaryHeader(a, .{ .type_alias = 1 }, .removed),
    );
    try testing.expectEqualStrings(
        "1 fn, 1 const, 1 type added",
        try formatSummaryHeader(
            a,
            .{ .function = 1, .binding = 1, .type_alias = 1 },
            .added,
        ),
    );
}

test "formatSummaryHeader: zero-count categories are omitted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "5 others added",
        try formatSummaryHeader(a, .{ .other = 5 }, .added),
    );
    try testing.expectEqualStrings(
        "added",
        try formatSummaryHeader(a, .{}, .added),
    );
}

test "countDeclKinds: groups added decls by kind, ignores unchanged/changed/removed" {
    // An added `.zig` file with 2 fns and 1 const. `countDeclKinds` with
    // direction=.added should report function=2 / binding=1. Zig has no
    // native type_alias, so that slot stays zero.
    const after =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub const C: u32 = 1;
    ;

    var fd = try rv.diffSources(testing.allocator, .zig, "", after);
    defer fd.deinit();

    const counts = countDeclKinds(fd.entries, .added);
    try testing.expectEqual(@as(u32, 2), counts.function);
    try testing.expectEqual(@as(u32, 1), counts.binding);
    try testing.expectEqual(@as(u32, 0), counts.type_alias);
    try testing.expectEqual(@as(u32, 0), counts.other);

    // Same entries asked about `.removed` yields nothing, since every
    // top-level DeclDiff here is `.added`.
    const removed_counts = countDeclKinds(fd.entries, .removed);
    try testing.expectEqual(@as(u32, 0), removed_counts.function);
    try testing.expectEqual(@as(u32, 0), removed_counts.binding);
}

test "summary header: added file with 3 fns and 2 consts renders expected string" {
    // End-to-end: diff an empty before against an added Zig file with
    // 3 fns and 2 consts, then format through the same helper the UI
    // calls, and check the full header string.
    const after =
        \\pub fn one() void {}
        \\pub fn two() void {}
        \\pub fn three() void {}
        \\pub const X: u32 = 1;
        \\pub const Y: u32 = 2;
    ;

    var fd = try rv.diffSources(testing.allocator, .zig, "", after);
    defer fd.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const counts = countDeclKinds(fd.entries, .added);
    const s = try formatSummaryHeader(arena.allocator(), counts, .added);
    try testing.expectEqualStrings("3 fns, 2 consts added", s);
}

test "summary header: deleted file with 1 fn renders '1 fn removed'" {
    const before = "pub fn gone() void {}\n";

    var fd = try rv.diffSources(testing.allocator, .zig, before, "");
    defer fd.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const counts = countDeclKinds(fd.entries, .removed);
    const s = try formatSummaryHeader(arena.allocator(), counts, .removed);
    try testing.expectEqualStrings("1 fn removed", s);
}


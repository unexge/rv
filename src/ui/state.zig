//! UI state shared across rebuilds of the diff view.
//!
//! `line.zig::build` reads this state (collapse set) to decide which decl
//! bodies to render. `app.zig` mutates scroll / cursor / collapse in
//! response to input and triggers a rebuild on change.

const std = @import("std");
const rv = @import("rv");

/// Stable identity for a decl across rebuilds. Uses the underlying
/// `sst.List` pointer, which is valid for the lifetime of the owning
/// `FileDiff` and unique across both the left and right SSTs.
pub const DeclId = u64;

/// Stable identity for an elided gap (a collapsed run of unchanged
/// lines) in the file-wide view. Built by `elide.zig` from the byte
/// offsets of the gap's first line so it survives rebuilds as long as
/// the surrounding source doesn't shift.
pub const GapId = u64;

/// Derive the `DeclId` for a decl. For `.changed` entries the caller
/// should pass `new`; for `.unchanged` / `.added` / `.removed` the unique
/// `decl` field.
pub fn declId(decl: rv.Decl) DeclId {
    return @intFromPtr(decl.list);
}

pub const AppState = struct {
    gpa: std.mem.Allocator,
    scroll_y: usize = 0,
    /// Absolute row (in the current view's coordinates) that the cursor
    /// sits on. Starts at the first line. Clamped to the view's row count
    /// after every rebuild.
    cursor_y: usize = 0,
    /// Set of collapsed decl ids. Membership = collapsed; absence =
    /// expanded. Unchanged decls are never added here (their bodies are
    /// not emitted in the first place, so collapsing them would add a
    /// misleading `[…]` suffix with no visible effect).
    collapsed: std.AutoHashMap(DeclId, void),
    /// Set of expanded gap ids. Membership = expanded (show the run);
    /// absence = collapsed (show the `… N unchanged lines …` row).
    /// Default is collapsed because the file-wide builder always emits
    /// gaps in their collapsed form first.
    expanded_gaps: std.AutoHashMap(GapId, void),
    /// Active search query. While `search_editing` is true, key text updates
    /// this buffer incrementally; after Enter it remains active for n/N.
    search_query: std.ArrayList(u8) = .empty,
    search_editing: bool = false,
    search_collapsed_snapshot: ?std.AutoHashMap(DeclId, void) = null,
    search_gaps_snapshot: ?std.AutoHashMap(GapId, void) = null,

    pub fn init(gpa: std.mem.Allocator) AppState {
        return .{
            .gpa = gpa,
            .collapsed = .init(gpa),
            .expanded_gaps = .init(gpa),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.collapsed.deinit();
        self.expanded_gaps.deinit();
        self.search_query.deinit(self.gpa);
        if (self.search_collapsed_snapshot) |*snapshot| snapshot.deinit();
        if (self.search_gaps_snapshot) |*snapshot| snapshot.deinit();
    }

    pub fn beginSearch(self: *AppState, view: anytype) !void {
        if (self.search_collapsed_snapshot == null) {
            var collapsed_snapshot = try self.collapsed.clone();
            const gaps_snapshot = self.expanded_gaps.clone() catch |err| {
                collapsed_snapshot.deinit();
                return err;
            };
            self.search_collapsed_snapshot = collapsed_snapshot;
            self.search_gaps_snapshot = gaps_snapshot;
        }
        self.search_query.clearRetainingCapacity();
        self.search_editing = true;
        self.expandAll();
        self.expandAllGaps(view) catch |err| {
            _ = self.restoreSearch();
            return err;
        };
    }

    /// Restore the exact fold state from before `/` was pressed. Returns
    /// false when no search snapshot is active.
    pub fn restoreSearch(self: *AppState) bool {
        const collapsed = self.search_collapsed_snapshot orelse return false;
        const gaps = self.search_gaps_snapshot.?;
        self.collapsed.deinit();
        self.expanded_gaps.deinit();
        self.collapsed = collapsed;
        self.expanded_gaps = gaps;
        self.search_collapsed_snapshot = null;
        self.search_gaps_snapshot = null;
        self.search_query.clearRetainingCapacity();
        self.search_editing = false;
        return true;
    }

    pub fn isCollapsed(self: *const AppState, id: DeclId) bool {
        return self.collapsed.contains(id);
    }

    /// Flip the collapse state for `id`. Returns the new state.
    pub fn toggle(self: *AppState, id: DeclId) !bool {
        const gop = try self.collapsed.getOrPut(id);
        if (gop.found_existing) {
            _ = self.collapsed.remove(id);
            return false;
        }
        return true;
    }

    pub fn expandAll(self: *AppState) void {
        self.collapsed.clearRetainingCapacity();
    }

    /// Mark every decl with a hideable body as collapsed. Unchanged decls
    /// emit no body and are skipped so their headers never sprout a
    /// `[…]` suffix.
    pub fn collapseAll(self: *AppState, file_diff: *const rv.FileDiff) !void {
        try collapseEntries(self, file_diff.entries);
    }

    pub fn isGapExpanded(self: *const AppState, id: GapId) bool {
        return self.expanded_gaps.contains(id);
    }

    /// Flip the expansion state for gap `id`. Returns the new state
    /// (true = expanded, false = collapsed).
    pub fn toggleGap(self: *AppState, id: GapId) !bool {
        const gop = try self.expanded_gaps.getOrPut(id);
        if (gop.found_existing) {
            _ = self.expanded_gaps.remove(id);
            return false;
        }
        return true;
    }

    /// Drop every expanded-gap id, returning the file view to its
    /// fully-collapsed (default) state.
    pub fn collapseAllGaps(self: *AppState) void {
        self.expanded_gaps.clearRetainingCapacity();
    }

    /// Walk the given view and mark every `.elided` row's `gap_id` as
    /// expanded. `view` is the `line.View` union; it's taken as `anytype`
    /// to avoid an import cycle (line.zig already imports state.zig).
    pub fn expandAllGaps(self: *AppState, view: anytype) !void {
        switch (view) {
            .unified => |lines| for (lines) |ln| {
                if (ln.kind == .elided) {
                    if (ln.gap_id) |id| try self.expanded_gaps.put(id, {});
                }
            },
            .split => |pairs| for (pairs) |p| {
                if (p.left.kind == .elided) {
                    if (p.left.gap_id) |id| try self.expanded_gaps.put(id, {});
                }
                if (p.right.kind == .elided) {
                    if (p.right.gap_id) |id| try self.expanded_gaps.put(id, {});
                }
            },
        }
    }
};

fn collapseEntries(state: *AppState, entries: []const rv.DeclDiff) !void {
    for (entries) |entry| switch (entry) {
        .unchanged => {},
        .added => |a| try state.collapsed.put(declId(a.decl), {}),
        .removed => |r| try state.collapsed.put(declId(r.decl), {}),
        .changed => |c| {
            try state.collapsed.put(declId(c.new), {});
            if (c.body == .container) {
                try collapseEntries(state, c.body.container);
            }
        },
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "AppState.toggle: flips membership and reports new state" {
    var state = AppState.init(testing.allocator);
    defer state.deinit();

    try testing.expect(!state.isCollapsed(42));
    try testing.expectEqual(true, try state.toggle(42));
    try testing.expect(state.isCollapsed(42));
    try testing.expectEqual(false, try state.toggle(42));
    try testing.expect(!state.isCollapsed(42));
}

test "AppState.expandAll: clears all collapsed ids" {
    var state = AppState.init(testing.allocator);
    defer state.deinit();

    _ = try state.toggle(1);
    _ = try state.toggle(2);
    state.expandAll();
    try testing.expect(!state.isCollapsed(1));
    try testing.expect(!state.isCollapsed(2));
}

test "AppState.toggleGap: flips membership and reports new state" {
    var state = AppState.init(testing.allocator);
    defer state.deinit();

    try testing.expect(!state.isGapExpanded(7));
    try testing.expectEqual(true, try state.toggleGap(7));
    try testing.expect(state.isGapExpanded(7));
    try testing.expectEqual(false, try state.toggleGap(7));
    try testing.expect(!state.isGapExpanded(7));
}

test "AppState.collapseAllGaps: clears all expanded gap ids" {
    var state = AppState.init(testing.allocator);
    defer state.deinit();

    _ = try state.toggleGap(1);
    _ = try state.toggleGap(2);
    state.collapseAllGaps();
    try testing.expect(!state.isGapExpanded(1));
    try testing.expect(!state.isGapExpanded(2));
}

test "AppState.collapseAll: walks added/removed/changed, skips unchanged" {
    // Two unchanged + one changed + one added should collapse exactly three:
    // the changed decl, the added decl, and no one else. The unchanged decl
    // has no body to hide so collapsing it would be misleading.
    const before =
        \\pub fn keep1() void {}
        \\pub fn changes() u32 { return 1; }
        \\pub fn keep2() void {}
    ;
    const after =
        \\pub fn keep1() void {}
        \\pub fn changes() u32 { return 2; }
        \\pub fn keep2() void {}
        \\pub fn added() void {}
    ;

    var fd = try rv.diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var state = AppState.init(testing.allocator);
    defer state.deinit();

    try state.collapseAll(&fd);

    // Exactly 2 collapsed (changed + added).
    try testing.expectEqual(@as(usize, 2), state.collapsed.count());

    // Unchanged decls are not collapsed.
    for (fd.entries) |e| if (e == .unchanged) {
        try testing.expect(!state.isCollapsed(declId(e.unchanged.decl)));
    };
}

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

/// Derive the `DeclId` for a decl. For `.changed` entries the caller
/// should pass `new`; for `.unchanged` / `.added` / `.removed` the unique
/// `decl` field.
pub fn declId(decl: rv.Decl) DeclId {
    return @intFromPtr(decl.list);
}

pub const AppState = struct {
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

    pub fn init(gpa: std.mem.Allocator) AppState {
        return .{ .collapsed = .init(gpa) };
    }

    pub fn deinit(self: *AppState) void {
        self.collapsed.deinit();
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

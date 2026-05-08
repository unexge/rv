//! Diff-shape assertion helpers for unit tests.
//!
//! Tiny DSL used by inline tests throughout the engine to make `DeclDiff`
//! inspection concise. Helpers return errors so callers compose with `try`.
//!
//! Example:
//!     try rv_testing.expectUnchanged(file_diff.entries[0], "foo");
//!     const insp = try rv_testing.expectChanged(file_diff.entries[1], "bar");
//!     try testing.expect(insp.body().leaf.edits.len == 3);

const std = @import("std");
const testing = std.testing;
const rv = @import("root.zig");
const node = @import("sst/node.zig");

pub const ExpectError = error{
    /// DeclDiff tag did not match the variant the helper expected.
    UnexpectedVariant,
    /// Decl name did not match the expected string.
    NameMismatch,
    /// Helper required MoveInfo but `moved` was null.
    NotMoved,
    /// MoveInfo from_idx/to_idx did not match expected values.
    MoveMismatch,
};

/// Returned by `expectChanged`. Exposes the changed body for further
/// inspection via `.body()`.
pub const ChangedInspector = struct {
    entry: rv.DeclDiff,

    /// Returns the `DeclBody` tagged union. Callers use `.leaf` for leaf
    /// Decls (EditScript) or `.container` for container Decls ([]DeclDiff).
    pub fn body(self: ChangedInspector) rv.DeclBody {
        return self.entry.changed.body;
    }
};

fn nameMatches(actual: ?[]const u8, expected: []const u8) bool {
    const a = actual orelse return false;
    return std.mem.eql(u8, a, expected);
}

/// Assert `entry` is `.unchanged` and its decl name matches `name`.
pub fn expectUnchanged(entry: rv.DeclDiff, name: []const u8) ExpectError!void {
    switch (entry) {
        .unchanged => |u| {
            if (!nameMatches(u.decl.name, name)) return error.NameMismatch;
        },
        else => return error.UnexpectedVariant,
    }
}

/// Assert `entry` is `.added` and its decl name matches `name`.
pub fn expectAdded(entry: rv.DeclDiff, name: []const u8) ExpectError!void {
    switch (entry) {
        .added => |a| {
            if (!nameMatches(a.decl.name, name)) return error.NameMismatch;
        },
        else => return error.UnexpectedVariant,
    }
}

/// Assert `entry` is `.removed` and its decl name matches `name`.
pub fn expectRemoved(entry: rv.DeclDiff, name: []const u8) ExpectError!void {
    switch (entry) {
        .removed => |r| {
            if (!nameMatches(r.decl.name, name)) return error.NameMismatch;
        },
        else => return error.UnexpectedVariant,
    }
}

/// Assert `entry` is `.changed` and its new-side decl name matches `name`.
/// Returns a `ChangedInspector` for further body inspection.
pub fn expectChanged(entry: rv.DeclDiff, name: []const u8) ExpectError!ChangedInspector {
    switch (entry) {
        .changed => |c| {
            if (!nameMatches(c.new.name, name)) return error.NameMismatch;
            return .{ .entry = entry };
        },
        else => return error.UnexpectedVariant,
    }
}

/// Assert `entry` carries a MoveInfo matching `from`→`to`. Valid on
/// `.unchanged` and `.changed`; other variants error as `UnexpectedVariant`.
pub fn expectMoved(entry: rv.DeclDiff, from: usize, to: usize) ExpectError!void {
    const move: rv.MoveInfo = switch (entry) {
        .unchanged => |u| u.moved orelse return error.NotMoved,
        .changed => |c| c.moved orelse return error.NotMoved,
        .added, .removed => return error.UnexpectedVariant,
    };
    if (move.from_idx != from or move.to_idx != to) return error.MoveMismatch;
}

// ── tests ──────────────────────────────────────────────────────────────────

// A shared static List used as the backing node for synthetic Decls.
// The tests only read Decl.name/kind/ts_kind, so a stub List is fine.
const stub_list = node.List{
    .ts_kind = "function_item",
    .open_delim = "",
    .close_delim = "",
    .children = &.{},
    .leading_trivia = &.{},
    .trailing_trivia = &.{},
    .byte_range = .{ .start = 0, .end = 0 },
    .hash = 0,
};

fn stubDecl(name: []const u8) rv.Decl {
    return .{
        .kind = .function,
        .ts_kind = "function_item",
        .name = name,
        .list = &stub_list,
    };
}

test "expectUnchanged accepts unchanged variant with matching name" {
    const entry = rv.DeclDiff{ .unchanged = .{
        .decl = stubDecl("foo"),
        .moved = null,
    } };
    try expectUnchanged(entry, "foo");
}

test "expectUnchanged rejects other variants" {
    const added = rv.DeclDiff{ .added = .{ .decl = stubDecl("foo") } };
    try testing.expectError(error.UnexpectedVariant, expectUnchanged(added, "foo"));

    const removed = rv.DeclDiff{ .removed = .{ .decl = stubDecl("foo") } };
    try testing.expectError(error.UnexpectedVariant, expectUnchanged(removed, "foo"));

    const empty_script = rv.EditScript{ .edits = &.{}, .total_cost = 0 };
    const changed = rv.DeclDiff{ .changed = .{
        .old = stubDecl("foo"),
        .new = stubDecl("foo"),
        .body = .{ .leaf = empty_script },
        .moved = null,
    } };
    try testing.expectError(error.UnexpectedVariant, expectUnchanged(changed, "foo"));
}

test "expectUnchanged rejects name mismatch" {
    const entry = rv.DeclDiff{ .unchanged = .{
        .decl = stubDecl("foo"),
        .moved = null,
    } };
    try testing.expectError(error.NameMismatch, expectUnchanged(entry, "bar"));
}

test "expectAdded and expectRemoved" {
    const added = rv.DeclDiff{ .added = .{ .decl = stubDecl("new_fn") } };
    try expectAdded(added, "new_fn");
    try testing.expectError(error.UnexpectedVariant, expectRemoved(added, "new_fn"));

    const removed = rv.DeclDiff{ .removed = .{ .decl = stubDecl("gone_fn") } };
    try expectRemoved(removed, "gone_fn");
    try testing.expectError(error.UnexpectedVariant, expectAdded(removed, "gone_fn"));
}

test "expectChanged inspector returns leaf EditScript" {
    const e1 = rv.Edit{ .novel = .{
        .side = .right,
        .node_ref = undefined, // pointer not dereferenced in this test
    } };
    const edits = [_]rv.Edit{e1};
    const script = rv.EditScript{ .edits = &edits, .total_cost = 5 };

    const entry = rv.DeclDiff{ .changed = .{
        .old = stubDecl("foo"),
        .new = stubDecl("foo"),
        .body = .{ .leaf = script },
        .moved = null,
    } };

    const insp = try expectChanged(entry, "foo");
    const leaf = insp.body().leaf;
    try testing.expectEqual(@as(usize, 1), leaf.edits.len);
    try testing.expectEqual(@as(u64, 5), leaf.total_cost);
}

test "expectChanged inspector returns container slice" {
    const child = rv.DeclDiff{ .added = .{ .decl = stubDecl("inner") } };
    const children = [_]rv.DeclDiff{child};

    const entry = rv.DeclDiff{ .changed = .{
        .old = stubDecl("Outer"),
        .new = stubDecl("Outer"),
        .body = .{ .container = &children },
        .moved = null,
    } };

    const insp = try expectChanged(entry, "Outer");
    const slice = insp.body().container;
    try testing.expectEqual(@as(usize, 1), slice.len);
    try expectAdded(slice[0], "inner");
}

test "expectChanged rejects wrong variant and wrong name" {
    const unchanged = rv.DeclDiff{ .unchanged = .{
        .decl = stubDecl("foo"),
        .moved = null,
    } };
    try testing.expectError(error.UnexpectedVariant, expectChanged(unchanged, "foo"));

    const script = rv.EditScript{ .edits = &.{}, .total_cost = 0 };
    const changed = rv.DeclDiff{ .changed = .{
        .old = stubDecl("foo"),
        .new = stubDecl("foo"),
        .body = .{ .leaf = script },
        .moved = null,
    } };
    try testing.expectError(error.NameMismatch, expectChanged(changed, "bar"));
}

test "expectMoved on unchanged checks MoveInfo fields" {
    const entry = rv.DeclDiff{ .unchanged = .{
        .decl = stubDecl("foo"),
        .moved = .{ .from_idx = 1, .to_idx = 3 },
    } };
    try expectMoved(entry, 1, 3);
    try testing.expectError(error.MoveMismatch, expectMoved(entry, 0, 3));
    try testing.expectError(error.MoveMismatch, expectMoved(entry, 1, 2));
}

test "expectMoved on changed checks MoveInfo fields" {
    const script = rv.EditScript{ .edits = &.{}, .total_cost = 0 };
    const entry = rv.DeclDiff{ .changed = .{
        .old = stubDecl("foo"),
        .new = stubDecl("foo"),
        .body = .{ .leaf = script },
        .moved = .{ .from_idx = 4, .to_idx = 2 },
    } };
    try expectMoved(entry, 4, 2);
}

test "expectMoved rejects when moved is null" {
    const entry = rv.DeclDiff{ .unchanged = .{
        .decl = stubDecl("foo"),
        .moved = null,
    } };
    try testing.expectError(error.NotMoved, expectMoved(entry, 0, 0));
}

test "expectMoved rejects added/removed variants" {
    const added = rv.DeclDiff{ .added = .{ .decl = stubDecl("foo") } };
    try testing.expectError(error.UnexpectedVariant, expectMoved(added, 0, 0));

    const removed = rv.DeclDiff{ .removed = .{ .decl = stubDecl("foo") } };
    try testing.expectError(error.UnexpectedVariant, expectMoved(removed, 0, 0));
}

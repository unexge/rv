//! Container alignment.
//!
//! Pairs Decls between two containers by the hybrid identity rule from Q3:
//!
//!   1. Hash-equal Decls → `DeclDiff.unchanged` (fast path).
//!   2. Among the rest, equal (kind, name, nth_occurrence) identity keys →
//!      `DeclDiff.changed` (run the leaf body-diff or recurse).
//!   3. Remaining leftovers → `DeclDiff.added` / `DeclDiff.removed`.
//!
//! Matching is set-based (Q7 revised): relative order is irrelevant for
//! pairing. When a matched pair's index differs between sides, `moved` is
//! populated.
//!
//! Output order: right-side order for matched and added entries, with
//! removed entries spliced in just before the right-side anchor of their
//! left-side next-neighbour's match. Trailing removed entries with no
//! anchor are appended at the end in left-side order.

const std = @import("std");
const node = @import("../sst/node.zig");
const config_mod = @import("../lang/config.zig");
const result = @import("../diff/result.zig");
const edit = @import("edit.zig");
const dijkstra = @import("dijkstra.zig");

pub const AlignError = error{
    OutOfMemory,
};

/// Align the children of two container Lists.
///
/// `left_container` and `right_container` must both be List nodes whose
/// `ts_kind` appears in `cfg.container_ts_kinds` - or the root `source_file`
/// for top-level alignment.
///
/// Recurses into child containers; calls into `dijkstra.zig` for leaf Decls
/// whose hash differs. Allocates everything in `arena`.
pub fn alignDecls(
    arena: std.mem.Allocator,
    cfg: *const config_mod.LangConfig,
    left_container: *const node.List,
    right_container: *const node.List,
    left_source: []const u8,
    right_source: []const u8,
) AlignError![]result.DeclDiff {
    const left_decls = try extractDecls(arena, cfg, left_container, left_source);
    const right_decls = try extractDecls(arena, cfg, right_container, right_source);

    // Paired indices: left_pair[li] = ri if left[li] is paired with right[ri].
    const left_pair = try arena.alloc(?usize, left_decls.len);
    @memset(left_pair, null);
    const right_pair = try arena.alloc(?usize, right_decls.len);
    @memset(right_pair, null);

    // Pass 1: hash match. Iterating left in order and taking the first
    // unused right with equal hash keeps pairing deterministic for
    // duplicate-hash siblings.
    for (left_decls, 0..) |ld, li| {
        if (left_pair[li] != null) continue;
        for (right_decls, 0..) |rd, ri| {
            if (right_pair[ri] != null) continue;
            if (ld.list.hash == rd.list.hash) {
                left_pair[li] = ri;
                right_pair[ri] = li;
                break;
            }
        }
    }

    // Pass 2: identity-key match among leftovers.
    for (left_decls, 0..) |ld, li| {
        if (left_pair[li] != null) continue;
        for (right_decls, 0..) |rd, ri| {
            if (right_pair[ri] != null) continue;
            if (identityEqual(ld.identity, rd.identity)) {
                left_pair[li] = ri;
                right_pair[ri] = li;
                break;
            }
        }
    }

    // For each unpaired (removed) left Decl, precompute the index of its
    // next matched neighbour in left-side order (the anchor). Removed
    // entries are spliced just before their anchor's right-side emit.
    const next_matched = try arena.alloc(?usize, left_decls.len);
    {
        var current: ?usize = null;
        var i: usize = left_decls.len;
        while (i > 0) {
            i -= 1;
            if (left_pair[i] != null) {
                current = i;
                next_matched[i] = null; // unused
            } else {
                next_matched[i] = current;
            }
        }
    }

    var out: std.ArrayList(result.DeclDiff) = .empty;
    const left_emitted = try arena.alloc(bool, left_decls.len);
    @memset(left_emitted, false);

    for (right_decls, 0..) |rd, ri| {
        if (right_pair[ri]) |li_match| {
            // Splice removed decls anchored at li_match, in left order.
            for (left_decls, 0..) |_, li| {
                if (left_pair[li] != null) continue;
                if (left_emitted[li]) continue;
                if (next_matched[li]) |anchor| {
                    if (anchor == li_match) {
                        try out.append(arena, .{ .removed = .{
                            .decl = makeDecl(left_decls[li]),
                        } });
                        left_emitted[li] = true;
                    }
                }
            }

            const ld = left_decls[li_match];
            const moved = moveInfo(ld.child_idx, rd.child_idx);

            if (ld.list.hash == rd.list.hash) {
                try out.append(arena, .{ .unchanged = .{
                    .decl = makeDecl(ld),
                    .moved = moved,
                } });
            } else if (try maybeImportGroupBody(arena, cfg, ld, rd, left_source, right_source)) |ig_body| {
                if (isAllKept(ig_body)) {
                    try out.append(arena, .{ .unchanged = .{
                        .decl = makeDecl(rd),
                        .moved = moved,
                    } });
                } else {
                    try out.append(arena, .{ .changed = .{
                        .old = makeDecl(ld),
                        .new = makeDecl(rd),
                        .body = ig_body,
                        .moved = moved,
                    } });
                }
            } else {
                const body: result.DeclBody = blk: {
                    if (containerListOf(cfg, ld.list)) |ld_inner| {
                        const rd_inner = containerListOf(cfg, rd.list) orelse break :blk
                            try leafDiff(arena, ld, rd);
                        break :blk .{ .container = try alignDecls(
                            arena,
                            cfg,
                            ld_inner,
                            rd_inner,
                            left_source,
                            right_source,
                        ) };
                    }
                    break :blk try leafDiff(arena, ld, rd);
                };

                try out.append(arena, .{ .changed = .{
                    .old = makeDecl(ld),
                    .new = makeDecl(rd),
                    .body = body,
                    .moved = moved,
                } });
            }
        } else {
            try out.append(arena, .{ .added = .{ .decl = makeDecl(rd) } });
        }
    }

    // Trailing removed Decls with no right-side anchor, in left order.
    for (left_decls, 0..) |_, li| {
        if (left_pair[li] != null) continue;
        if (left_emitted[li]) continue;
        try out.append(arena, .{ .removed = .{ .decl = makeDecl(left_decls[li]) } });
    }

    return out.toOwnedSlice(arena);
}

// ── internals ──────────────────────────────────────────────────────────────

const IdentityKey = struct {
    ts_kind: []const u8,
    name: ?[]const u8,
    occ: usize,
    /// True when `name` came from `cfg.import_group_key` rather than
    /// `cfg.extract_name`. Keeps the two namespaces disjoint so that, for
    /// example, `use foo;` (extract_name "foo") doesn't accidentally pair
    /// with `use foo::Bar;` (import_group_key "foo") when one side opts
    /// out of import-group alignment.
    import_group: bool,
};

/// Internal record: a Decl plus the metadata alignment needs to track.
const DeclInfo = struct {
    node_ptr: *const node.Node,
    list: *const node.List,
    child_idx: usize,
    ts_kind: []const u8,
    name: ?[]const u8,
    decl_kind: result.DeclKind,
    identity: IdentityKey,
};

fn extractDecls(
    arena: std.mem.Allocator,
    cfg: *const config_mod.LangConfig,
    container: *const node.List,
    source: []const u8,
) AlignError![]DeclInfo {
    var out: std.ArrayList(DeclInfo) = .empty;
    errdefer out.deinit(arena);

    for (container.children, 0..) |*child_ptr, idx| {
        switch (child_ptr.*) {
            .atom => {},
            .list => |l| {
                if (!contains(cfg.decl_ts_kinds, l.ts_kind)) continue;
                const list_ptr = &child_ptr.list;
                const display_name = cfg.extract_name(list_ptr, source);
                // Identity name overrides display name for import-group
                // decls: two `use foo::Bar;` and `use foo::Baz;` share the
                // identity `foo` so they pair under a common prefix while
                // still rendering their full path as the display name.
                // The `import_group` flag keeps these prefix identities in
                // a separate namespace from regular extract_name ones.
                const ig_key: ?[]const u8 = if (cfg.import_group_key) |key_fn|
                    key_fn(list_ptr, source)
                else
                    null;
                const identity_name: ?[]const u8 = ig_key orelse display_name;
                const is_ig_identity = ig_key != null;
                const decl_kind = cfg.classify(l.ts_kind);

                // Compute nth_occurrence of (ts_kind, identity_name,
                // import_group) among already-extracted decls on this
                // side. O(n²); decl counts are small.
                var occ: usize = 0;
                for (out.items) |prior| {
                    if (std.mem.eql(u8, prior.ts_kind, l.ts_kind) and
                        prior.identity.import_group == is_ig_identity and
                        nameEqual(prior.identity.name, identity_name))
                    {
                        occ += 1;
                    }
                }

                try out.append(arena, .{
                    .node_ptr = child_ptr,
                    .list = list_ptr,
                    .child_idx = idx,
                    .ts_kind = l.ts_kind,
                    .name = display_name,
                    .decl_kind = decl_kind,
                    .identity = .{
                        .ts_kind = l.ts_kind,
                        .name = identity_name,
                        .occ = occ,
                        .import_group = is_ig_identity,
                    },
                });
            },
        }
    }

    return out.toOwnedSlice(arena);
}

fn makeDecl(info: DeclInfo) result.Decl {
    return .{
        .kind = info.decl_kind,
        .ts_kind = info.ts_kind,
        .name = info.name,
        .list = info.list,
    };
}

fn moveInfo(from: usize, to: usize) ?result.MoveInfo {
    if (from == to) return null;
    return .{ .from_idx = from, .to_idx = to };
}

fn nameEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn identityEqual(a: IdentityKey, b: IdentityKey) bool {
    if (!std.mem.eql(u8, a.ts_kind, b.ts_kind)) return false;
    if (a.import_group != b.import_group) return false;
    if (!nameEqual(a.name, b.name)) return false;
    return a.occ == b.occ;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// Resolve a Decl's container list, honouring `cfg.container_list_of` when
/// present and falling back to the static `container_ts_kinds` table.
/// Returns null when the given Decl is not a container.
fn containerListOf(cfg: *const config_mod.LangConfig, list: *const node.List) ?*const node.List {
    if (cfg.container_list_of) |fn_ptr| return fn_ptr(list);
    if (contains(cfg.container_ts_kinds, list.ts_kind)) return list;
    return null;
}

/// Leaf body diff for a Changed Decl: run Dijkstra over children and
/// append novel edits for any leading/trailing trivia that differ between
/// the two Decl Lists. Trivia atoms (comments attached to a Decl in
/// `sst/convert.zig`) are invisible to Dijkstra because its virtual
/// wrapper aliases the root Node and only its `children` slice - so
/// comment-only edits on doc comments would otherwise leave the edit
/// script empty and `isCommentOnly()` would return false.
fn leafDiff(
    arena: std.mem.Allocator,
    ld: DeclInfo,
    rd: DeclInfo,
) AlignError!result.DeclBody {
    const body = try dijkstra.diffNodes(arena, ld.node_ptr, rd.node_ptr);
    const trivia = try triviaEdits(arena, ld.list, rd.list);
    if (trivia.len == 0) return .{ .leaf = body };

    const merged = try arena.alloc(edit.Edit, body.edits.len + trivia.len);
    @memcpy(merged[0..body.edits.len], body.edits);
    @memcpy(merged[body.edits.len..], trivia);
    return .{ .leaf = .{ .edits = merged, .total_cost = body.total_cost } };
}

/// Pairwise-align two trivia streams (leading, then trailing). Equal
/// hashes at the same index match silently; a difference at position `i`
/// emits novel-left for the left atom and/or novel-right for the right
/// atom depending on which side has an atom there. The synthesised Node
/// wrappers live in `arena` and carry the original atom bytes.
fn triviaEdits(
    arena: std.mem.Allocator,
    l: *const node.List,
    r: *const node.List,
) AlignError![]const edit.Edit {
    var out: std.ArrayList(edit.Edit) = .empty;
    errdefer out.deinit(arena);
    try appendTriviaDiff(arena, &out, l.leading_trivia, r.leading_trivia);
    try appendTriviaDiff(arena, &out, l.trailing_trivia, r.trailing_trivia);
    return try out.toOwnedSlice(arena);
}

fn appendTriviaDiff(
    arena: std.mem.Allocator,
    out: *std.ArrayList(edit.Edit),
    left: []const node.Atom,
    right: []const node.Atom,
) AlignError!void {
    const max_len = @max(left.len, right.len);
    var i: usize = 0;
    while (i < max_len) : (i += 1) {
        const have_l = i < left.len;
        const have_r = i < right.len;
        if (have_l and have_r and left[i].hash == right[i].hash) continue;
        if (have_l) try out.append(arena, .{ .novel = .{
            .side = .left,
            .node_ref = try wrapAtom(arena, left[i]),
        } });
        if (have_r) try out.append(arena, .{ .novel = .{
            .side = .right,
            .node_ref = try wrapAtom(arena, right[i]),
        } });
    }
}

fn wrapAtom(arena: std.mem.Allocator, atom: node.Atom) AlignError!*const node.Node {
    const wrapper = try arena.create(node.Node);
    wrapper.* = .{ .atom = atom };
    return wrapper;
}

// ── import-group body diff ─────────────────────────────────────────────────

/// Build an `ImportGroupDiff` body if both sides supply a non-null
/// `import_group_key`; otherwise return null and let the caller fall back
/// to the regular leaf/container body. The two-sided null check is
/// defensive - paired decls that landed here already shared an identity,
/// which (for an import-group identity) implies both sides had a key.
fn maybeImportGroupBody(
    arena: std.mem.Allocator,
    cfg: *const config_mod.LangConfig,
    ld: DeclInfo,
    rd: DeclInfo,
    left_source: []const u8,
    right_source: []const u8,
) AlignError!?result.DeclBody {
    const key_fn = cfg.import_group_key orelse return null;
    const left_key = key_fn(ld.list, left_source);
    const right_key = key_fn(rd.list, right_source);
    if (left_key == null or right_key == null) return null;
    return try importGroupBody(arena, cfg, ld, rd, left_source, right_source);
}

/// Diff two paired import-group decls as a per-symbol delta.
///
/// Output ordering: walks the right-side symbol list and emits each one as
/// `.kept` (text-equal match against an unconsumed left symbol) or
/// `.added`. Unmatched left symbols are spliced as `.removed` next to
/// their matched neighbour on the left side: those before the first
/// matched left go at the front, and those between (or after) matched
/// lefts are emitted right after the kept entry for their preceding match.
fn importGroupBody(
    arena: std.mem.Allocator,
    cfg: *const config_mod.LangConfig,
    ld: DeclInfo,
    rd: DeclInfo,
    left_source: []const u8,
    right_source: []const u8,
) AlignError!result.DeclBody {
    const left_syms = try cfg.import_symbols.?(arena, ld.list, left_source);
    const right_syms = try cfg.import_symbols.?(arena, rd.list, right_source);

    // Match each right symbol to the first available text-equal left.
    const left_matched = try arena.alloc(bool, left_syms.len);
    @memset(left_matched, false);
    const right_match = try arena.alloc(?usize, right_syms.len);
    for (right_syms, 0..) |rs, ri| {
        right_match[ri] = null;
        for (left_syms, 0..) |ls, li| {
            if (left_matched[li]) continue;
            if (std.mem.eql(u8, ls.text, rs.text)) {
                left_matched[li] = true;
                right_match[ri] = li;
                break;
            }
        }
    }

    var entries: std.ArrayList(result.ImportSymbolEntry) = .empty;

    // Lead-in: unmatched lefts before the first matched left.
    var lead: usize = 0;
    while (lead < left_syms.len and !left_matched[lead]) : (lead += 1) {
        try entries.append(arena, .{ .removed = left_syms[lead] });
    }

    // Walk right symbols in order. After each kept entry, splice any
    // unmatched lefts that immediately follow its matched left index.
    for (right_syms, 0..) |rs, ri| {
        if (right_match[ri]) |li| {
            try entries.append(arena, .{ .kept = rs });
            var j = li + 1;
            while (j < left_syms.len and !left_matched[j]) : (j += 1) {
                try entries.append(arena, .{ .removed = left_syms[j] });
            }
        } else {
            try entries.append(arena, .{ .added = rs });
        }
    }

    const prefix = cfg.import_group_key.?(rd.list, right_source).?;
    return .{ .import_group = .{
        .prefix = prefix,
        .entries = try entries.toOwnedSlice(arena),
    } };
}

/// Returns true when `body` is an `import_group` whose entries are all
/// `.kept` (i.e. left and right have the exact same symbol set, just in a
/// different order or with whitespace edits). Such bodies represent
/// reorder-only changes and should demote to `Unchanged`.
fn isAllKept(body: result.DeclBody) bool {
    return switch (body) {
        .import_group => |g| blk: {
            for (g.entries) |e| {
                if (e != .kept) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const hash_mod = @import("../sst/hash.zig");

// Test LangConfig: first code atom is the name; everything listed in
// `decl_ts_kinds` is a Decl; `class`/`mod` are containers.
const test_cfg: config_mod.LangConfig = .{
    .grammar_name = "test",
    .atom_ts_kinds = &.{},
    .delimiter_ts_kinds = &.{},
    .comment_ts_kinds = &.{},
    .decl_ts_kinds = &.{ "fn", "const", "class", "mod", "impl" },
    .container_ts_kinds = &.{ "class", "mod", "impl" },
    .classify = testClassify,
    .extract_name = testExtractName,
};

fn testClassify(ts_kind: []const u8) result.DeclKind {
    if (std.mem.eql(u8, ts_kind, "fn")) return .function;
    if (std.mem.eql(u8, ts_kind, "const")) return .binding;
    if (std.mem.eql(u8, ts_kind, "class")) return .container;
    if (std.mem.eql(u8, ts_kind, "mod")) return .container;
    if (std.mem.eql(u8, ts_kind, "impl")) return .container;
    return .other;
}

fn testExtractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = source;
    if (list.children.len == 0) return null;
    return switch (list.children[0]) {
        .atom => |a| if (a.kind == .code) a.bytes else null,
        .list => null,
    };
}

// ── test tree builders ─────────────────────────────────────────────────────

fn atomN(kind: node.AtomKind, bytes: []const u8) node.Node {
    return .{ .atom = .{
        .kind = kind,
        .bytes = bytes,
        .byte_range = .{ .start = 0, .end = @intCast(bytes.len) },
        .hash = 0,
    } };
}

fn listN(
    arena: std.mem.Allocator,
    ts_kind: []const u8,
    children: []const node.Node,
) !node.Node {
    const dup = try arena.dupe(node.Node, children);
    return .{ .list = .{
        .ts_kind = ts_kind,
        .open_delim = "",
        .close_delim = "",
        .children = dup,
        .leading_trivia = &.{},
        .trailing_trivia = &.{},
        .byte_range = .{ .start = 0, .end = 0 },
        .hash = 0,
    } };
}

/// Build a named Decl: `ts_kind [name_atom, body_atoms...]`.
fn declN(
    arena: std.mem.Allocator,
    ts_kind: []const u8,
    name: []const u8,
    body: []const node.Node,
) !node.Node {
    var kids: std.ArrayList(node.Node) = .empty;
    defer kids.deinit(arena);
    try kids.append(arena, atomN(.code, name));
    try kids.appendSlice(arena, body);
    return listN(arena, ts_kind, kids.items);
}

fn buildTree(arena: std.mem.Allocator, root: node.Node) !*node.Tree {
    const tree = try arena.create(node.Tree);
    tree.* = .{ .root = root, .source = "" };
    hash_mod.hashTree(tree);
    return tree;
}

fn alignRoots(
    arena: std.mem.Allocator,
    left: node.Node,
    right: node.Node,
) ![]result.DeclDiff {
    const tl = try buildTree(arena, left);
    const tr = try buildTree(arena, right);
    return alignDecls(arena, &test_cfg, &tl.root.list, &tr.root.list, "", "");
}

// ── Unit tests ─────────────────────────────────────────────────────────────

test "align: empty containers both sides → empty result" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const l = try listN(arena, "source_file", &.{});
    const r = try listN(arena, "source_file", &.{});

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "align: identical decls both sides → all Unchanged, moved null" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const foo_l = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const bar_l = try declN(arena, "fn", "bar", &.{atomN(.code, "2")});
    const foo_r = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const bar_r = try declN(arena, "fn", "bar", &.{atomN(.code, "2")});

    const l = try listN(arena, "source_file", &.{ foo_l, bar_l });
    const r = try listN(arena, "source_file", &.{ foo_r, bar_r });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expect(entries[0] == .unchanged);
    try testing.expect(entries[0].unchanged.moved == null);
    try testing.expectEqualStrings("foo", entries[0].unchanged.decl.name.?);
    try testing.expect(entries[1] == .unchanged);
    try testing.expect(entries[1].unchanged.moved == null);
    try testing.expectEqualStrings("bar", entries[1].unchanged.decl.name.?);
}

test "align: reorder only → Unchanged entries with moved populated" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const foo_l = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const bar_l = try declN(arena, "fn", "bar", &.{atomN(.code, "2")});
    const foo_r = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const bar_r = try declN(arena, "fn", "bar", &.{atomN(.code, "2")});

    const l = try listN(arena, "source_file", &.{ foo_l, bar_l });
    const r = try listN(arena, "source_file", &.{ bar_r, foo_r });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 2), entries.len);
    // Output follows right-side order: bar, then foo.
    try testing.expect(entries[0] == .unchanged);
    try testing.expectEqualStrings("bar", entries[0].unchanged.decl.name.?);
    try testing.expect(entries[0].unchanged.moved != null);
    try testing.expectEqual(@as(usize, 1), entries[0].unchanged.moved.?.from_idx);
    try testing.expectEqual(@as(usize, 0), entries[0].unchanged.moved.?.to_idx);

    try testing.expect(entries[1] == .unchanged);
    try testing.expectEqualStrings("foo", entries[1].unchanged.decl.name.?);
    try testing.expect(entries[1].unchanged.moved != null);
    try testing.expectEqual(@as(usize, 0), entries[1].unchanged.moved.?.from_idx);
    try testing.expectEqual(@as(usize, 1), entries[1].unchanged.moved.?.to_idx);
}

test "align: insert one Decl in middle → Added at correct position" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const foo_l = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const bar_l = try declN(arena, "fn", "bar", &.{atomN(.code, "2")});
    const foo_r = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const mid_r = try declN(arena, "fn", "mid", &.{atomN(.code, "m")});
    const bar_r = try declN(arena, "fn", "bar", &.{atomN(.code, "2")});

    const l = try listN(arena, "source_file", &.{ foo_l, bar_l });
    const r = try listN(arena, "source_file", &.{ foo_r, mid_r, bar_r });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expect(entries[0] == .unchanged);
    try testing.expectEqualStrings("foo", entries[0].unchanged.decl.name.?);
    try testing.expect(entries[1] == .added);
    try testing.expectEqualStrings("mid", entries[1].added.decl.name.?);
    try testing.expect(entries[2] == .unchanged);
    try testing.expectEqualStrings("bar", entries[2].unchanged.decl.name.?);
    try testing.expect(entries[2].unchanged.moved != null);
    try testing.expectEqual(@as(usize, 1), entries[2].unchanged.moved.?.from_idx);
    try testing.expectEqual(@as(usize, 2), entries[2].unchanged.moved.?.to_idx);
}

test "align: remove one Decl → Removed spliced near its anchor" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const foo_l = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const mid_l = try declN(arena, "fn", "mid", &.{atomN(.code, "m")});
    const bar_l = try declN(arena, "fn", "bar", &.{atomN(.code, "2")});
    const foo_r = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const bar_r = try declN(arena, "fn", "bar", &.{atomN(.code, "2")});

    const l = try listN(arena, "source_file", &.{ foo_l, mid_l, bar_l });
    const r = try listN(arena, "source_file", &.{ foo_r, bar_r });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expect(entries[0] == .unchanged);
    try testing.expectEqualStrings("foo", entries[0].unchanged.decl.name.?);
    // `mid` is spliced before `bar` (its next matched neighbour).
    try testing.expect(entries[1] == .removed);
    try testing.expectEqualStrings("mid", entries[1].removed.decl.name.?);
    try testing.expect(entries[2] == .unchanged);
    try testing.expectEqualStrings("bar", entries[2].unchanged.decl.name.?);
}

test "align: trailing removed Decl with no right anchor goes at end" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const foo_l = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const bar_l = try declN(arena, "fn", "bar", &.{atomN(.code, "2")});
    const foo_r = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});

    const l = try listN(arena, "source_file", &.{ foo_l, bar_l });
    const r = try listN(arena, "source_file", &.{foo_r});

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expect(entries[0] == .unchanged);
    try testing.expectEqualStrings("foo", entries[0].unchanged.decl.name.?);
    try testing.expect(entries[1] == .removed);
    try testing.expectEqualStrings("bar", entries[1].removed.decl.name.?);
}

test "align: same name different kind → Removed + Added (identity breaks)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const foo_fn = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const foo_const = try declN(arena, "const", "foo", &.{atomN(.code, "1")});

    const l = try listN(arena, "source_file", &.{foo_fn});
    const r = try listN(arena, "source_file", &.{foo_const});

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 2), entries.len);
    // Right-side first: Added(const foo), then Removed(fn foo) at the end
    // (no right-side anchor for the removal).
    try testing.expect(entries[0] == .added);
    try testing.expectEqualStrings("foo", entries[0].added.decl.name.?);
    try testing.expectEqualStrings("const", entries[0].added.decl.ts_kind);
    try testing.expect(entries[1] == .removed);
    try testing.expectEqualStrings("foo", entries[1].removed.decl.name.?);
    try testing.expectEqualStrings("fn", entries[1].removed.decl.ts_kind);
}

test "align: duplicate identity keys — two `impl Foo` blocks each side pair by occurrence" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Different body so each impl has a distinct hash, forcing Pass 2.
    const impl_l1 = try declN(arena, "impl", "Foo", &.{ try declN(arena, "fn", "a", &.{atomN(.code, "1")}) });
    const impl_l2 = try declN(arena, "impl", "Foo", &.{ try declN(arena, "fn", "b", &.{atomN(.code, "2")}) });
    const impl_r1 = try declN(arena, "impl", "Foo", &.{ try declN(arena, "fn", "a", &.{atomN(.code, "9")}) });
    const impl_r2 = try declN(arena, "impl", "Foo", &.{ try declN(arena, "fn", "b", &.{atomN(.code, "8")}) });

    const l = try listN(arena, "source_file", &.{ impl_l1, impl_l2 });
    const r = try listN(arena, "source_file", &.{ impl_r1, impl_r2 });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 2), entries.len);
    // Each impl pairs by occurrence: l[0]↔r[0], l[1]↔r[1].
    try testing.expect(entries[0] == .changed);
    try testing.expect(entries[0].changed.body == .container);
    try testing.expect(entries[0].changed.moved == null);
    try testing.expect(entries[1] == .changed);
    try testing.expect(entries[1].changed.body == .container);
    try testing.expect(entries[1].changed.moved == null);
}

test "align: leaf Decl body change → Changed with body.leaf, edit script non-empty" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const foo_l = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const foo_r = try declN(arena, "fn", "foo", &.{atomN(.code, "2")});

    const l = try listN(arena, "source_file", &.{foo_l});
    const r = try listN(arena, "source_file", &.{foo_r});

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(entries[0] == .changed);
    try testing.expect(entries[0].changed.body == .leaf);
    try testing.expect(entries[0].changed.body.leaf.edits.len > 0);
    try testing.expect(!entries[0].changed.body.leaf.isCommentOnly());
    try testing.expect(entries[0].changed.moved == null);
}

test "align: comment-only body change → Changed with body.leaf + isCommentOnly() == true" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Same code, left has one comment atom in body, right does not.
    const foo_l = try declN(arena, "fn", "foo", &.{ atomN(.comment, "// a"), atomN(.code, "1") });
    const foo_r = try declN(arena, "fn", "foo", &.{ atomN(.comment, "// b"), atomN(.code, "1") });

    const l = try listN(arena, "source_file", &.{foo_l});
    const r = try listN(arena, "source_file", &.{foo_r});

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(entries[0] == .changed);
    try testing.expect(entries[0].changed.body == .leaf);
    try testing.expect(entries[0].changed.body.leaf.isCommentOnly());
}

test "align: container Decl gains a child → Changed with body.container recurses" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m_l = try declN(arena, "fn", "m", &.{atomN(.code, "1")});
    const m_r = try declN(arena, "fn", "m", &.{atomN(.code, "1")});
    const n_r = try declN(arena, "fn", "n", &.{atomN(.code, "2")});

    const class_l = try declN(arena, "class", "C", &.{m_l});
    const class_r = try declN(arena, "class", "C", &.{ m_r, n_r });

    const l = try listN(arena, "source_file", &.{class_l});
    const r = try listN(arena, "source_file", &.{class_r});

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(entries[0] == .changed);
    try testing.expect(entries[0].changed.body == .container);

    const inner = entries[0].changed.body.container;
    try testing.expectEqual(@as(usize, 2), inner.len);
    try testing.expect(inner[0] == .unchanged);
    try testing.expectEqualStrings("m", inner[0].unchanged.decl.name.?);
    try testing.expect(inner[1] == .added);
    try testing.expectEqualStrings("n", inner[1].added.decl.name.?);
}

test "align: nested container (class inside mod) change → deeply nested body.container" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // mod M { class C { fn m; } } → mod M { class C { fn m; fn n; } }
    const m_l = try declN(arena, "fn", "m", &.{atomN(.code, "1")});
    const m_r = try declN(arena, "fn", "m", &.{atomN(.code, "1")});
    const n_r = try declN(arena, "fn", "n", &.{atomN(.code, "2")});
    const class_l = try declN(arena, "class", "C", &.{m_l});
    const class_r = try declN(arena, "class", "C", &.{ m_r, n_r });
    const mod_l = try declN(arena, "mod", "M", &.{class_l});
    const mod_r = try declN(arena, "mod", "M", &.{class_r});

    const l = try listN(arena, "source_file", &.{mod_l});
    const r = try listN(arena, "source_file", &.{mod_r});

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(entries[0] == .changed); // mod M changed
    try testing.expect(entries[0].changed.body == .container);
    const mod_inner = entries[0].changed.body.container;
    try testing.expectEqual(@as(usize, 1), mod_inner.len);
    try testing.expect(mod_inner[0] == .changed); // class C changed
    try testing.expect(mod_inner[0].changed.body == .container);
    const class_inner = mod_inner[0].changed.body.container;
    try testing.expectEqual(@as(usize, 2), class_inner.len);
    try testing.expect(class_inner[0] == .unchanged);
    try testing.expect(class_inner[1] == .added);
    try testing.expectEqualStrings("n", class_inner[1].added.decl.name.?);
}

test "align: 3 levels of container nesting with leaf change at bottom" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // mod A { mod B { class C { fn deep; } } } with body edit on `deep`.
    const deep_l = try declN(arena, "fn", "deep", &.{atomN(.code, "1")});
    const deep_r = try declN(arena, "fn", "deep", &.{atomN(.code, "2")});
    const class_l = try declN(arena, "class", "C", &.{deep_l});
    const class_r = try declN(arena, "class", "C", &.{deep_r});
    const mid_l = try declN(arena, "mod", "B", &.{class_l});
    const mid_r = try declN(arena, "mod", "B", &.{class_r});
    const outer_l = try declN(arena, "mod", "A", &.{mid_l});
    const outer_r = try declN(arena, "mod", "A", &.{mid_r});

    const l = try listN(arena, "source_file", &.{outer_l});
    const r = try listN(arena, "source_file", &.{outer_r});

    const entries = try alignRoots(arena, l, r);

    // Walk A → B → C → deep, asserting Changed+container at each level.
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(entries[0] == .changed);
    const a_body = entries[0].changed.body.container;
    try testing.expectEqual(@as(usize, 1), a_body.len);
    try testing.expect(a_body[0] == .changed);
    const b_body = a_body[0].changed.body.container;
    try testing.expectEqual(@as(usize, 1), b_body.len);
    try testing.expect(b_body[0] == .changed);
    const c_body = b_body[0].changed.body.container;
    try testing.expectEqual(@as(usize, 1), c_body.len);
    try testing.expect(c_body[0] == .changed);
    try testing.expect(c_body[0].changed.body == .leaf);
    try testing.expect(c_body[0].changed.body.leaf.edits.len > 0);
}

test "align: moved + changed — reorder + body edit on same Decl" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Left:  [foo_v1, bar]. Right: [bar, foo_v2].
    // foo's body changes AND its position moves.
    const foo_l = try declN(arena, "fn", "foo", &.{atomN(.code, "1")});
    const bar_l = try declN(arena, "fn", "bar", &.{atomN(.code, "b")});
    const bar_r = try declN(arena, "fn", "bar", &.{atomN(.code, "b")});
    const foo_r = try declN(arena, "fn", "foo", &.{atomN(.code, "2")});

    const l = try listN(arena, "source_file", &.{ foo_l, bar_l });
    const r = try listN(arena, "source_file", &.{ bar_r, foo_r });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 2), entries.len);
    // Right order: bar (unchanged, moved 1→0), foo (changed, moved 0→1).
    try testing.expect(entries[0] == .unchanged);
    try testing.expectEqualStrings("bar", entries[0].unchanged.decl.name.?);
    try testing.expect(entries[1] == .changed);
    try testing.expectEqualStrings("foo", entries[1].changed.new.name.?);
    try testing.expect(entries[1].changed.moved != null);
    try testing.expectEqual(@as(usize, 0), entries[1].changed.moved.?.from_idx);
    try testing.expectEqual(@as(usize, 1), entries[1].changed.moved.?.to_idx);
}

// ── Property tests ─────────────────────────────────────────────────────────

test "property: alignDecls(X, X) → all Unchanged, no moves" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try declN(arena, "fn", "a", &.{atomN(.code, "1")});
    const b = try declN(arena, "fn", "b", &.{atomN(.code, "2")});
    const c = try declN(arena, "fn", "c", &.{atomN(.code, "3")});

    const al = try declN(arena, "fn", "a", &.{atomN(.code, "1")});
    const bl = try declN(arena, "fn", "b", &.{atomN(.code, "2")});
    const cl = try declN(arena, "fn", "c", &.{atomN(.code, "3")});

    const l = try listN(arena, "source_file", &.{ a, b, c });
    const r = try listN(arena, "source_file", &.{ al, bl, cl });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 3), entries.len);
    for (entries) |e| {
        try testing.expect(e == .unchanged);
        try testing.expect(e.unchanged.moved == null);
    }
}

test "property: add exactly one Decl → exactly one Added, rest Unchanged" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a_l = try declN(arena, "fn", "a", &.{atomN(.code, "1")});
    const b_l = try declN(arena, "fn", "b", &.{atomN(.code, "2")});
    const a_r = try declN(arena, "fn", "a", &.{atomN(.code, "1")});
    const b_r = try declN(arena, "fn", "b", &.{atomN(.code, "2")});
    const c_r = try declN(arena, "fn", "c", &.{atomN(.code, "3")});

    const l = try listN(arena, "source_file", &.{ a_l, b_l });
    const r = try listN(arena, "source_file", &.{ a_r, b_r, c_r });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 3), entries.len);
    var added: usize = 0;
    var unchanged: usize = 0;
    for (entries) |e| switch (e) {
        .added => added += 1,
        .unchanged => unchanged += 1,
        else => try testing.expect(false),
    };
    try testing.expectEqual(@as(usize, 1), added);
    try testing.expectEqual(@as(usize, 2), unchanged);
}

test "property: remove exactly one Decl → exactly one Removed, rest Unchanged" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a_l = try declN(arena, "fn", "a", &.{atomN(.code, "1")});
    const b_l = try declN(arena, "fn", "b", &.{atomN(.code, "2")});
    const c_l = try declN(arena, "fn", "c", &.{atomN(.code, "3")});
    const a_r = try declN(arena, "fn", "a", &.{atomN(.code, "1")});
    const c_r = try declN(arena, "fn", "c", &.{atomN(.code, "3")});

    const l = try listN(arena, "source_file", &.{ a_l, b_l, c_l });
    const r = try listN(arena, "source_file", &.{ a_r, c_r });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 3), entries.len);
    var removed: usize = 0;
    var unchanged: usize = 0;
    for (entries) |e| switch (e) {
        .removed => removed += 1,
        .unchanged => unchanged += 1,
        else => try testing.expect(false),
    };
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(usize, 2), unchanged);
}

test "property: swap two Decls → all Unchanged, exactly two moved" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a_l = try declN(arena, "fn", "a", &.{atomN(.code, "1")});
    const b_l = try declN(arena, "fn", "b", &.{atomN(.code, "2")});
    const c_l = try declN(arena, "fn", "c", &.{atomN(.code, "3")});
    const a_r = try declN(arena, "fn", "a", &.{atomN(.code, "1")});
    const b_r = try declN(arena, "fn", "b", &.{atomN(.code, "2")});
    const c_r = try declN(arena, "fn", "c", &.{atomN(.code, "3")});

    // Swap a and c.
    const l = try listN(arena, "source_file", &.{ a_l, b_l, c_l });
    const r = try listN(arena, "source_file", &.{ c_r, b_r, a_r });

    const entries = try alignRoots(arena, l, r);
    try testing.expectEqual(@as(usize, 3), entries.len);
    var moved_count: usize = 0;
    for (entries) |e| {
        try testing.expect(e == .unchanged);
        if (e.unchanged.moved != null) moved_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), moved_count);
}

test "property: output ordering is deterministic across runs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build a mix of Added/Removed/Changed/Unchanged with and without moves.
    const l_decls = &[_]node.Node{
        try declN(arena, "fn", "kept", &.{atomN(.code, "1")}),
        try declN(arena, "fn", "removed", &.{atomN(.code, "r")}),
        try declN(arena, "fn", "changed", &.{atomN(.code, "old")}),
        try declN(arena, "fn", "moved", &.{atomN(.code, "m")}),
    };
    const r_decls = &[_]node.Node{
        try declN(arena, "fn", "moved", &.{atomN(.code, "m")}),
        try declN(arena, "fn", "kept", &.{atomN(.code, "1")}),
        try declN(arena, "fn", "added", &.{atomN(.code, "a")}),
        try declN(arena, "fn", "changed", &.{atomN(.code, "new")}),
    };

    const l1 = try listN(arena, "source_file", l_decls);
    const r1 = try listN(arena, "source_file", r_decls);
    const e1 = try alignRoots(arena, l1, r1);

    const l2 = try listN(arena, "source_file", l_decls);
    const r2 = try listN(arena, "source_file", r_decls);
    const e2 = try alignRoots(arena, l2, r2);

    try testing.expectEqual(e1.len, e2.len);
    for (e1, e2) |a, b| {
        try testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
        const name_a: ?[]const u8 = switch (a) {
            .unchanged => |u| u.decl.name,
            .added => |x| x.decl.name,
            .removed => |x| x.decl.name,
            .changed => |c| c.new.name,
        };
        const name_b: ?[]const u8 = switch (b) {
            .unchanged => |u| u.decl.name,
            .added => |x| x.decl.name,
            .removed => |x| x.decl.name,
            .changed => |c| c.new.name,
        };
        try testing.expect(nameEqual(name_a, name_b));
    }
}

// ── import-group alignment ───────────────────────────────────────────────
//
// These tests parse real Rust source so they exercise the full pipeline:
// the import_group_key / import_symbols hooks on `LangConfig` and the
// alignment integration in this file. They're the contract for the
// sub-task in dex 7hc4bs38.

const treez = @import("treez");
const convert = @import("../sst/convert.zig");
const rust = @import("../lang/rust.zig");

const RustAlignFixture = struct {
    left_ts: *treez.Tree,
    right_ts: *treez.Tree,
    entries: []const result.DeclDiff,

    fn deinit(self: *RustAlignFixture) void {
        self.left_ts.destroy();
        self.right_ts.destroy();
    }
};

fn alignRust(
    arena: std.mem.Allocator,
    left_src: []const u8,
    right_src: []const u8,
) !RustAlignFixture {
    const lang = try treez.Language.get("rust");
    const parser = try treez.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang);

    const left_ts = try parser.parseString(null, left_src);
    errdefer left_ts.destroy();
    const right_ts = try parser.parseString(null, right_src);
    errdefer right_ts.destroy();

    const left_res = try convert.fromTreeSitter(arena, left_ts, left_src, &rust.config);
    const right_res = try convert.fromTreeSitter(arena, right_ts, right_src, &rust.config);
    hash_mod.hashTree(left_res.tree);
    hash_mod.hashTree(right_res.tree);

    const entries = try alignDecls(
        arena,
        &rust.config,
        &left_res.tree.root.list,
        &right_res.tree.root.list,
        left_src,
        right_src,
    );
    return .{ .left_ts = left_ts, .right_ts = right_ts, .entries = entries };
}

fn expectImportGroup(
    entry: result.DeclDiff,
    expected_prefix: []const u8,
    expected: []const result.ImportSymbolEntry,
) !void {
    try testing.expect(entry == .changed);
    try testing.expect(entry.changed.body == .import_group);
    const ig = entry.changed.body.import_group;
    try testing.expectEqualStrings(expected_prefix, ig.prefix);
    try testing.expectEqual(expected.len, ig.entries.len);
    for (expected, ig.entries) |want, got| {
        try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
        const want_text = switch (want) {
            .kept => |s| s.text,
            .added => |s| s.text,
            .removed => |s| s.text,
        };
        const got_text = switch (got) {
            .kept => |s| s.text,
            .added => |s| s.text,
            .removed => |s| s.text,
        };
        try testing.expectEqualStrings(want_text, got_text);
    }
}

fn sym(text: []const u8) result.ImportSymbol {
    return .{ .text = text };
}

test "import-group: single-symbol → brace expansion (Serialize → Deserialize, Serialize)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use serde::Serialize;\n",
        "use serde::{Deserialize, Serialize};\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 1), fx.entries.len);
    try expectImportGroup(fx.entries[0], "serde", &.{
        .{ .added = sym("Deserialize") },
        .{ .kept = sym("Serialize") },
    });
}

test "import-group: brace → brace add only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use foo::{a, b};\n",
        "use foo::{a, b, c};\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 1), fx.entries.len);
    try expectImportGroup(fx.entries[0], "foo", &.{
        .{ .kept = sym("a") },
        .{ .kept = sym("b") },
        .{ .added = sym("c") },
    });
}

test "import-group: brace → brace remove only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use foo::{a, b, c};\n",
        "use foo::{a, c};\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 1), fx.entries.len);
    try expectImportGroup(fx.entries[0], "foo", &.{
        .{ .kept = sym("a") },
        .{ .removed = sym("b") },
        .{ .kept = sym("c") },
    });
}

test "import-group: brace → brace add and remove" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use foo::{a, b};\n",
        "use foo::{a, c};\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 1), fx.entries.len);
    try expectImportGroup(fx.entries[0], "foo", &.{
        .{ .kept = sym("a") },
        .{ .removed = sym("b") },
        .{ .added = sym("c") },
    });
}

test "import-group: single rename under same prefix" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use std::sync::Old;\n",
        "use std::sync::New;\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 1), fx.entries.len);
    try expectImportGroup(fx.entries[0], "std::sync", &.{
        .{ .removed = sym("Old") },
        .{ .added = sym("New") },
    });
}

test "import-group: different sub-prefixes don't merge" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use std::io::Write;\n",
        "use std::path::Path;\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 2), fx.entries.len);
    // Right-side first (added), then left-side trailing (removed).
    try testing.expect(fx.entries[0] == .added);
    try testing.expect(fx.entries[1] == .removed);
}

test "import-group: two same-prefix decls don't cross-pair" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use foo::A;\nuse foo::B;\n",
        "use foo::A;\nuse foo::C;\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 2), fx.entries.len);
    // `use foo::A;` is byte-identical → Unchanged.
    try testing.expect(fx.entries[0] == .unchanged);
    // `use foo::B;` and `use foo::C;` share identity "foo" at occ 1.
    try expectImportGroup(fx.entries[1], "foo", &.{
        .{ .removed = sym("B") },
        .{ .added = sym("C") },
    });
}

test "import-group: wildcard opts out" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use foo::*;\n",
        "use foo::{Bar};\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 2), fx.entries.len);
    // Different identities → not paired.
    try testing.expect(fx.entries[0] == .added);
    try testing.expect(fx.entries[1] == .removed);
}

test "import-group: pub use opts out" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use foo::Bar;\n",
        "pub use foo::Bar;\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 2), fx.entries.len);
    try testing.expect(fx.entries[0] == .added);
    try testing.expect(fx.entries[1] == .removed);
}

test "import-group: all-kept reorder demotes to Unchanged" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use foo::{a, b, c};\n",
        "use foo::{c, a, b};\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 1), fx.entries.len);
    try testing.expect(fx.entries[0] == .unchanged);
}

test "import-group: aliases are kept verbatim" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use foo::Bar as Baz;\n",
        "use foo::{Bar as Baz, Qux};\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 1), fx.entries.len);
    try expectImportGroup(fx.entries[0], "foo", &.{
        .{ .kept = sym("Bar as Baz") },
        .{ .added = sym("Qux") },
    });
}

test "import-group: self symbol" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try alignRust(
        arena,
        "use foo::{Bar};\n",
        "use foo::{self, Bar};\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 1), fx.entries.len);
    try expectImportGroup(fx.entries[0], "foo", &.{
        .{ .added = sym("self") },
        .{ .kept = sym("Bar") },
    });
}

test "import-group: single-segment use does not collide with prefixed use under same name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `use foo;` opts out of import-group alignment (single segment, key
    // returns null). Even though its extract_name happens to be "foo" -
    // matching the import-group key of `use foo::Bar;` on the right side -
    // the two must NOT pair: they live in separate identity namespaces.
    var fx = try alignRust(
        arena,
        "use foo;\n",
        "use foo::Bar;\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 2), fx.entries.len);
    try testing.expect(fx.entries[0] == .added);
    try testing.expect(fx.entries[1] == .removed);
}

test "import-group: use_declaration moved between top-level decls populates `moved`" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Same use line, different position relative to other top-level decls.
    var fx = try alignRust(
        arena,
        "use foo::Bar;\nfn x() {}\n",
        "fn x() {}\nuse foo::Bar;\n",
    );
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 2), fx.entries.len);
    // `fn x` first on the right side, unchanged with moved 1→0.
    try testing.expect(fx.entries[0] == .unchanged);
    try testing.expectEqualStrings("x", fx.entries[0].unchanged.decl.name.?);
    try testing.expect(fx.entries[0].unchanged.moved != null);

    // Then the use line: byte-identical content, so this is the hash-equal
    // Unchanged path — `moved` carries the index change orthogonally.
    try testing.expect(fx.entries[1] == .unchanged);
    try testing.expectEqualStrings("use_declaration", fx.entries[1].unchanged.decl.ts_kind);
    try testing.expect(fx.entries[1].unchanged.moved != null);
    try testing.expectEqual(@as(usize, 0), fx.entries[1].unchanged.moved.?.from_idx);
    try testing.expectEqual(@as(usize, 1), fx.entries[1].unchanged.moved.?.to_idx);
}

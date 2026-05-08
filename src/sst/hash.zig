//! SST content hashing.
//!
//! Pure-structural hash per Q8 - no language-aware normalisation.
//!
//! Hash of an Atom combines its `AtomKind` discriminant and its raw bytes.
//! Hash of a List combines its `ts_kind`, delimiters, children hashes, and
//! leading/trailing trivia hashes (so a doc-comment edit changes the
//! enclosing Decl's hash).

const std = @import("std");
const node = @import("node.zig");

// Distinct Wyhash seeds keep atom and list hash "spaces" from colliding
// pathologically when byte layouts happen to overlap. Values are arbitrary
// but must stay stable: two runs on the same SST must produce the same u64.
const atom_seed: u64 = 0xA70_A70_A70_A70A70;
const list_seed: u64 = 0x715_715_715_715715;

/// Fill the `hash` field on every node in `tree` in post-order. Must be
/// called before the diff engine reads any hashes. Deterministic.
pub fn hashTree(tree: *node.Tree) void {
    fillNode(&tree.root);
}

/// Compute a hash without mutating. The value is identical to whatever
/// `hashTree` would store in `n.hash` for the same subtree.
pub fn hashNode(n: node.Node) u64 {
    return switch (n) {
        .atom => |a| hashAtom(a),
        .list => |l| hashListPure(l),
    };
}

// ── internals ──────────────────────────────────────────────────────────────

/// Post-order mutator. Node slices in `node.List` are `[]const` because the
/// tree is immutable from the converter's point of view; the hash field is
/// the one deliberate exception, so we `@constCast` inside the list arms.
fn fillNode(n: *node.Node) void {
    switch (n.*) {
        .atom => {
            n.atom.hash = hashAtom(n.atom);
        },
        .list => {
            for (n.list.leading_trivia) |*t| {
                @constCast(t).hash = hashAtom(t.*);
            }
            for (n.list.children) |*c| {
                fillNode(@constCast(c));
            }
            for (n.list.trailing_trivia) |*t| {
                @constCast(t).hash = hashAtom(t.*);
            }
            n.list.hash = combineList(n.list);
        },
    }
}

fn hashAtom(a: node.Atom) u64 {
    var h: std.hash.Wyhash = .init(atom_seed);
    const tag: u8 = @intCast(@intFromEnum(a.kind));
    h.update(&[_]u8{tag});
    writeLenPrefixed(&h, a.bytes);
    return h.final();
}

/// Combines a list using already-filled child/trivia `hash` fields. Caller
/// must ensure every child and trivia atom has had its hash computed.
/// Kept separate from `hashListPure` so the `fillNode` walk stays O(n) —
/// using the pure version there would re-hash every descendant at every
/// level.
fn combineList(l: node.List) u64 {
    var h: std.hash.Wyhash = .init(list_seed);
    writeLenPrefixed(&h, l.ts_kind);
    writeLenPrefixed(&h, l.open_delim);
    writeLenPrefixed(&h, l.close_delim);

    writeU64(&h, l.leading_trivia.len);
    for (l.leading_trivia) |a| writeU64(&h, a.hash);

    writeU64(&h, l.children.len);
    for (l.children) |c| writeU64(&h, c.hash());

    writeU64(&h, l.trailing_trivia.len);
    for (l.trailing_trivia) |a| writeU64(&h, a.hash);

    return h.final();
}

/// Self-contained list hash: recomputes child and trivia hashes from
/// scratch. Used by the public `hashNode`, which must not require
/// `hashTree` to have run. Produces the same u64 as `combineList` would
/// after a full fill.
fn hashListPure(l: node.List) u64 {
    var h: std.hash.Wyhash = .init(list_seed);
    writeLenPrefixed(&h, l.ts_kind);
    writeLenPrefixed(&h, l.open_delim);
    writeLenPrefixed(&h, l.close_delim);

    writeU64(&h, l.leading_trivia.len);
    for (l.leading_trivia) |a| writeU64(&h, hashAtom(a));

    writeU64(&h, l.children.len);
    for (l.children) |c| writeU64(&h, hashNode(c));

    writeU64(&h, l.trailing_trivia.len);
    for (l.trailing_trivia) |a| writeU64(&h, hashAtom(a));

    return h.final();
}

fn writeLenPrefixed(h: *std.hash.Wyhash, s: []const u8) void {
    writeU64(h, s.len);
    h.update(s);
}

fn writeU64(h: *std.hash.Wyhash, v: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    h.update(&buf);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const treez = @import("treez");
const convert = @import("convert.zig");
const registry = @import("../lang/registry.zig");

fn parseZig(src: []const u8) !*treez.Tree {
    const lang = try treez.Language.get("zig");
    const parser = try treez.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang);
    return try parser.parseString(null, src);
}

const ZigFixture = struct {
    ts_tree: *treez.Tree,
    res: convert.ConvertResult,

    fn deinit(self: *ZigFixture) void {
        self.ts_tree.destroy();
    }
};

fn convertZig(arena: std.mem.Allocator, src: []const u8) !ZigFixture {
    const ts_tree = try parseZig(src);
    const cfg = registry.config(.zig);
    const res = try convert.fromTreeSitter(arena, ts_tree, src, cfg);
    return .{ .ts_tree = ts_tree, .res = res };
}

// ── Unit tests: hashTree fills every node ──────────────────────────────────

test "hashTree: fills every node (all hashes != 0)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const src = "// doc\nfn foo(a: u32) void { const x = 1; _ = a; _ = x; }";
    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    hashTree(fx.res.tree);
    try expectAllHashed(fx.res.tree.root);
}

test "hashTree: identical SSTs produce identical root hash" {
    var arena_a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_a.deinit();
    var arena_b: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_b.deinit();

    const src = "fn foo() void { const x = 42; _ = x; }";
    var a = try convertZig(arena_a.allocator(), src);
    defer a.deinit();
    var b = try convertZig(arena_b.allocator(), src);
    defer b.deinit();

    hashTree(a.res.tree);
    hashTree(b.res.tree);
    try testing.expectEqual(a.res.tree.root.hash(), b.res.tree.root.hash());
}

// ── Unit tests: individual fields influence the hash ───────────────────────

test "hashNode: AtomKind affects hash (same bytes, .code vs .comment)" {
    const code_atom: node.Atom = .{
        .kind = .code,
        .bytes = "// x",
        .byte_range = .{ .start = 0, .end = 4 },
        .hash = 0,
    };
    const comment_atom: node.Atom = .{
        .kind = .comment,
        .bytes = "// x",
        .byte_range = .{ .start = 0, .end = 4 },
        .hash = 0,
    };
    try testing.expect(
        hashNode(.{ .atom = code_atom }) != hashNode(.{ .atom = comment_atom }),
    );
}

test "hashNode: List ts_kind affects hash" {
    const child = atomNode("x");
    const children = [_]node.Node{child};

    const a = makeList("function_declaration", "", "", &children, &.{}, &.{});
    const b = makeList("variable_declaration", "", "", &children, &.{}, &.{});

    try testing.expect(hashNode(.{ .list = a }) != hashNode(.{ .list = b }));
}

test "hashNode: delimiters affect hash — (a) vs [a]" {
    const child = atomNode("a");
    const children = [_]node.Node{child};

    const paren = makeList("wrap", "(", ")", &children, &.{}, &.{});
    const brack = makeList("wrap", "[", "]", &children, &.{}, &.{});

    try testing.expect(hashNode(.{ .list = paren }) != hashNode(.{ .list = brack }));
}

test "hashNode: child order matters — [a, b] vs [b, a]" {
    const a = atomNode("a");
    const b = atomNode("b");
    const ab = [_]node.Node{ a, b };
    const ba = [_]node.Node{ b, a };

    const list_ab = makeList("seq", "", "", &ab, &.{}, &.{});
    const list_ba = makeList("seq", "", "", &ba, &.{}, &.{});

    try testing.expect(hashNode(.{ .list = list_ab }) != hashNode(.{ .list = list_ba }));
}

test "hashNode: leading_trivia affects hash" {
    const child = atomNode("x");
    const children = [_]node.Node{child};
    const comment = [_]node.Atom{.{
        .kind = .comment,
        .bytes = "// lead",
        .byte_range = .{ .start = 0, .end = 7 },
        .hash = 0,
    }};

    const plain = makeList("w", "", "", &children, &.{}, &.{});
    const with_lead = makeList("w", "", "", &children, &comment, &.{});

    try testing.expect(hashNode(.{ .list = plain }) != hashNode(.{ .list = with_lead }));
}

test "hashNode: trailing_trivia affects hash" {
    const child = atomNode("x");
    const children = [_]node.Node{child};
    const comment = [_]node.Atom{.{
        .kind = .comment,
        .bytes = "// trail",
        .byte_range = .{ .start = 0, .end = 8 },
        .hash = 0,
    }};

    const plain = makeList("w", "", "", &children, &.{}, &.{});
    const with_trail = makeList("w", "", "", &children, &.{}, &comment);

    try testing.expect(hashNode(.{ .list = plain }) != hashNode(.{ .list = with_trail }));
}

// ── Property tests ─────────────────────────────────────────────────────────

test "property: determinism — same input hashed twice yields same hash" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const src = "// a\nfn foo(a: u32, b: u32) void { _ = a; _ = b; }";
    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    const h1 = hashNode(fx.res.tree.root);
    const h2 = hashNode(fx.res.tree.root);
    try testing.expectEqual(h1, h2);
}

test "property: hash equality holds for structurally equal SSTs (whitespace-only reformat)" {
    var arena_a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_a.deinit();
    var arena_b: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_b.deinit();

    // Whitespace between tokens is dropped during conversion, so the two
    // sources produce structurally identical SSTs and must hash equal.
    var a = try convertZig(arena_a.allocator(), "fn foo() void {}");
    defer a.deinit();
    var b = try convertZig(arena_b.allocator(), "fn foo (  )  void  { }");
    defer b.deinit();

    hashTree(a.res.tree);
    hashTree(b.res.tree);
    try testing.expectEqual(a.res.tree.root.hash(), b.res.tree.root.hash());
}

test "property: mutating any field changes the hash" {
    // Rename function: body unchanged, but the identifier atom differs.
    var arena_a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_a.deinit();
    var arena_b: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_b.deinit();

    var a = try convertZig(arena_a.allocator(), "fn foo() void {}");
    defer a.deinit();
    var b = try convertZig(arena_b.allocator(), "fn bar() void {}");
    defer b.deinit();

    try testing.expect(hashNode(a.res.tree.root) != hashNode(b.res.tree.root));
}

test "property: hashTree is idempotent" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const src = "// top\nfn foo(a: u32) void { _ = a; }";
    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    hashTree(fx.res.tree);
    var before: std.ArrayList(u64) = .empty;
    defer before.deinit(testing.allocator);
    try collectHashes(fx.res.tree.root, testing.allocator, &before);

    hashTree(fx.res.tree);
    var after: std.ArrayList(u64) = .empty;
    defer after.deinit(testing.allocator);
    try collectHashes(fx.res.tree.root, testing.allocator, &after);

    try testing.expectEqualSlices(u64, before.items, after.items);
}

test "property: hashTree root matches pure hashNode on root" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const src = "// a\nfn foo() void { const x = 1; _ = x; }";
    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    const pure = hashNode(fx.res.tree.root);
    hashTree(fx.res.tree);
    try testing.expectEqual(pure, fx.res.tree.root.hash());
}

// ── helpers ────────────────────────────────────────────────────────────────

fn atomNode(bytes: []const u8) node.Node {
    return .{ .atom = .{
        .kind = .code,
        .bytes = bytes,
        .byte_range = .{ .start = 0, .end = @intCast(bytes.len) },
        .hash = 0,
    } };
}

fn makeList(
    ts_kind: []const u8,
    open_delim: []const u8,
    close_delim: []const u8,
    children: []const node.Node,
    leading_trivia: []const node.Atom,
    trailing_trivia: []const node.Atom,
) node.List {
    return .{
        .ts_kind = ts_kind,
        .open_delim = open_delim,
        .close_delim = close_delim,
        .children = children,
        .leading_trivia = leading_trivia,
        .trailing_trivia = trailing_trivia,
        .byte_range = .{ .start = 0, .end = 0 },
        .hash = 0,
    };
}

fn expectAllHashed(n: node.Node) !void {
    switch (n) {
        .atom => |a| try testing.expect(a.hash != 0),
        .list => |l| {
            try testing.expect(l.hash != 0);
            for (l.leading_trivia) |t| try testing.expect(t.hash != 0);
            for (l.children) |c| try expectAllHashed(c);
            for (l.trailing_trivia) |t| try testing.expect(t.hash != 0);
        },
    }
}

fn collectHashes(n: node.Node, alloc: std.mem.Allocator, out: *std.ArrayList(u64)) !void {
    switch (n) {
        .atom => |a| try out.append(alloc, a.hash),
        .list => |l| {
            try out.append(alloc, l.hash);
            for (l.leading_trivia) |t| try out.append(alloc, t.hash);
            for (l.children) |c| try collectHashes(c, alloc, out);
            for (l.trailing_trivia) |t| try out.append(alloc, t.hash);
        },
    }
}

//! Dijkstra-based leaf-body diffing.
//!
//! Implements the graph-search described in difftastic/autochrome: vertices
//! are pairs of cursors over two SST subtrees plus per-cursor stacks of
//! pending parent return positions; edges are match-advance, novel-L,
//! novel-R, descend-both, descend-L, descend-R, pop-L, pop-R; costs bias
//! toward matches and toward matched-movement over single-cursor movement.
//!
//! Used only for leaf Decls' body_diff. Container Decls recurse via
//! `align.zig` instead.

const std = @import("std");
const node = @import("../sst/node.zig");
const edit = @import("edit.zig");

pub const DiffError = error{
    OutOfMemory,
};

// Cost model (matches autochrome):
//   match          = 0          (zero-cost pairing of two hash-equal subtrees)
//   descend-both   = 1          (paired structural descent)
//   descend-single = 2          (single-cursor descent into extra nesting)
//   novel          = size + 1   (the +1 biases toward fewer, bigger changes)
//   pop            = 0
const cost_match: u64 = 0;
const cost_descend_both: u64 = 1;
const cost_descend_single: u64 = 2;
const cost_pop: u64 = 0;

/// Produce the lowest-cost `EditScript` transforming `left` into `right`.
///
/// Relies on `hash` having been filled on all nodes (see `sst/hash.zig`);
/// equal hashes short-circuit to `match` edges at zero cost.
///
/// The returned script is arena-allocated via `arena`.
pub fn diffNodes(
    arena: std.mem.Allocator,
    left: *const node.Node,
    right: *const node.Node,
) DiffError!edit.EditScript {
    // Hash short-circuit at the root: two identical subtrees match as a
    // whole, no search needed.
    if (left.hash() == right.hash()) {
        const edits = try arena.alloc(edit.Edit, 1);
        edits[0] = .{ .match = .{ .left = left, .right = right } };
        return .{ .edits = edits, .total_cost = 0 };
    }

    // Wrap each root in a virtual outer List so every cursor is always
    // positioned inside *some* List. The virtual list's `children` slice
    // aliases the caller's node memory (via pointer cast), so node
    // references emitted as edits remain pointer-equal to the inputs.
    const virt_l = try wrapRoot(arena, left);
    const virt_r = try wrapRoot(arena, right);

    var visited: std.AutoHashMapUnmanaged(StateKey, void) = .empty;
    defer visited.deinit(arena);

    var pq: PQ = .empty;
    defer pq.deinit(arena);

    const start = try arena.create(Record);
    start.* = .{
        .cost = 0,
        .prev = null,
        .edit = null,
        .state = .{
            .left = .{ .list = virt_l, .idx = 0 },
            .right = .{ .list = virt_r, .idx = 0 },
            .stack_left = null,
            .stack_right = null,
        },
    };
    try pq.push(arena, .{ .cost = 0, .record = start });

    var goal: ?*const Record = null;
    while (pq.pop()) |item| {
        const rec = item.record;
        const key = keyOf(rec.state);
        const gop = try visited.getOrPut(arena, key);
        if (gop.found_existing) continue;
        if (isGoal(rec.state)) {
            goal = rec;
            break;
        }
        try expand(arena, &pq, rec);
    }

    // Goal is always reachable: all-novel is a finite-cost fallback path.
    const g = goal.?;

    // Reconstruct path by walking back from the goal.
    var edits_list: std.ArrayList(edit.Edit) = .empty;
    defer edits_list.deinit(arena);
    var cur: ?*const Record = g;
    while (cur) |r| : (cur = r.prev) {
        if (r.edit) |e| try edits_list.append(arena, e);
    }
    std.mem.reverse(edit.Edit, edits_list.items);

    const edits = try edits_list.toOwnedSlice(arena);
    return .{ .edits = edits, .total_cost = g.cost };
}

// ── internals ──────────────────────────────────────────────────────────────

/// Position inside a List: pointer + child index. `idx == list.children.len`
/// means past-the-end, which triggers a `pop` edge.
const Cursor = struct {
    list: *const node.List,
    idx: u32,

    fn pastEnd(self: Cursor) bool {
        return self.idx >= self.list.children.len;
    }

    fn currentPtr(self: Cursor) ?*const node.Node {
        if (self.pastEnd()) return null;
        return &self.list.children[self.idx];
    }

    fn advance(self: Cursor) Cursor {
        return .{ .list = self.list, .idx = self.idx + 1 };
    }
};

/// Persistent linked-list frame for parent-return stacks. Sharing via `tail`
/// keeps `descend` cheap; the rolling `hash` lets us key visited-state on
/// the whole stack without copying it into a hashmap key.
const Frame = struct {
    tail: ?*const Frame,
    cursor: Cursor,
    hash: u64,
};

const frame_seed: u64 = 0xF1A_F1A_F1A_F1A_F1AF;

fn stackHash(f: ?*const Frame) u64 {
    return if (f) |fr| fr.hash else 0;
}

fn pushFrame(
    arena: std.mem.Allocator,
    tail: ?*const Frame,
    cur: Cursor,
) !*const Frame {
    var h: std.hash.Wyhash = .init(frame_seed);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, stackHash(tail), .little);
    h.update(&buf);
    std.mem.writeInt(u64, &buf, @intFromPtr(cur.list), .little);
    h.update(&buf);
    std.mem.writeInt(u64, &buf, @as(u64, cur.idx), .little);
    h.update(&buf);

    const frame = try arena.create(Frame);
    frame.* = .{
        .tail = tail,
        .cursor = cur,
        .hash = h.final(),
    };
    return frame;
}

const State = struct {
    left: Cursor,
    right: Cursor,
    stack_left: ?*const Frame,
    stack_right: ?*const Frame,
};

const StateKey = struct {
    left_list: usize,
    left_idx: u32,
    right_list: usize,
    right_idx: u32,
    stack_left_hash: u64,
    stack_right_hash: u64,
};

fn keyOf(s: State) StateKey {
    return .{
        .left_list = @intFromPtr(s.left.list),
        .left_idx = s.left.idx,
        .right_list = @intFromPtr(s.right.list),
        .right_idx = s.right.idx,
        .stack_left_hash = stackHash(s.stack_left),
        .stack_right_hash = stackHash(s.stack_right),
    };
}

/// Each Record is a node in the predecessor DAG we walk to reconstruct the
/// final edit script. Kept immutable after creation.
const Record = struct {
    cost: u64,
    prev: ?*const Record,
    state: State,
    /// The edit emitted on the edge `prev → this`. Null for edges that only
    /// move cursors (descend, pop).
    edit: ?edit.Edit,
};

const QItem = struct {
    cost: u64,
    record: *const Record,
};

fn compareQ(_: void, a: QItem, b: QItem) std.math.Order {
    return std.math.order(a.cost, b.cost);
}

const PQ = std.PriorityQueue(QItem, void, compareQ);

fn isGoal(s: State) bool {
    return s.left.pastEnd() and s.right.pastEnd() and
        s.stack_left == null and s.stack_right == null;
}

fn sizeOfNode(n: node.Node) u64 {
    return switch (n) {
        .atom => 1,
        .list => |l| blk: {
            var s: u64 = 1;
            for (l.children) |c| s += sizeOfNode(c);
            break :blk s;
        },
    };
}

/// Produce a one-child virtual List whose single child aliases the caller's
/// Node via pointer cast (not a copy). This preserves pointer identity of
/// any node reachable from the virtual list, so emitted edits keep referring
/// to the original tree's nodes.
fn wrapRoot(arena: std.mem.Allocator, root: *const node.Node) !*const node.List {
    const many: [*]const node.Node = @ptrCast(root);
    const children: []const node.Node = many[0..1];
    const list = try arena.create(node.List);
    list.* = .{
        .ts_kind = "",
        .open_delim = "",
        .close_delim = "",
        .children = children,
        .leading_trivia = &.{},
        .trailing_trivia = &.{},
        .byte_range = root.byteRange(),
        .hash = 0,
    };
    return list;
}

/// Enumerate outgoing edges of `rec`'s state and push each resulting state
/// onto the priority queue. Edges are lazy; we don't materialise the whole
/// graph.
fn expand(
    arena: std.mem.Allocator,
    pq: *PQ,
    rec: *const Record,
) !void {
    const s = rec.state;

    // ── Pop edges: resume parent cursor once children are exhausted.
    if (s.left.pastEnd()) {
        if (s.stack_left) |top| {
            try enqueue(arena, pq, rec, .{
                .left = top.cursor,
                .right = s.right,
                .stack_left = top.tail,
                .stack_right = s.stack_right,
            }, null, cost_pop);
        }
    }
    if (s.right.pastEnd()) {
        if (s.stack_right) |top| {
            try enqueue(arena, pq, rec, .{
                .left = s.left,
                .right = top.cursor,
                .stack_left = s.stack_left,
                .stack_right = top.tail,
            }, null, cost_pop);
        }
    }

    const l_cur = s.left.currentPtr();
    const r_cur = s.right.currentPtr();

    // ── Two-sided edges: match-advance and descend-both.
    if (l_cur != null and r_cur != null) {
        const ln = l_cur.?;
        const rn = r_cur.?;

        if (ln.hash() == rn.hash()) {
            // match-advance: consumes both subtrees as a pair (hash short-
            // circuit for lists; no descent needed).
            try enqueue(arena, pq, rec, .{
                .left = s.left.advance(),
                .right = s.right.advance(),
                .stack_left = s.stack_left,
                .stack_right = s.stack_right,
            }, .{ .match = .{ .left = ln, .right = rn } }, cost_match);
        } else if (ln.* == .list and rn.* == .list) {
            const ll = &ln.list;
            const rl = &rn.list;
            if (std.mem.eql(u8, ll.ts_kind, rl.ts_kind) and
                std.mem.eql(u8, ll.open_delim, rl.open_delim) and
                std.mem.eql(u8, ll.close_delim, rl.close_delim))
            {
                // descend-both: paired structural descent. The wrapper list
                // "matches" implicitly; only its contents produce edits.
                const new_stk_l = try pushFrame(arena, s.stack_left, s.left.advance());
                const new_stk_r = try pushFrame(arena, s.stack_right, s.right.advance());
                try enqueue(arena, pq, rec, .{
                    .left = .{ .list = ll, .idx = 0 },
                    .right = .{ .list = rl, .idx = 0 },
                    .stack_left = new_stk_l,
                    .stack_right = new_stk_r,
                }, null, cost_descend_both);
            }
        }
    }

    // ── Novel-L.
    if (l_cur) |ln| {
        try enqueue(arena, pq, rec, .{
            .left = s.left.advance(),
            .right = s.right,
            .stack_left = s.stack_left,
            .stack_right = s.stack_right,
        }, .{ .novel = .{ .side = .left, .node_ref = ln } }, sizeOfNode(ln.*) + 1);
    }

    // ── Novel-R.
    if (r_cur) |rn| {
        try enqueue(arena, pq, rec, .{
            .left = s.left,
            .right = s.right.advance(),
            .stack_left = s.stack_left,
            .stack_right = s.stack_right,
        }, .{ .novel = .{ .side = .right, .node_ref = rn } }, sizeOfNode(rn.*) + 1);
    }

    // ── Descend-L: extra nesting on the left that the right doesn't share.
    if (l_cur) |ln| {
        if (ln.* == .list) {
            const ll = &ln.list;
            const new_stk_l = try pushFrame(arena, s.stack_left, s.left.advance());
            try enqueue(arena, pq, rec, .{
                .left = .{ .list = ll, .idx = 0 },
                .right = s.right,
                .stack_left = new_stk_l,
                .stack_right = s.stack_right,
            }, null, cost_descend_single);
        }
    }

    // ── Descend-R: extra nesting on the right (paren-wrap case).
    if (r_cur) |rn| {
        if (rn.* == .list) {
            const rl = &rn.list;
            const new_stk_r = try pushFrame(arena, s.stack_right, s.right.advance());
            try enqueue(arena, pq, rec, .{
                .left = s.left,
                .right = .{ .list = rl, .idx = 0 },
                .stack_left = s.stack_left,
                .stack_right = new_stk_r,
            }, null, cost_descend_single);
        }
    }
}

fn enqueue(
    arena: std.mem.Allocator,
    pq: *PQ,
    prev: *const Record,
    new_state: State,
    e: ?edit.Edit,
    edge_cost: u64,
) !void {
    const cost = prev.cost + edge_cost;
    const rec = try arena.create(Record);
    rec.* = .{
        .cost = cost,
        .prev = prev,
        .state = new_state,
        .edit = e,
    };
    try pq.push(arena, .{ .cost = cost, .record = rec });
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const hash_mod = @import("../sst/hash.zig");

// Tiny SST builders. All allocations (children slices, list/atom structs)
// use the test's arena. We build Trees to get `hashTree` to fill in hashes.

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
    open: []const u8,
    close: []const u8,
    children: []const node.Node,
) !node.Node {
    const child_slice = try arena.dupe(node.Node, children);
    return .{ .list = .{
        .ts_kind = ts_kind,
        .open_delim = open,
        .close_delim = close,
        .children = child_slice,
        .leading_trivia = &.{},
        .trailing_trivia = &.{},
        .byte_range = .{ .start = 0, .end = 0 },
        .hash = 0,
    } };
}

fn hashed(arena: std.mem.Allocator, root: node.Node) !*node.Tree {
    const t = try arena.create(node.Tree);
    t.* = .{ .root = root, .source = "" };
    hash_mod.hashTree(t);
    return t;
}

fn countEdits(script: edit.EditScript, tag: std.meta.Tag(edit.Edit)) usize {
    var n: usize = 0;
    for (script.edits) |e| if (std.meta.activeTag(e) == tag) {
        n += 1;
    };
    return n;
}

fn countNovelBySide(script: edit.EditScript, side: edit.Side) usize {
    var n: usize = 0;
    for (script.edits) |e| switch (e) {
        .novel => |nv| if (nv.side == side) {
            n += 1;
        },
        else => {},
    };
    return n;
}

// ── Unit tests ─────────────────────────────────────────────────────────────

test "diffNodes: identical atoms yield single match, zero cost" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a_l = atomN(.code, "x");
    const a_r = atomN(.code, "x");
    const tl = try hashed(arena, a_l);
    const tr = try hashed(arena, a_r);

    const script = try diffNodes(arena, &tl.root, &tr.root);
    try testing.expectEqual(@as(u64, 0), script.total_cost);
    try testing.expectEqual(@as(usize, 1), script.edits.len);
    try testing.expect(script.edits[0] == .match);
    try testing.expect(script.edits[0].match.left == &tl.root);
    try testing.expect(script.edits[0].match.right == &tr.root);
}

test "diffNodes: identical non-trivial SST yields empty-ish script, cost 0" {
    // Build the same nested structure on both sides; the hash short-circuit
    // must collapse the whole thing into one match edit.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const make = struct {
        fn go(a: std.mem.Allocator) !node.Node {
            const a1 = atomN(.code, "a");
            const a2 = atomN(.code, "b");
            const inner = try listN(a, "inner", "(", ")", &.{ a1, a2 });
            const a3 = atomN(.code, "c");
            return try listN(a, "outer", "{", "}", &.{ inner, a3 });
        }
    };

    const tl = try hashed(arena, try make.go(arena));
    const tr = try hashed(arena, try make.go(arena));

    const script = try diffNodes(arena, &tl.root, &tr.root);
    try testing.expectEqual(@as(u64, 0), script.total_cost);
    try testing.expectEqual(@as(usize, 0), countEdits(script, .novel));
}

test "diffNodes: single atom difference `[a, b]` vs `[a, c]`" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const l_a = atomN(.code, "a");
    const l_b = atomN(.code, "b");
    const l_list = try listN(arena, "seq", "[", "]", &.{ l_a, l_b });

    const r_a = atomN(.code, "a");
    const r_c = atomN(.code, "c");
    const r_list = try listN(arena, "seq", "[", "]", &.{ r_a, r_c });

    const tl = try hashed(arena, l_list);
    const tr = try hashed(arena, r_list);

    const script = try diffNodes(arena, &tl.root, &tr.root);

    // Exactly: 1 match on `a`, 1 novel-L on `b`, 1 novel-R on `c`.
    try testing.expectEqual(@as(usize, 1), countEdits(script, .match));
    try testing.expectEqual(@as(usize, 1), countNovelBySide(script, .left));
    try testing.expectEqual(@as(usize, 1), countNovelBySide(script, .right));

    // Verify the novel references point at the expected atoms.
    for (script.edits) |e| switch (e) {
        .novel => |nv| {
            const ref = nv.node_ref;
            try testing.expect(ref.* == .atom);
            const bytes = ref.atom.bytes;
            if (nv.side == .left) try testing.expectEqualStrings("b", bytes);
            if (nv.side == .right) try testing.expectEqualStrings("c", bytes);
        },
        .match => |m| {
            try testing.expect(m.left.* == .atom);
            try testing.expectEqualStrings("a", m.left.atom.bytes);
            try testing.expectEqualStrings("a", m.right.atom.bytes);
        },
    };
}

test "diffNodes: paren wrap `a` vs `(a)` prefers descend+match over full replace" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a_left = atomN(.code, "a");
    const a_right = atomN(.code, "a");
    const wrap = try listN(arena, "paren", "(", ")", &.{a_right});

    const tl = try hashed(arena, a_left);
    const tr = try hashed(arena, wrap);

    const script = try diffNodes(arena, &tl.root, &tr.root);

    // Full replace = novel-L(size 1)+1 + novel-R(size 2)+1 = 2 + 3 = 5.
    // descend-R (2) + match (0) = 2. Strictly less.
    try testing.expect(script.total_cost < 5);

    // Must include a match edit on the inner `a`s.
    try testing.expectEqual(@as(usize, 1), countEdits(script, .match));
    try testing.expectEqual(@as(usize, 0), countEdits(script, .novel));
}

test "diffNodes: shared deep subtree short-circuits via hash (zero cost for that descent)" {
    // Left and right each wrap the *same shape* of deep subtree in a
    // different outer shell. The deep subtree must match at zero cost.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build the deep subtree twice (same shape → same hash).
    const deep_left = blk: {
        const a = atomN(.code, "x");
        const b = atomN(.code, "y");
        const c = atomN(.code, "z");
        const l1 = try listN(arena, "inner", "[", "]", &.{ b, c });
        break :blk try listN(arena, "deep", "(", ")", &.{ a, l1 });
    };
    const deep_right = blk: {
        const a = atomN(.code, "x");
        const b = atomN(.code, "y");
        const c = atomN(.code, "z");
        const l1 = try listN(arena, "inner", "[", "]", &.{ b, c });
        break :blk try listN(arena, "deep", "(", ")", &.{ a, l1 });
    };

    // Different outer shells that both contain the deep subtree at index 0.
    const left_extra = atomN(.code, "L");
    const right_extra = atomN(.code, "R");
    const l_root = try listN(arena, "outer", "{", "}", &.{ deep_left, left_extra });
    const r_root = try listN(arena, "outer", "{", "}", &.{ deep_right, right_extra });

    const tl = try hashed(arena, l_root);
    const tr = try hashed(arena, r_root);

    const script = try diffNodes(arena, &tl.root, &tr.root);

    // The deep subtree pair must appear as a match, and the only novel edits
    // must be on the "L"/"R" atoms.
    var saw_deep_match = false;
    for (script.edits) |e| switch (e) {
        .match => |m| {
            if (m.left.* == .list and std.mem.eql(u8, m.left.list.ts_kind, "deep")) {
                saw_deep_match = true;
            }
        },
        .novel => |nv| {
            try testing.expect(nv.node_ref.* == .atom);
            const b = nv.node_ref.atom.bytes;
            try testing.expect(std.mem.eql(u8, b, "L") or std.mem.eql(u8, b, "R"));
        },
    };
    try testing.expect(saw_deep_match);

    // The expensive path (novel whole-outer on each side) would cost at
    // least (size_left + 1) + (size_right + 1). Each outer has 6 nodes
    // (outer + deep + x + inner + y + z + extra = 7, +1 = 8 each → 16).
    // Our actual cost should be far smaller (just the two atom novels and
    // one descend-both). Check upper bound to prove short-circuit ran.
    try testing.expect(script.total_cost < 8);
}

test "diffNodes: symmetric cost under side swap" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a1 = atomN(.code, "a");
    const a2 = atomN(.code, "b");
    const a3 = atomN(.code, "c");
    const left = try listN(arena, "seq", "(", ")", &.{ a1, a2 });
    const right = try listN(arena, "seq", "(", ")", &.{ a1, a3 });

    const tl = try hashed(arena, left);
    const tr = try hashed(arena, right);

    const ab = try diffNodes(arena, &tl.root, &tr.root);
    const ba = try diffNodes(arena, &tr.root, &tl.root);
    try testing.expectEqual(ab.total_cost, ba.total_cost);
}

// ── Property tests ─────────────────────────────────────────────────────────

test "property: diffNodes(A, A) emits zero novel edges" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = atomN(.code, "x");
    const b = atomN(.code, "y");
    const c = atomN(.code, "z");
    const inner = try listN(arena, "inner", "[", "]", &.{ b, c });
    const outer = try listN(arena, "outer", "{", "}", &.{ a, inner });

    const tl = try hashed(arena, outer);
    // Reuse the same tree on both sides.
    const script = try diffNodes(arena, &tl.root, &tl.root);
    try testing.expectEqual(@as(u64, 0), script.total_cost);
    try testing.expectEqual(@as(usize, 0), countEdits(script, .novel));
}

test "property: novel-edge count ≤ sum of subtree sizes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const la = atomN(.code, "a");
    const lb = atomN(.code, "b");
    const lc = atomN(.code, "c");
    const ll = try listN(arena, "seq", "(", ")", &.{ la, lb, lc });

    const ra = atomN(.code, "x");
    const rb = atomN(.code, "y");
    const rl = try listN(arena, "seq", "(", ")", &.{ ra, rb });

    const tl = try hashed(arena, ll);
    const tr = try hashed(arena, rl);

    const script = try diffNodes(arena, &tl.root, &tr.root);

    const total_size = sizeOfNode(tl.root) + sizeOfNode(tr.root);
    try testing.expect(@as(u64, @intCast(countEdits(script, .novel))) <= total_size);
}

test "property: every edit node lies within its side's tree" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const la = atomN(.code, "a");
    const lb = atomN(.code, "b");
    const ll = try listN(arena, "seq", "(", ")", &.{ la, lb });

    const ra = atomN(.code, "a");
    const rc = atomN(.code, "c");
    const rl = try listN(arena, "seq", "(", ")", &.{ ra, rc });

    const tl = try hashed(arena, ll);
    const tr = try hashed(arena, rl);

    const script = try diffNodes(arena, &tl.root, &tr.root);

    for (script.edits) |e| switch (e) {
        .match => |m| {
            try testing.expect(nodeReachable(&tl.root, m.left));
            try testing.expect(nodeReachable(&tr.root, m.right));
        },
        .novel => |nv| {
            const reachable = switch (nv.side) {
                .left => nodeReachable(&tl.root, nv.node_ref),
                .right => nodeReachable(&tr.root, nv.node_ref),
            };
            try testing.expect(reachable);
        },
    };
}

fn nodeReachable(root: *const node.Node, target: *const node.Node) bool {
    if (root == target) return true;
    switch (root.*) {
        .atom => return false,
        .list => |l| {
            for (l.children) |*c| {
                if (nodeReachable(c, target)) return true;
            }
            return false;
        },
    }
}

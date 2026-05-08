//! Tree-sitter → SST conversion.
//!
//! Walks a tree-sitter parse tree and produces an `sst.Tree` according to a
//! `LangConfig`. Responsibilities:
//!
//! 1. Flatten TS nodes listed in `atom_ts_kinds` into single Atoms even if
//!    they have children (e.g. string literals whose grammar splits them).
//! 2. Consume TS tokens listed in `delimiter_ts_kinds` as the open/close
//!    delimiters of their enclosing List rather than emitting them as child
//!    atoms.
//! 3. Classify Atoms via `comment_ts_kinds` → `AtomKind.comment`, ERROR /
//!    MISSING TS nodes → `AtomKind.@"error"`, everything else → `.code`.
//! 4. Attach comments adjacent to a List as `leading_trivia` / `trailing_trivia`
//!    on that List, so they participate in the List's hash (see Q5).
//! 5. Drop whitespace entirely.

const std = @import("std");
const treez = @import("treez");

const node = @import("node.zig");
const config_mod = @import("../lang/config.zig");
const result = @import("../diff/result.zig");
const registry = @import("../lang/registry.zig");

pub const ConvertError = error{
    OutOfMemory,
    /// Returned if the tree-sitter grammar named by the config could not be
    /// loaded (missing, name mismatch, etc.). Distinct from parse errors,
    /// which are data (see `ParseError`), not control flow.
    GrammarLoadFailed,
    NotImplemented,
};

pub const ConvertResult = struct {
    /// Newly allocated tree. Lives in `arena`.
    tree: *node.Tree,
    /// ERROR / MISSING regions encountered during conversion. `side` is left
    /// unset by the converter; the engine fills it in.
    parse_errors: []result.ParseError,
};

/// Convert a tree-sitter tree into an SST.
///
/// All SST allocations go through `arena`. The returned tree borrows `source`
/// for its atoms; caller must keep `source` alive as long as the tree is used.
pub fn fromTreeSitter(
    arena: std.mem.Allocator,
    ts_tree: *const treez.Tree,
    source: []const u8,
    cfg: *const config_mod.LangConfig,
) ConvertError!ConvertResult {
    var errors: std.ArrayList(result.ParseError) = .empty;
    errdefer errors.deinit(arena);

    const root_ts = ts_tree.getRootNode();
    const root_node = try convertNode(arena, root_ts, source, cfg, &errors);

    const tree_ptr = try arena.create(node.Tree);
    tree_ptr.* = .{ .root = root_node, .source = source };

    return .{
        .tree = tree_ptr,
        .parse_errors = try errors.toOwnedSlice(arena),
    };
}

/// Recursively convert a single tree-sitter node.
fn convertNode(
    arena: std.mem.Allocator,
    ts_node: treez.Node,
    source: []const u8,
    cfg: *const config_mod.LangConfig,
    errors: *std.ArrayList(result.ParseError),
) ConvertError!node.Node {
    const start = ts_node.getStartByte();
    const end = ts_node.getEndByte();
    const range: node.ByteRange = .{ .start = start, .end = end };
    const ts_kind = ts_node.getType();

    // MISSING node: inferred missing token. Byte range is typically empty.
    if (ts_node.isMissing()) {
        try errors.append(arena, .{
            // Placeholder: `side` is a non-optional enum, so we must pick
            // something. The engine caller overwrites this with the real
            // side after conversion (see ConvertResult.parse_errors doc).
            .side = .left,
            .byte_range = range,
            .kind = .missing_token,
        });
        return .{ .atom = .{
            .kind = .@"error",
            .bytes = source[start..end],
            .byte_range = range,
            .hash = 0,
        } };
    }

    // ERROR region: flatten to a single atom covering the whole byte range.
    // We do not recurse; the children of an ERROR are unreliable by
    // definition and only the raw bytes carry useful information.
    if (std.mem.eql(u8, ts_kind, "ERROR")) {
        try errors.append(arena, .{
            // Placeholder `side` - overwritten by the engine caller.
            .side = .left,
            .byte_range = range,
            .kind = .error_node,
        });
        return .{ .atom = .{
            .kind = .@"error",
            .bytes = source[start..end],
            .byte_range = range,
            .hash = 0,
        } };
    }

    // Comment.
    if (contains(cfg.comment_ts_kinds, ts_kind)) {
        return .{ .atom = .{
            .kind = .comment,
            .bytes = source[start..end],
            .byte_range = range,
            .hash = 0,
        } };
    }

    // Atom flattening for explicitly listed TS kinds.
    if (contains(cfg.atom_ts_kinds, ts_kind)) {
        return .{ .atom = .{
            .kind = .code,
            .bytes = source[start..end],
            .byte_range = range,
            .hash = 0,
        } };
    }

    // Anonymous tokens (punctuation, keywords) are always atoms.
    if (!ts_node.isNamed()) {
        return .{ .atom = .{
            .kind = .code,
            .bytes = source[start..end],
            .byte_range = range,
            .hash = 0,
        } };
    }

    // Otherwise: build a List from named children.
    const child_count = ts_node.getChildCount();

    // Determine the slice of children to convert, after consuming
    // open/close delimiters.
    var first: u32 = 0;
    var last_excl: u32 = child_count;
    var open_delim: []const u8 = "";
    var close_delim: []const u8 = "";

    if (first < last_excl) {
        const head = ts_node.getChild(first);
        if (contains(cfg.delimiter_ts_kinds, head.getType())) {
            open_delim = source[head.getStartByte()..head.getEndByte()];
            first += 1;
        }
    }
    if (first < last_excl) {
        const tail = ts_node.getChild(last_excl - 1);
        if (contains(cfg.delimiter_ts_kinds, tail.getType())) {
            close_delim = source[tail.getStartByte()..tail.getEndByte()];
            last_excl -= 1;
        }
    }

    // Convert the remaining children.
    var raw: std.ArrayList(node.Node) = .empty;
    defer raw.deinit(arena);
    try raw.ensureTotalCapacity(arena, last_excl - first);
    var i: u32 = first;
    while (i < last_excl) : (i += 1) {
        const converted = try convertNode(arena, ts_node.getChild(i), source, cfg, errors);
        try raw.append(arena, converted);
    }

    // Trivia attachment pass. Groups contiguous comment atoms and attaches
    // them as leading/trailing trivia on adjacent List children, per task
    // rules.
    const children_slice = try attachTrivia(arena, raw.items);

    return .{ .list = .{
        .ts_kind = ts_kind,
        .open_delim = open_delim,
        .close_delim = close_delim,
        .children = children_slice,
        .leading_trivia = &.{},
        .trailing_trivia = &.{},
        .byte_range = range,
        .hash = 0,
    } };
}

/// Walk `raw` children and produce the final children list with comments
/// redistributed as `leading_trivia` / `trailing_trivia` on adjacent Lists.
fn attachTrivia(arena: std.mem.Allocator, raw: []const node.Node) ConvertError![]const node.Node {
    var out: std.ArrayList(node.Node) = .empty;
    errdefer out.deinit(arena);
    try out.ensureTotalCapacity(arena, raw.len);

    var pending: std.ArrayList(node.Atom) = .empty;
    defer pending.deinit(arena);

    for (raw) |child| {
        switch (child) {
            .atom => |a| {
                if (a.kind == .comment) {
                    try pending.append(arena, a);
                } else {
                    // Non-comment atom: flush buffered comments as regular
                    // atom children before appending this one.
                    for (pending.items) |pc| {
                        try out.append(arena, .{ .atom = pc });
                    }
                    pending.clearRetainingCapacity();
                    try out.append(arena, child);
                }
            },
            .list => |l| {
                var list_copy = l;
                if (pending.items.len > 0) {
                    const leading = try arena.alloc(node.Atom, pending.items.len);
                    @memcpy(leading, pending.items);
                    list_copy.leading_trivia = leading;
                    pending.clearRetainingCapacity();
                }
                try out.append(arena, .{ .list = list_copy });
            },
        }
    }

    // Trailing comments: attach to the last List child if it is directly
    // adjacent. Since non-comment atoms flush `pending` above, the item
    // preceding these pending comments is either a List (attach) or a
    // non-comment atom (flush as children).
    if (pending.items.len > 0) {
        const n = out.items.len;
        if (n > 0 and out.items[n - 1] == .list) {
            var l = out.items[n - 1].list;
            const trailing = try arena.alloc(node.Atom, pending.items.len);
            @memcpy(trailing, pending.items);
            l.trailing_trivia = trailing;
            out.items[n - 1] = .{ .list = l };
        } else {
            for (pending.items) |pc| try out.append(arena, .{ .atom = pc });
        }
        pending.clearRetainingCapacity();
    }

    return try out.toOwnedSlice(arena);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseZig(src: []const u8) !*treez.Tree {
    const lang = try treez.Language.get("zig");
    const parser = try treez.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang);
    return try parser.parseString(null, src);
}

/// Helper: parse `src` as Zig and run `fromTreeSitter` against it, returning
/// the ConvertResult + the raw tree-sitter tree (for lifetime management).
/// Caller deinits arena and destroys ts_tree.
const ZigFixture = struct {
    ts_tree: *treez.Tree,
    res: ConvertResult,

    fn deinit(self: *ZigFixture) void {
        self.ts_tree.destroy();
    }
};

fn convertZig(arena: std.mem.Allocator, src: []const u8) !ZigFixture {
    const ts_tree = try parseZig(src);
    const cfg = registry.config(.zig);
    const res = try fromTreeSitter(arena, ts_tree, src, cfg);
    return .{ .ts_tree = ts_tree, .res = res };
}

test "fromTreeSitter: empty source produces source_file List with zero children" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), "");
    defer fx.deinit();

    try testing.expect(fx.res.tree.root == .list);
    const root = fx.res.tree.root.list;
    try testing.expectEqualStrings("source_file", root.ts_kind);
    try testing.expectEqual(@as(usize, 0), root.children.len);
    try testing.expectEqualStrings("", root.open_delim);
    try testing.expectEqualStrings("", root.close_delim);
    try testing.expectEqual(@as(usize, 0), fx.res.parse_errors.len);
}

test "fromTreeSitter: single fn produces one child List" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), "fn foo() void {}");
    defer fx.deinit();

    const root = fx.res.tree.root.list;
    try testing.expectEqual(@as(usize, 1), root.children.len);
    try testing.expect(root.children[0] == .list);
    try testing.expectEqualStrings("function_declaration", root.children[0].list.ts_kind);
}

test "fromTreeSitter: string literal flattened to single Atom" {
    const src = "const x = \"hello\";";
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    // Walk to the `string` node. source_file → variable_declaration → string.
    const root = fx.res.tree.root.list;
    try testing.expectEqual(@as(usize, 1), root.children.len);
    const var_decl = root.children[0].list;
    try testing.expectEqualStrings("variable_declaration", var_decl.ts_kind);

    var found_string: ?node.Atom = null;
    for (var_decl.children) |c| {
        switch (c) {
            .atom => |a| {
                if (std.mem.eql(u8, a.bytes, "\"hello\"")) found_string = a;
            },
            .list => {},
        }
    }
    const s = found_string orelse return error.StringAtomNotFound;
    try testing.expectEqual(node.AtomKind.code, s.kind);
    try testing.expectEqualStrings("\"hello\"", s.bytes);
    try testing.expectEqual(@as(u32, 10), s.byte_range.start);
    try testing.expectEqual(@as(u32, 17), s.byte_range.end);
}

test "fromTreeSitter: parens consumed as delimiters on call arguments" {
    const src = "fn t() void { bar(a, b); }";
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    // Descend: source_file → function_declaration → block → expression_statement
    //   → call_expression → arguments.
    const fn_decl = fx.res.tree.root.list.children[0].list;
    const block = findChildList(fn_decl, "block") orelse return error.NoBlock;
    const expr_stmt = findChildList(block, "expression_statement") orelse return error.NoExprStmt;
    const call = findChildList(expr_stmt, "call_expression") orelse return error.NoCall;
    const args = findChildList(call, "arguments") orelse return error.NoArgs;

    try testing.expectEqualStrings("(", args.open_delim);
    try testing.expectEqualStrings(")", args.close_delim);

    // Expected children after delimiter consumption: [a, ",", b].
    try testing.expectEqual(@as(usize, 3), args.children.len);
    try testing.expect(args.children[0] == .atom);
    try testing.expectEqualStrings("a", args.children[0].atom.bytes);
    try testing.expect(args.children[1] == .atom);
    try testing.expectEqualStrings(",", args.children[1].atom.bytes);
    try testing.expect(args.children[2] == .atom);
    try testing.expectEqualStrings("b", args.children[2].atom.bytes);
}

test "fromTreeSitter: braces consumed as delimiters on block" {
    const src = "fn t() void {}";
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    const fn_decl = fx.res.tree.root.list.children[0].list;
    const block = findChildList(fn_decl, "block") orelse return error.NoBlock;
    try testing.expectEqualStrings("{", block.open_delim);
    try testing.expectEqualStrings("}", block.close_delim);
    try testing.expectEqual(@as(usize, 0), block.children.len);
}

test "fromTreeSitter: leading comment attaches to next Decl at file top" {
    const src = "// hi\nfn foo() void {}";
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    const root = fx.res.tree.root.list;
    try testing.expectEqual(@as(usize, 1), root.children.len);
    try testing.expect(root.children[0] == .list);
    const fn_decl = root.children[0].list;
    try testing.expectEqualStrings("function_declaration", fn_decl.ts_kind);
    try testing.expectEqual(@as(usize, 1), fn_decl.leading_trivia.len);
    try testing.expectEqual(node.AtomKind.comment, fn_decl.leading_trivia[0].kind);
    try testing.expectEqualStrings("// hi", fn_decl.leading_trivia[0].bytes);
}

test "fromTreeSitter: trailing comment in container body attaches to last child" {
    // Two decls, with a trailing comment after the second. The comment
    // should attach to the second decl's trailing_trivia.
    const src = "fn a() void {}\nfn b() void {}\n// bye\n";
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    const root = fx.res.tree.root.list;
    try testing.expectEqual(@as(usize, 2), root.children.len);
    const last = root.children[1].list;
    try testing.expectEqual(@as(usize, 1), last.trailing_trivia.len);
    try testing.expectEqualStrings("// bye", last.trailing_trivia[0].bytes);
}

test "fromTreeSitter: ERROR region produces error atom + ParseError entry" {
    // Incomplete function declaration triggers an ERROR region.
    const src = "fn foo(";
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    try testing.expect(fx.res.parse_errors.len >= 1);

    // Every error atom in the tree should coincide with a parse_errors entry.
    const err_count = countErrorAtoms(fx.res.tree.root);
    try testing.expectEqual(fx.res.parse_errors.len, err_count);
}

test "fromTreeSitter: whitespace absent — `fn foo ( )` ≡ `fn foo()`" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var a = try convertZig(arena_state.allocator(), "fn foo() void {}");
    defer a.deinit();
    var b = try convertZig(arena_state.allocator(), "fn foo (  )  void  { }");
    defer b.deinit();

    try testing.expect(sameShape(a.res.tree.root, b.res.tree.root));
}

// ── Property tests ─────────────────────────────────────────────────────────

test "property: every atom's bytes slice equals source[byte_range]" {
    const src =
        \\// top
        \\const x: u32 = 1;
        \\pub fn foo(a: u32, b: u32) void {
        \\    const s = "x";
        \\    _ = a;
        \\    _ = b;
        \\}
    ;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    try expectAtomBytesMatchSource(fx.res.tree.root, src);
}

test "property: no orphan comments — every comment from source is placed exactly once" {
    const src =
        \\// alpha
        \\fn one() void {}
        \\// beta
        \\fn two() void {}
        \\// gamma
    ;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    // Count every `//` start in the source. Each must appear exactly once as
    // a comment atom (either as a child atom or as leading/trailing trivia)
    // in the SST.
    const source_comments = std.mem.count(u8, src, "//");
    const placed = countComments(fx.res.tree.root);
    try testing.expectEqual(source_comments, placed);
}

test "sanity fixture: Zig SST shape is inspectable (set RV_DUMP=1 to print)" {
    const build_options = @import("build_options");
    const path = try std.fs.path.join(testing.allocator, &.{
        build_options.fixtures_path, "zig", "sanity", "before.zig",
    });
    defer testing.allocator.free(path);

    const src = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(src);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), src);
    defer fx.deinit();

    // Invariants: the root is a List, all atom bytes agree with their byte
    // ranges, and every comment in `src` is placed somewhere in the SST.
    try testing.expect(fx.res.tree.root == .list);
    try expectAtomBytesMatchSource(fx.res.tree.root, src);
    const src_comments = std.mem.count(u8, src, "//");
    try testing.expectEqual(src_comments, countComments(fx.res.tree.root));

    if (std.c.getenv("RV_DUMP") != null) {
        std.debug.print("\n=== sanity fixture SST ===\n", .{});
        dumpSst(fx.res.tree.root, 0);
    }
}

// ── test helpers ───────────────────────────────────────────────────────────

fn findChildList(list: node.List, ts_kind: []const u8) ?node.List {
    for (list.children) |c| switch (c) {
        .list => |l| if (std.mem.eql(u8, l.ts_kind, ts_kind)) return l,
        .atom => {},
    };
    return null;
}

/// Diagnostic helper: print the SST structure. Only used when `RV_DUMP=1`.
fn dumpSst(n: node.Node, depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) std.debug.print("  ", .{});
    switch (n) {
        .atom => |a| std.debug.print("atom({s}) {d}..{d} {s}\n", .{
            @tagName(a.kind), a.byte_range.start, a.byte_range.end, a.bytes,
        }),
        .list => |l| {
            std.debug.print("list[{s}] open={s} close={s} lt={d} tt={d}\n", .{
                l.ts_kind, l.open_delim, l.close_delim,
                l.leading_trivia.len, l.trailing_trivia.len,
            });
            for (l.leading_trivia) |t| {
                var j: usize = 0;
                while (j < depth + 1) : (j += 1) std.debug.print("  ", .{});
                std.debug.print("[lead] {s}\n", .{t.bytes});
            }
            for (l.children) |c| dumpSst(c, depth + 1);
            for (l.trailing_trivia) |t| {
                var j: usize = 0;
                while (j < depth + 1) : (j += 1) std.debug.print("  ", .{});
                std.debug.print("[trail] {s}\n", .{t.bytes});
            }
        },
    }
}

fn countErrorAtoms(n: node.Node) usize {
    return switch (n) {
        .atom => |a| if (a.kind == .@"error") @as(usize, 1) else 0,
        .list => |l| blk: {
            var total: usize = 0;
            for (l.children) |c| total += countErrorAtoms(c);
            for (l.leading_trivia) |t| if (t.kind == .@"error") {
                total += 1;
            };
            for (l.trailing_trivia) |t| if (t.kind == .@"error") {
                total += 1;
            };
            break :blk total;
        },
    };
}

fn countComments(n: node.Node) usize {
    return switch (n) {
        .atom => |a| if (a.kind == .comment) @as(usize, 1) else 0,
        .list => |l| blk: {
            var total: usize = 0;
            for (l.children) |c| total += countComments(c);
            for (l.leading_trivia) |t| if (t.kind == .comment) {
                total += 1;
            };
            for (l.trailing_trivia) |t| if (t.kind == .comment) {
                total += 1;
            };
            break :blk total;
        },
    };
}

fn expectAtomBytesMatchSource(n: node.Node, src: []const u8) !void {
    switch (n) {
        .atom => |a| {
            const slice = src[a.byte_range.start..a.byte_range.end];
            try testing.expectEqualStrings(slice, a.bytes);
        },
        .list => |l| {
            for (l.children) |c| try expectAtomBytesMatchSource(c, src);
            for (l.leading_trivia) |t| {
                const slice = src[t.byte_range.start..t.byte_range.end];
                try testing.expectEqualStrings(slice, t.bytes);
            }
            for (l.trailing_trivia) |t| {
                const slice = src[t.byte_range.start..t.byte_range.end];
                try testing.expectEqualStrings(slice, t.bytes);
            }
        },
    }
}

/// Structural equality of two SST subtrees. Compares ts_kinds of Lists,
/// kinds + bytes of Atoms, delimiters, and children in order. Byte ranges
/// and trivia placement are compared by length to ignore absolute offsets.
fn sameShape(a: node.Node, b: node.Node) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .atom => |aa| {
            const ba = b.atom;
            if (aa.kind != ba.kind) return false;
            if (!std.mem.eql(u8, aa.bytes, ba.bytes)) return false;
        },
        .list => |al| {
            const bl = b.list;
            if (!std.mem.eql(u8, al.ts_kind, bl.ts_kind)) return false;
            if (!std.mem.eql(u8, al.open_delim, bl.open_delim)) return false;
            if (!std.mem.eql(u8, al.close_delim, bl.close_delim)) return false;
            if (al.children.len != bl.children.len) return false;
            if (al.leading_trivia.len != bl.leading_trivia.len) return false;
            if (al.trailing_trivia.len != bl.trailing_trivia.len) return false;
            for (al.children, bl.children) |ac, bc| {
                if (!sameShape(ac, bc)) return false;
            }
        },
    }
    return true;
}

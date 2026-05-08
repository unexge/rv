//! Zig language configuration.
//!
//! ## Container detection
//!
//! Zig's struct-as-namespace idiom - `pub const Thing = struct { ... };` -
//! has a `variable_declaration` as the outer Decl; the inner declarations
//! live in a nested `struct_declaration` (or `enum_`, `union_`, `opaque_`).
//! ts_kind alone can't tell a container var from a scalar var, so we use
//! the optional `LangConfig.container_list_of` hook: given a candidate
//! Decl List, return the nested container list if one is present, else
//! null. This keeps `container_ts_kinds` empty for Zig.

const std = @import("std");
const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "zig",
    // Flatten these TS node types into a single Atom even when the grammar
    // splits them into sub-tokens (e.g. string → [", string_content, "]).
    // Keeps leaf literals comparable as single bytes.
    .atom_ts_kinds = &.{
        "string",
        "multiline_string",
        "character",
        "integer",
        "float",
        "identifier",
        "builtin_identifier",
        "builtin_type",
        "escape_sequence",
    },
    // Anonymous punctuation tokens that delimit a List. The TS node type for
    // an anonymous token equals its literal text, so matching on these
    // strings is sound.
    .delimiter_ts_kinds = &.{
        "(", ")",
        "{", "}",
        "[", "]",
    },
    .comment_ts_kinds = &.{"comment"},
    .decl_ts_kinds = &.{
        "function_declaration",
        "variable_declaration",
        "test_declaration",
        "comptime_declaration",
        "container_field",
        "using_namespace_declaration",
    },
    // All Zig container detection is dynamic via `container_list_of`.
    .container_ts_kinds = &.{},
    .classify = classify,
    .extract_name = extractName,
    .container_list_of = containerListOf,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    if (std.mem.eql(u8, ts_kind, "function_declaration")) return .function;
    if (std.mem.eql(u8, ts_kind, "variable_declaration")) return .binding;
    if (std.mem.eql(u8, ts_kind, "test_declaration")) return .test_case;
    if (std.mem.eql(u8, ts_kind, "comptime_declaration")) return .other;
    if (std.mem.eql(u8, ts_kind, "container_field")) return .binding;
    if (std.mem.eql(u8, ts_kind, "using_namespace_declaration")) return .import;
    return .other;
}

/// Keyword atoms we skip when scanning for a Decl's identifier. These are
/// modifier keywords that may precede the name in a function/variable/
/// container_field declaration (e.g. `pub const foo`, `pub fn bar`,
/// `comptime fieldName`). Post-conversion the converter has stripped node
/// types, so we discriminate by byte equality.
const skip_kw = [_][]const u8{
    "pub",
    "const",
    "var",
    "fn",
    "test",
    "comptime",
    "extern",
    "export",
    "threadlocal",
    "inline",
    "noinline",
    "usingnamespace",
    "packed",
};

fn isSkipKeyword(bytes: []const u8) bool {
    for (skip_kw) |kw| {
        if (std.mem.eql(u8, kw, bytes)) return true;
    }
    return false;
}

/// Scan the direct Atom children of `list` and return the first one that
/// isn't a modifier keyword. Returns null if every atom is a keyword or if
/// there are no atoms.
fn firstNonKeywordAtom(list: *const node.List) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .atom => |a| {
            if (a.kind != .code) continue;
            if (isSkipKeyword(a.bytes)) continue;
            return a.bytes;
        },
        .list => {},
    };
    return null;
}

fn extractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = source;
    const ts = list.ts_kind;
    if (std.mem.eql(u8, ts, "comptime_declaration")) return null;
    if (std.mem.eql(u8, ts, "using_namespace_declaration")) return null;

    // For function/variable/test/container_field the identifier (or test's
    // name string) is the first non-keyword Atom child.
    return firstNonKeywordAtom(list);
}

/// Inspect `list`: if it's a `variable_declaration` whose RHS is a
/// struct/union/enum/opaque_declaration, return that nested list (whose
/// children are the inner Decls). Otherwise return null.
fn containerListOf(list: *const node.List) ?*const node.List {
    if (!std.mem.eql(u8, list.ts_kind, "variable_declaration")) return null;
    for (list.children) |*child| switch (child.*) {
        .list => |inner| {
            if (std.mem.eql(u8, inner.ts_kind, "struct_declaration") or
                std.mem.eql(u8, inner.ts_kind, "union_declaration") or
                std.mem.eql(u8, inner.ts_kind, "enum_declaration") or
                std.mem.eql(u8, inner.ts_kind, "opaque_declaration"))
            {
                return &child.list;
            }
        },
        .atom => {},
    };
    return null;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const treez = @import("treez");
const convert = @import("../sst/convert.zig");

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
    const res = try convert.fromTreeSitter(arena, ts_tree, src, &config);
    return .{ .ts_tree = ts_tree, .res = res };
}

fn findTopDecl(root: *const node.List, ts_kind: []const u8) ?*const node.List {
    for (root.children) |*child| switch (child.*) {
        .list => |l| if (std.mem.eql(u8, l.ts_kind, ts_kind)) return &child.list,
        .atom => {},
    };
    return null;
}

// ── classify ───────────────────────────────────────────────────────────────

test "classify: every listed decl_ts_kind maps to a DeclKind" {
    try testing.expectEqual(result.DeclKind.function, classify("function_declaration"));
    try testing.expectEqual(result.DeclKind.binding, classify("variable_declaration"));
    try testing.expectEqual(result.DeclKind.test_case, classify("test_declaration"));
    try testing.expectEqual(result.DeclKind.other, classify("comptime_declaration"));
    try testing.expectEqual(result.DeclKind.binding, classify("container_field"));
    try testing.expectEqual(result.DeclKind.import, classify("using_namespace_declaration"));
    try testing.expectEqual(result.DeclKind.other, classify("arbitrary_unlisted_kind"));
}

// ── extractName ────────────────────────────────────────────────────────────

test "extractName: function_declaration identifier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), "pub fn foo(a: u32) void {}");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const fn_decl = findTopDecl(root, "function_declaration").?;
    const name = extractName(fn_decl, fx.res.tree.source).?;
    try testing.expectEqualStrings("foo", name);
}

test "extractName: variable_declaration identifier (const, pub)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), "pub const answer: u32 = 42;");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const vd = findTopDecl(root, "variable_declaration").?;
    const name = extractName(vd, fx.res.tree.source).?;
    try testing.expectEqualStrings("answer", name);
}

test "extractName: test_declaration captures the test string literal" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), "test \"my name\" { }");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const td = findTopDecl(root, "test_declaration").?;
    const name = extractName(td, fx.res.tree.source).?;
    try testing.expectEqualStrings("\"my name\"", name);
}

test "extractName: comptime_declaration is anonymous" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), "comptime { _ = 1; }");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const cd = findTopDecl(root, "comptime_declaration").?;
    try testing.expect(extractName(cd, fx.res.tree.source) == null);
}

test "extractName: container_field identifier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(),
        \\pub const S = struct {
        \\    x: u32,
        \\};
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const vd = findTopDecl(root, "variable_declaration").?;
    const inner = containerListOf(vd).?;
    const field = findTopDecl(inner, "container_field").?;
    const name = extractName(field, fx.res.tree.source).?;
    try testing.expectEqualStrings("x", name);
}

test "extractName: using_namespace_declaration is anonymous" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), "pub usingnamespace @import(\"x\");");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const ud = findTopDecl(root, "using_namespace_declaration").?;
    try testing.expect(extractName(ud, fx.res.tree.source) == null);
}

// ── containerListOf ────────────────────────────────────────────────────────

test "containerListOf: var decl with struct RHS returns the struct list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(),
        \\pub const Thing = struct {
        \\    x: u32,
        \\};
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const vd = findTopDecl(root, "variable_declaration").?;
    const inner = containerListOf(vd).?;
    try testing.expectEqualStrings("struct_declaration", inner.ts_kind);
}

test "containerListOf: scalar var decl returns null" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), "pub const answer: u32 = 42;");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const vd = findTopDecl(root, "variable_declaration").?;
    try testing.expect(containerListOf(vd) == null);
}

test "containerListOf: function_declaration is not a container" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertZig(arena_state.allocator(), "fn foo() void {}");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const fn_decl = findTopDecl(root, "function_declaration").?;
    try testing.expect(containerListOf(fn_decl) == null);
}

test "containerListOf: enum/union/opaque RHS all detected" {
    const sources = [_][]const u8{
        "const E = enum { A, B };",
        "const U = union { a: u32, b: u64 };",
        "const O = opaque {};",
    };
    const expected = [_][]const u8{
        "enum_declaration",
        "union_declaration",
        "opaque_declaration",
    };

    for (sources, expected) |src, want| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var fx = try convertZig(arena.allocator(), src);
        defer fx.deinit();
        const root = &fx.res.tree.root.list;
        const vd = findTopDecl(root, "variable_declaration").?;
        const inner = containerListOf(vd) orelse return error.NoContainer;
        try testing.expectEqualStrings(want, inner.ts_kind);
    }
}

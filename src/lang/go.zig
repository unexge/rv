//! Go language configuration.
//!
//! ## Name extraction
//!
//! Go Decls spread the name across several positions in the grammar:
//!
//! - `function_declaration`: children are `[Atom "func", Atom name,
//!   parameter_list, ...]`. Skip the `func` keyword, take the next code
//!   atom.
//! - `method_declaration`: children are `[Atom "func", receiver_list,
//!   Atom name, parameter_list, ...]`. The receiver is a List in between.
//!   Same helper applies - skip "func", return the first non-keyword
//!   atom - which yields just the method name (e.g. `Bar` for
//!   `func (r *Foo) Bar()`). Methods of the same name on different types
//!   collide on identity key; the occurrence-index tiebreaker in
//!   `diff/align.zig` disambiguates.
//! - `type_declaration`, `var_declaration`, `const_declaration`: the
//!   identifier lives one level deep inside a `type_spec` / `type_alias` /
//!   `var_spec` / `const_spec` child List. For grouped declarations
//!   (`var ( x int; y int )`) we only surface the first spec's name;
//!   multi-spec blocks are rare at top level and finer-grained handling
//!   is deferred.
//! - `import_declaration`: returns the string literal of the first import
//!   path (descending through `import_spec_list` if present).
//!
//! ## Decl granularity
//!
//! One Decl per `*_declaration`. Grouped forms like `var ( x int; y int )`
//! yield a single `var_declaration` Decl whose name is the first spec's
//! identifier. This matches Go's own organisation of these blocks and
//! keeps identity keys simple.
//!
//! ## Classify
//!
//! `type_declaration` maps to `.other` (see task Q): Go's `type X struct
//! { ... }` is a leaf Decl here; fields and methods aren't nested inside
//! it (methods are their own top-level Decls, fields are body tokens).

const std = @import("std");
const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "go",
    // Flatten literals and identifier-like named leaves into single Atoms.
    // Named leaves (no children) would otherwise convert to empty Lists and
    // be invisible to the "scan direct atoms" name-extraction helper.
    .atom_ts_kinds = &.{
        "interpreted_string_literal",
        "raw_string_literal",
        "rune_literal",
        "int_literal",
        "float_literal",
        "imaginary_literal",
        "identifier",
        "field_identifier",
        "type_identifier",
        "package_identifier",
        "blank_identifier",
        "label_name",
        "nil",
        "true",
        "false",
    },
    .delimiter_ts_kinds = &.{
        "(", ")",
        "{", "}",
        "[", "]",
    },
    .comment_ts_kinds = &.{"comment"},
    .decl_ts_kinds = &.{
        "function_declaration",
        "method_declaration",
        "type_declaration",
        "var_declaration",
        "const_declaration",
        "import_declaration",
    },
    // Go has no nested top-level containers in v1. `source_file` is passed
    // directly to alignment by the engine; listing it here would be a
    // no-op.
    .container_ts_kinds = &.{},
    .classify = classify,
    .extract_name = extractName,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    if (std.mem.eql(u8, ts_kind, "function_declaration")) return .function;
    if (std.mem.eql(u8, ts_kind, "method_declaration")) return .function;
    if (std.mem.eql(u8, ts_kind, "var_declaration")) return .binding;
    if (std.mem.eql(u8, ts_kind, "const_declaration")) return .binding;
    if (std.mem.eql(u8, ts_kind, "import_declaration")) return .import;
    if (std.mem.eql(u8, ts_kind, "type_declaration")) return .other;
    return .other;
}

fn extractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = source;
    const ts = list.ts_kind;
    if (std.mem.eql(u8, ts, "function_declaration") or
        std.mem.eql(u8, ts, "method_declaration"))
    {
        // Children are [Atom "func", optional receiver List (methods only),
        // Atom name, ...]. Skipping "func" leaves the name as the first
        // direct atom.
        return firstNonKeywordAtom(list, &.{"func"});
    }
    if (std.mem.eql(u8, ts, "type_declaration")) {
        // `type` declarations do not wrap their specs in an intermediate
        // `*_spec_list` node, so the spec is a direct child.
        return firstAtomOfFirstSpec(list, &.{ "type_spec", "type_alias" }, null);
    }
    if (std.mem.eql(u8, ts, "var_declaration")) {
        // Grouped form `var ( x int; y int )` wraps the specs in a
        // `var_spec_list`; descend one level when we see that wrapper.
        return firstAtomOfFirstSpec(list, &.{"var_spec"}, "var_spec_list");
    }
    if (std.mem.eql(u8, ts, "const_declaration")) {
        // Unlike `var`, tree-sitter-go has no `const_spec_list` wrapper -
        // grouped `const ( ... )` exposes its `const_spec`s as direct
        // children, so `group_wrapper` stays null.
        return firstAtomOfFirstSpec(list, &.{"const_spec"}, null);
    }
    if (std.mem.eql(u8, ts, "import_declaration")) {
        return firstImportPath(list);
    }
    return null;
}

/// Scan direct atom children, skipping any whose bytes match one of `skip`
/// (used for keyword elision). Returns the first remaining code atom.
fn firstNonKeywordAtom(list: *const node.List, skip: []const []const u8) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .atom => |a| {
            if (a.kind != .code) continue;
            if (containsBytes(skip, a.bytes)) continue;
            return a.bytes;
        },
        .list => {},
    };
    return null;
}

/// Find the first spec list (whose `ts_kind` appears in `spec_kinds`)
/// reachable from `list`, then return its first code atom.
///
/// When `group_wrapper` is non-null, a direct child List with that ts_kind
/// is descended into one level - this handles the grouped forms like
/// `var ( x int; y int )` where tree-sitter-go introduces an intermediate
/// `var_spec_list` / `const_spec_list` wrapper.
fn firstAtomOfFirstSpec(
    list: *const node.List,
    spec_kinds: []const []const u8,
    group_wrapper: ?[]const u8,
) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .list => |inner| {
            if (containsBytes(spec_kinds, inner.ts_kind)) {
                return firstCodeAtom(inner);
            }
            if (group_wrapper) |gw| if (std.mem.eql(u8, inner.ts_kind, gw)) {
                for (inner.children) |ic| switch (ic) {
                    .list => |spec| if (containsBytes(spec_kinds, spec.ts_kind)) {
                        return firstCodeAtom(spec);
                    },
                    .atom => {},
                };
            };
        },
        .atom => {},
    };
    return null;
}

fn firstCodeAtom(list: node.List) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .atom => |a| if (a.kind == .code) return a.bytes,
        .list => {},
    };
    return null;
}

/// Return the first import path string literal reachable from an
/// `import_declaration`. The grammar wraps it either directly (single
/// import) in an `import_spec` child, or via `import_spec_list` for the
/// `import ( ... )` form.
fn firstImportPath(list: *const node.List) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .list => |inner| {
            if (std.mem.eql(u8, inner.ts_kind, "import_spec")) {
                return firstStringLiteralAtom(inner);
            }
            if (std.mem.eql(u8, inner.ts_kind, "import_spec_list")) {
                for (inner.children) |ic| switch (ic) {
                    .list => |spec| {
                        if (std.mem.eql(u8, spec.ts_kind, "import_spec")) {
                            return firstStringLiteralAtom(spec);
                        }
                    },
                    .atom => {},
                };
            }
        },
        .atom => {},
    };
    return null;
}

/// Return the first direct code atom whose bytes begin with `"` or a
/// backtick (Go's two string literal forms).
fn firstStringLiteralAtom(list: node.List) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .atom => |a| {
            if (a.kind != .code) continue;
            if (a.bytes.len == 0) continue;
            if (a.bytes[0] == '"' or a.bytes[0] == '`') return a.bytes;
        },
        .list => {},
    };
    return null;
}

fn containsBytes(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const treez = @import("treez");
const convert = @import("../sst/convert.zig");

fn parseGo(src: []const u8) !*treez.Tree {
    const lang = try treez.Language.get("go");
    const parser = try treez.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang);
    return try parser.parseString(null, src);
}

const GoFixture = struct {
    ts_tree: *treez.Tree,
    res: convert.ConvertResult,

    fn deinit(self: *GoFixture) void {
        self.ts_tree.destroy();
    }
};

fn convertGo(arena: std.mem.Allocator, src: []const u8) !GoFixture {
    const ts_tree = try parseGo(src);
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
    try testing.expectEqual(result.DeclKind.function, classify("method_declaration"));
    try testing.expectEqual(result.DeclKind.other, classify("type_declaration"));
    try testing.expectEqual(result.DeclKind.binding, classify("var_declaration"));
    try testing.expectEqual(result.DeclKind.binding, classify("const_declaration"));
    try testing.expectEqual(result.DeclKind.import, classify("import_declaration"));
    try testing.expectEqual(result.DeclKind.other, classify("arbitrary_unlisted_kind"));
}

// ── extractName ────────────────────────────────────────────────────────────

test "extractName: function_declaration identifier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(), "package p\nfunc Foo() {}\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const fd = findTopDecl(root, "function_declaration").?;
    const name = extractName(fd, fx.res.tree.source).?;
    try testing.expectEqualStrings("Foo", name);
}

test "extractName: method_declaration returns just the method name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\type Foo struct{}
        \\func (r *Foo) Bar() {}
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const md = findTopDecl(root, "method_declaration").?;
    const name = extractName(md, fx.res.tree.source).?;
    try testing.expectEqualStrings("Bar", name);
}

test "extractName: two methods with the same name on different types coexist" {
    // Identity key alone can't distinguish (A).Do from (B).Do — both have
    // ts_kind = method_declaration and name = "Do". The occurrence-index
    // tiebreaker in the aligner disambiguates; here we just verify the
    // name is extracted correctly for both.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\type A struct{}
        \\type B struct{}
        \\func (a *A) Do() {}
        \\func (b *B) Do() {}
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    var count: usize = 0;
    for (root.children) |*child| switch (child.*) {
        .list => |l| {
            if (std.mem.eql(u8, l.ts_kind, "method_declaration")) {
                const name = extractName(&child.list, fx.res.tree.source).?;
                try testing.expectEqualStrings("Do", name);
                count += 1;
            }
        },
        .atom => {},
    };
    try testing.expectEqual(@as(usize, 2), count);
}

test "extractName: type_declaration struct" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\type Thing struct{ x int }
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const td = findTopDecl(root, "type_declaration").?;
    const name = extractName(td, fx.res.tree.source).?;
    try testing.expectEqualStrings("Thing", name);
}

test "extractName: type_declaration type alias" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\type Alias = int
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const td = findTopDecl(root, "type_declaration").?;
    const name = extractName(td, fx.res.tree.source).?;
    try testing.expectEqualStrings("Alias", name);
}

test "extractName: var_declaration identifier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\var answer int = 42
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const vd = findTopDecl(root, "var_declaration").?;
    const name = extractName(vd, fx.res.tree.source).?;
    try testing.expectEqualStrings("answer", name);
}

test "extractName: const_declaration identifier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\const pi = 3.14
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const cd = findTopDecl(root, "const_declaration").?;
    const name = extractName(cd, fx.res.tree.source).?;
    try testing.expectEqualStrings("pi", name);
}

test "extractName: const_declaration grouped form returns first name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\const (
        \\    x = 1
        \\    y = 2
        \\)
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const cd = findTopDecl(root, "const_declaration").?;
    const name = extractName(cd, fx.res.tree.source).?;
    try testing.expectEqualStrings("x", name);
}

test "extractName: var_declaration grouped form returns first name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\var (
        \\    x int
        \\    y int
        \\)
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const vd = findTopDecl(root, "var_declaration").?;
    const name = extractName(vd, fx.res.tree.source).?;
    try testing.expectEqualStrings("x", name);
}

test "extractName: import_declaration single import returns the path literal" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\import "fmt"
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const id = findTopDecl(root, "import_declaration").?;
    const name = extractName(id, fx.res.tree.source).?;
    try testing.expectEqualStrings("\"fmt\"", name);
}

test "extractName: import_declaration grouped form returns first path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertGo(arena_state.allocator(),
        \\package p
        \\import (
        \\    "fmt"
        \\    "os"
        \\)
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const id = findTopDecl(root, "import_declaration").?;
    const name = extractName(id, fx.res.tree.source).?;
    try testing.expectEqualStrings("\"fmt\"", name);
}

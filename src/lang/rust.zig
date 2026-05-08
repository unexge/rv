//! Rust language configuration.
//!
//! ## Name extraction
//!
//! Most Rust Decls follow a `[modifiers?, keyword, name, ...]` layout:
//!
//! - `function_item`: `[visibility_modifier?, function_modifiers?, "fn",
//!   identifier, type_parameters?, parameters, return_type?, block]`.
//! - `struct_item`, `enum_item`, `union_item`, `trait_item`: same shape
//!   with their keyword and a `type_identifier` for the name.
//! - `mod_item`, `const_item`, `static_item`, `type_item`: ditto.
//!
//! `firstNonKeywordAtom` skips modifier keywords (`pub`, `fn`, `struct`,
//! etc.) and returns the first remaining code atom. `visibility_modifier`
//! and `function_modifiers` are named Lists in the TS tree, so they never
//! collide with this scan.
//!
//! ## impl_item
//!
//! The task gives two options for `impl Trait for Foo`:
//!   (a) return `Foo` (the target type) and let the occurrence-index
//!       tiebreaker in `diff/align.zig` disambiguate two `impl Foo` blocks;
//!   (b) allocate a `"Trait for Foo"` string and have LangConfig own it.
//!
//! We take (a): simpler, matches the borrowed-slice contract in
//! `LangConfig.extract_name`. Body differences still surface via the body
//! diff; trait identity only affects identity-key ties, and siblings are
//! disambiguated by occurrence.
//!
//! ## use_declaration
//!
//! Returns the raw source slice of the argument between `use` and `;`. For
//! `use std::fmt::Write;` this is `"std::fmt::Write"`. Simpler than
//! extracting the last segment and keeps paths readable in diff output.
//!
//! ## Macros
//!
//! `macro_definition` (`macro_rules! foo { ... }`): the grammar exposes the
//! `macro_rules!` prefix as a single anonymous token, so skipping it leaves
//! the macro identifier as the first atom. `macro_invocation` at top level
//! (`foo!();` or `path::foo!();`) returns the first named child's source
//! slice - identifier or scoped_identifier.

const std = @import("std");
const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "rust",
    // Flatten literals and identifier-like leaves into single Atoms so
    // name-extraction can scan direct atom children. `byte_string_literal`
    // is listed for forward-compat with grammar versions that expose it;
    // the current version folds byte strings into `string_literal` and the
    // entry is a harmless no-op.
    .atom_ts_kinds = &.{
        "string_literal",
        "raw_string_literal",
        "char_literal",
        "byte_string_literal",
        "integer_literal",
        "float_literal",
        "boolean_literal",
        "identifier",
        "type_identifier",
        "field_identifier",
        "shorthand_field_identifier",
        "primitive_type",
        "self",
        "super",
        "crate",
    },
    .delimiter_ts_kinds = &.{
        "(", ")",
        "{", "}",
        "[", "]",
    },
    .comment_ts_kinds = &.{ "line_comment", "block_comment" },
    .decl_ts_kinds = &.{
        "function_item",
        "struct_item",
        "enum_item",
        "union_item",
        "impl_item",
        "trait_item",
        "mod_item",
        "use_declaration",
        "const_item",
        "static_item",
        "type_item",
        "macro_definition",
        "macro_invocation",
    },
    // All Rust container detection is dynamic via `container_list_of`:
    // `impl_item` / `trait_item` / `mod_item` need to descend into their
    // nested `declaration_list`, and the root `source_file` is entered
    // by `alignDecls` directly without consulting this table.
    .container_ts_kinds = &.{},
    .classify = classify,
    .extract_name = extractName,
    .container_list_of = containerListOf,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    if (std.mem.eql(u8, ts_kind, "function_item")) return .function;
    if (std.mem.eql(u8, ts_kind, "struct_item")) return .container;
    if (std.mem.eql(u8, ts_kind, "enum_item")) return .container;
    if (std.mem.eql(u8, ts_kind, "union_item")) return .container;
    if (std.mem.eql(u8, ts_kind, "impl_item")) return .container;
    if (std.mem.eql(u8, ts_kind, "trait_item")) return .container;
    if (std.mem.eql(u8, ts_kind, "mod_item")) return .container;
    if (std.mem.eql(u8, ts_kind, "const_item")) return .binding;
    if (std.mem.eql(u8, ts_kind, "static_item")) return .binding;
    if (std.mem.eql(u8, ts_kind, "type_item")) return .type_alias;
    if (std.mem.eql(u8, ts_kind, "use_declaration")) return .import;
    if (std.mem.eql(u8, ts_kind, "macro_definition")) return .other;
    if (std.mem.eql(u8, ts_kind, "macro_invocation")) return .other;
    return .other;
}

/// Keywords that can appear as direct atom children of a Decl before the
/// name. `pub`, `async`, `unsafe`, `extern "abi"` are wrapped in
/// `visibility_modifier` / `function_modifiers` Lists and so don't appear
/// here as atoms, but listing them is harmless belt-and-braces.
const skip_kw = [_][]const u8{
    "fn",
    "struct",
    "enum",
    "union",
    "trait",
    "mod",
    "impl",
    "const",
    "static",
    "type",
    "use",
    "pub",
    "async",
    "unsafe",
    "extern",
    "default",
    "move",
    "dyn",
    "mut",
    "ref",
    "where",
    "macro_rules!",
    "!",
    ";",
};

fn isSkipKeyword(bytes: []const u8) bool {
    for (skip_kw) |kw| {
        if (std.mem.eql(u8, kw, bytes)) return true;
    }
    return false;
}

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
    const ts = list.ts_kind;
    if (std.mem.eql(u8, ts, "function_item") or
        std.mem.eql(u8, ts, "struct_item") or
        std.mem.eql(u8, ts, "enum_item") or
        std.mem.eql(u8, ts, "union_item") or
        std.mem.eql(u8, ts, "trait_item") or
        std.mem.eql(u8, ts, "mod_item") or
        std.mem.eql(u8, ts, "const_item") or
        std.mem.eql(u8, ts, "static_item") or
        std.mem.eql(u8, ts, "type_item") or
        std.mem.eql(u8, ts, "macro_definition"))
    {
        return firstNonKeywordAtom(list);
    }
    if (std.mem.eql(u8, ts, "impl_item")) return implName(list, source);
    if (std.mem.eql(u8, ts, "use_declaration")) return useArgument(list, source);
    if (std.mem.eql(u8, ts, "macro_invocation")) return macroPath(list, source);
    return null;
}

/// For `impl Foo { ... }` return `"Foo"`. For `impl Trait for Foo { ... }`
/// return `"Foo"` (option (a) in the module doc). The body of an impl is
/// a `declaration_list`; everything before it is type machinery.
fn implName(list: *const node.List, source: []const u8) ?[]const u8 {
    // Scan for "for" keyword among direct code atoms. When found, the
    // first non-keyword child after it is the target type.
    var saw_for = false;
    for (list.children) |c| {
        switch (c) {
            .atom => |a| {
                if (a.kind == .code and std.mem.eql(u8, a.bytes, "for")) {
                    saw_for = true;
                    continue;
                }
                if (saw_for) {
                    if (a.kind != .code) continue;
                    if (isSkipKeyword(a.bytes)) continue;
                    return a.bytes;
                }
            },
            .list => |inner| {
                if (saw_for) {
                    if (std.mem.eql(u8, inner.ts_kind, "declaration_list")) continue;
                    return nodeSource(source, inner.byte_range);
                }
            },
        }
    }

    // No "for": the target type is the last non-body child.
    var i = list.children.len;
    while (i > 0) {
        i -= 1;
        switch (list.children[i]) {
            .atom => |a| {
                if (a.kind != .code) continue;
                if (isSkipKeyword(a.bytes)) continue;
                return a.bytes;
            },
            .list => |inner| {
                if (std.mem.eql(u8, inner.ts_kind, "declaration_list")) continue;
                if (std.mem.eql(u8, inner.ts_kind, "where_clause")) continue;
                if (std.mem.eql(u8, inner.ts_kind, "visibility_modifier")) continue;
                return nodeSource(source, inner.byte_range);
            },
        }
    }
    return null;
}

/// Return the raw source slice of the first "significant" child between
/// `use` and `;`. This is `"foo"` for `use foo;`, `"std::fmt::Write"` for
/// `use std::fmt::Write;`, and `"foo::{a, b}"` for `use foo::{a, b};`.
fn useArgument(list: *const node.List, source: []const u8) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .atom => |a| {
            if (a.kind != .code) continue;
            if (isSkipKeyword(a.bytes)) continue;
            return a.bytes;
        },
        .list => |inner| {
            if (std.mem.eql(u8, inner.ts_kind, "visibility_modifier")) continue;
            return nodeSource(source, inner.byte_range);
        },
    };
    return null;
}

/// Return the path portion of a top-level macro invocation: `foo!()`
/// yields `"foo"`, `path::foo!()` yields `"path::foo"`.
fn macroPath(list: *const node.List, source: []const u8) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .atom => |a| {
            if (a.kind != .code) continue;
            if (isSkipKeyword(a.bytes)) continue;
            return a.bytes;
        },
        .list => |inner| {
            // token_tree is the macro body `( ... )` / `[ ... ]` / `{ ... }`;
            // skip it when scanning for the path head.
            if (std.mem.eql(u8, inner.ts_kind, "token_tree")) continue;
            return nodeSource(source, inner.byte_range);
        },
    };
    return null;
}

fn nodeSource(source: []const u8, range: node.ByteRange) []const u8 {
    return source[range.start..range.end];
}

/// For Decls whose body is a `declaration_list` (Rust's container body for
/// `impl`, `trait`, and `mod`), return that list so the aligner recurses
/// into its inner Decls. Returns null for everything else - including
/// `mod m;` (no body), `struct_item`, `enum_item`, `union_item` (fields
/// and variants are not Decls).
fn containerListOf(list: *const node.List) ?*const node.List {
    const ts = list.ts_kind;
    if (!std.mem.eql(u8, ts, "impl_item") and
        !std.mem.eql(u8, ts, "trait_item") and
        !std.mem.eql(u8, ts, "mod_item"))
    {
        return null;
    }
    for (list.children) |*child| switch (child.*) {
        .list => |inner| if (std.mem.eql(u8, inner.ts_kind, "declaration_list")) {
            return &child.list;
        },
        .atom => {},
    };
    return null;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const treez = @import("treez");
const convert = @import("../sst/convert.zig");

fn parseRust(src: []const u8) !*treez.Tree {
    const lang = try treez.Language.get("rust");
    const parser = try treez.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang);
    return try parser.parseString(null, src);
}

const RustFixture = struct {
    ts_tree: *treez.Tree,
    res: convert.ConvertResult,

    fn deinit(self: *RustFixture) void {
        self.ts_tree.destroy();
    }
};

fn convertRust(arena: std.mem.Allocator, src: []const u8) !RustFixture {
    const ts_tree = try parseRust(src);
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
    try testing.expectEqual(result.DeclKind.function, classify("function_item"));
    try testing.expectEqual(result.DeclKind.container, classify("struct_item"));
    try testing.expectEqual(result.DeclKind.container, classify("enum_item"));
    try testing.expectEqual(result.DeclKind.container, classify("union_item"));
    try testing.expectEqual(result.DeclKind.container, classify("impl_item"));
    try testing.expectEqual(result.DeclKind.container, classify("trait_item"));
    try testing.expectEqual(result.DeclKind.container, classify("mod_item"));
    try testing.expectEqual(result.DeclKind.binding, classify("const_item"));
    try testing.expectEqual(result.DeclKind.binding, classify("static_item"));
    try testing.expectEqual(result.DeclKind.type_alias, classify("type_item"));
    try testing.expectEqual(result.DeclKind.import, classify("use_declaration"));
    try testing.expectEqual(result.DeclKind.other, classify("macro_definition"));
    try testing.expectEqual(result.DeclKind.other, classify("macro_invocation"));
    try testing.expectEqual(result.DeclKind.other, classify("arbitrary_unlisted_kind"));
}

// ── extractName ────────────────────────────────────────────────────────────

test "extractName: function_item identifier" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "fn foo() {}\n");
    defer fx.deinit();

    const fd = findTopDecl(&fx.res.tree.root.list, "function_item").?;
    const name = extractName(fd, fx.res.tree.source).?;
    try testing.expectEqualStrings("foo", name);
}

test "extractName: function_item with pub and async" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "pub async fn foo() {}\n");
    defer fx.deinit();

    const fd = findTopDecl(&fx.res.tree.root.list, "function_item").?;
    const name = extractName(fd, fx.res.tree.source).?;
    try testing.expectEqualStrings("foo", name);
}

test "extractName: struct_item type_identifier" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "struct Foo { x: i32 }\n");
    defer fx.deinit();

    const s = findTopDecl(&fx.res.tree.root.list, "struct_item").?;
    const name = extractName(s, fx.res.tree.source).?;
    try testing.expectEqualStrings("Foo", name);
}

test "extractName: enum_item" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "enum E { A, B }\n");
    defer fx.deinit();

    const e = findTopDecl(&fx.res.tree.root.list, "enum_item").?;
    const name = extractName(e, fx.res.tree.source).?;
    try testing.expectEqualStrings("E", name);
}

test "extractName: union_item" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "union U { a: i32, b: u32 }\n");
    defer fx.deinit();

    const u = findTopDecl(&fx.res.tree.root.list, "union_item").?;
    const name = extractName(u, fx.res.tree.source).?;
    try testing.expectEqualStrings("U", name);
}

test "extractName: trait_item" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "trait T { fn m(&self); }\n");
    defer fx.deinit();

    const t = findTopDecl(&fx.res.tree.root.list, "trait_item").?;
    const name = extractName(t, fx.res.tree.source).?;
    try testing.expectEqualStrings("T", name);
}

test "extractName: mod_item" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "mod m {}\n");
    defer fx.deinit();

    const m = findTopDecl(&fx.res.tree.root.list, "mod_item").?;
    const name = extractName(m, fx.res.tree.source).?;
    try testing.expectEqualStrings("m", name);
}

test "extractName: const_item" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "const X: i32 = 1;\n");
    defer fx.deinit();

    const c = findTopDecl(&fx.res.tree.root.list, "const_item").?;
    const name = extractName(c, fx.res.tree.source).?;
    try testing.expectEqualStrings("X", name);
}

test "extractName: static_item" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "static Y: i32 = 2;\n");
    defer fx.deinit();

    const s = findTopDecl(&fx.res.tree.root.list, "static_item").?;
    const name = extractName(s, fx.res.tree.source).?;
    try testing.expectEqualStrings("Y", name);
}

test "extractName: type_item" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "type Alias = i32;\n");
    defer fx.deinit();

    const t = findTopDecl(&fx.res.tree.root.list, "type_item").?;
    const name = extractName(t, fx.res.tree.source).?;
    try testing.expectEqualStrings("Alias", name);
}

test "extractName: use_declaration simple identifier" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "use foo;\n");
    defer fx.deinit();

    const u = findTopDecl(&fx.res.tree.root.list, "use_declaration").?;
    const name = extractName(u, fx.res.tree.source).?;
    try testing.expectEqualStrings("foo", name);
}

test "extractName: use_declaration scoped path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "use std::fmt::Write;\n");
    defer fx.deinit();

    const u = findTopDecl(&fx.res.tree.root.list, "use_declaration").?;
    const name = extractName(u, fx.res.tree.source).?;
    try testing.expectEqualStrings("std::fmt::Write", name);
}

test "extractName: impl_item without trait returns target type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "impl Foo { fn m(&self) {} }\n");
    defer fx.deinit();

    const i = findTopDecl(&fx.res.tree.root.list, "impl_item").?;
    const name = extractName(i, fx.res.tree.source).?;
    try testing.expectEqualStrings("Foo", name);
}

test "extractName: impl_item with trait returns target type (option a)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "impl Bar for Foo { fn m(&self) {} }\n");
    defer fx.deinit();

    const i = findTopDecl(&fx.res.tree.root.list, "impl_item").?;
    const name = extractName(i, fx.res.tree.source).?;
    try testing.expectEqualStrings("Foo", name);
}

test "extractName: macro_definition" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "macro_rules! foo { () => {}; }\n");
    defer fx.deinit();

    const md = findTopDecl(&fx.res.tree.root.list, "macro_definition").?;
    const name = extractName(md, fx.res.tree.source).?;
    try testing.expectEqualStrings("foo", name);
}

test "extractName: macro_invocation path (nested in expression_statement)" {
    // tree-sitter-rust wraps `foo!();` at the top level inside an
    // `expression_statement`, so the alignment engine (which only recurses
    // into containers listed in `container_ts_kinds` / `container_list_of`)
    // never encounters a `macro_invocation` node as a direct Decl today.
    // This unit test walks the tree manually to exercise `macroPath` for
    // the `path::foo` form regardless of whether the engine reaches it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "fn test() { path::foo!(); }\n");
    defer fx.deinit();

    // source_file → function_item → block → expression_statement
    //   → macro_invocation.
    const fn_item = findTopDecl(&fx.res.tree.root.list, "function_item").?;
    const mi = findDescendant(fn_item, "macro_invocation") orelse return error.NoMacroInvocation;
    const name = extractName(mi, fx.res.tree.source).?;
    try testing.expectEqualStrings("path::foo", name);
}

fn findDescendant(list: *const node.List, ts_kind: []const u8) ?*const node.List {
    for (list.children) |*child| switch (child.*) {
        .list => |l| {
            if (std.mem.eql(u8, l.ts_kind, ts_kind)) return &child.list;
            if (findDescendant(&child.list, ts_kind)) |found| return found;
        },
        .atom => {},
    };
    return null;
}

// ── containerListOf ──────────────────────────────────────────

test "containerListOf: impl_item returns its declaration_list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "impl Foo { fn m(&self) {} }\n");
    defer fx.deinit();

    const i = findTopDecl(&fx.res.tree.root.list, "impl_item").?;
    const inner = containerListOf(i).?;
    try testing.expectEqualStrings("declaration_list", inner.ts_kind);
}

test "containerListOf: trait_item returns its declaration_list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "trait T { fn m(&self); }\n");
    defer fx.deinit();

    const t = findTopDecl(&fx.res.tree.root.list, "trait_item").?;
    const inner = containerListOf(t).?;
    try testing.expectEqualStrings("declaration_list", inner.ts_kind);
}

test "containerListOf: mod_item with body returns its declaration_list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "mod m { fn a() {} }\n");
    defer fx.deinit();

    const m = findTopDecl(&fx.res.tree.root.list, "mod_item").?;
    const inner = containerListOf(m).?;
    try testing.expectEqualStrings("declaration_list", inner.ts_kind);
}

test "containerListOf: mod_item without body returns null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "mod m;\n");
    defer fx.deinit();

    const m = findTopDecl(&fx.res.tree.root.list, "mod_item").?;
    try testing.expect(containerListOf(m) == null);
}

test "containerListOf: struct_item returns null (fields are not Decls)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "struct Foo { x: i32 }\n");
    defer fx.deinit();

    const s = findTopDecl(&fx.res.tree.root.list, "struct_item").?;
    try testing.expect(containerListOf(s) == null);
}

test "containerListOf: function_item is not a container" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), "fn foo() {}\n");
    defer fx.deinit();

    const f = findTopDecl(&fx.res.tree.root.list, "function_item").?;
    try testing.expect(containerListOf(f) == null);
}

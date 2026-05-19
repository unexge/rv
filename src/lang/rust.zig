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
    .import_group_key = importGroupKey,
    .import_symbols = importSymbols,
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

// ── import-group hooks ──────────────────────────────────────────────────────
//
// `importGroupKey` and `importSymbols` together let the diff engine pair two
// `use foo::...;` declarations under the shared prefix `foo` and surface the
// brace-list delta as a per-symbol diff. See `result.ImportGroupDiff`.
//
// Both hooks operate on the same SST shape produced by tree-sitter-rust:
//
//   use_declaration
//     [visibility_modifier]      // `pub`, `pub(crate)` etc. - opt-out
//     "use"
//     <path>                     // identifier | scoped_identifier |
//                                // scoped_use_list | use_wildcard |
//                                // use_as_clause | use_list
//     ";"
//
// `scoped_identifier` is `<path> :: <name>` with three children
// `[<path>, "::", <name>]`. `scoped_use_list` is `<path> :: { ... }` with
// children `[<path>, "::", use_list]`. `use_as_clause` is `<path> as <alias>`
// with children `[<path>, "as", <alias>]`.

/// Returns the path prefix of a Rust `use_declaration` for import-group
/// alignment, or null to opt out. See the LangConfig hook contract.
fn importGroupKey(list: *const node.List, source: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, list.ts_kind, "use_declaration")) return null;

    const path_child = findUsePathChild(list) orelse return null;
    return prefixOfPath(path_child, source);
}

/// Find the path child of a `use_declaration` while opting out for `pub use`.
/// Returns null if a `visibility_modifier` is present anywhere in the decl,
/// or if no path child can be found.
fn findUsePathChild(list: *const node.List) ?*const node.Node {
    var path_child: ?*const node.Node = null;
    for (list.children) |*c| switch (c.*) {
        .atom => |a| {
            if (a.kind != .code) continue;
            // Skip the `use` keyword and trailing `;`. Anything else atomic
            // here is a single-identifier path like `use foo;`.
            if (std.mem.eql(u8, a.bytes, "use")) continue;
            if (std.mem.eql(u8, a.bytes, ";")) continue;
            if (path_child == null) path_child = c;
        },
        .list => |inner| {
            if (std.mem.eql(u8, inner.ts_kind, "visibility_modifier")) return null;
            if (path_child == null) path_child = c;
        },
    };
    return path_child;
}

/// Return the prefix slice of a path node, dropping the final segment.
/// Single-segment paths and wildcards return null (opt-out).
fn prefixOfPath(n: *const node.Node, source: []const u8) ?[]const u8 {
    return switch (n.*) {
        // Single identifier: `use foo;` - no `::`, no prefix.
        .atom => null,
        .list => |l| blk: {
            // `<prefix> :: <name>` and `<prefix> :: { ... }` both store the
            // prefix path as their first child. The `::` is contiguous in
            // source so the first child's byte range already excludes it.
            if (std.mem.eql(u8, l.ts_kind, "scoped_identifier") or
                std.mem.eql(u8, l.ts_kind, "scoped_use_list"))
            {
                if (l.children.len == 0) break :blk null;
                break :blk nodeSource(source, l.children[0].byteRange());
            }
            // `use foo::Bar as Baz;` - alignment keys off the path being
            // aliased, not the alias itself.
            if (std.mem.eql(u8, l.ts_kind, "use_as_clause")) {
                if (l.children.len == 0) break :blk null;
                break :blk prefixOfPath(&l.children[0], source);
            }
            // `use foo::*;`, `use { ... };`, or anything unrecognised: opt out.
            break :blk null;
        },
    };
}

/// Parse the leaf symbols of a Rust `use_declaration` in source order.
/// See `result.ImportSymbol` and the LangConfig hook contract.
fn importSymbols(
    arena: std.mem.Allocator,
    list: *const node.List,
    source: []const u8,
) std.mem.Allocator.Error![]const result.ImportSymbol {
    var entries: std.ArrayList(result.ImportSymbol) = .empty;
    if (!std.mem.eql(u8, list.ts_kind, "use_declaration")) {
        return entries.toOwnedSlice(arena);
    }

    if (findUsePathChild(list)) |pc| {
        try collectImportSymbols(arena, &entries, pc, source);
    }
    return entries.toOwnedSlice(arena);
}

fn collectImportSymbols(
    arena: std.mem.Allocator,
    entries: *std.ArrayList(result.ImportSymbol),
    n: *const node.Node,
    source: []const u8,
) std.mem.Allocator.Error!void {
    switch (n.*) {
        // Bare identifier: `use foo;` - emit `"foo"`.
        .atom => |a| try entries.append(arena, .{ .text = a.bytes }),
        .list => |l| {
            // `path :: name` - the symbol is the last segment.
            if (std.mem.eql(u8, l.ts_kind, "scoped_identifier")) {
                if (l.children.len > 0) {
                    const last = &l.children[l.children.len - 1];
                    try entries.append(arena, .{ .text = nodeSource(source, last.byteRange()) });
                }
                return;
            }
            // `path :: { ... }` - dispatch into the trailing use_list.
            if (std.mem.eql(u8, l.ts_kind, "scoped_use_list")) {
                if (l.children.len > 0) {
                    const last = &l.children[l.children.len - 1];
                    try collectImportSymbols(arena, entries, last, source);
                }
                return;
            }
            // Wildcard. `importGroupKey` opts out earlier; this branch is the
            // defensive fallback if `importSymbols` is called directly.
            if (std.mem.eql(u8, l.ts_kind, "use_wildcard")) {
                try entries.append(arena, .{ .text = "*" });
                return;
            }
            // Top-level `use <path> as <alias>;` - render as a single
            // `"<last_segment> as <alias>"` entry.
            if (std.mem.eql(u8, l.ts_kind, "use_as_clause")) {
                try entries.append(arena, .{ .text = renderUseAsClause(&l, source) });
                return;
            }
            // `{ a, b, ... }` brace list. Iterate comma-separated entries.
            if (std.mem.eql(u8, l.ts_kind, "use_list")) {
                for (l.children) |*child| switch (child.*) {
                    .atom => |a| {
                        if (a.kind != .code) continue;
                        if (std.mem.eql(u8, a.bytes, ",")) continue;
                        // Identifier-shaped atoms inside a use_list:
                        // `identifier`, `type_identifier`, `self`, `super`,
                        // `crate`. Surface raw bytes verbatim.
                        try entries.append(arena, .{ .text = a.bytes });
                    },
                    .list => |inner| {
                        if (std.mem.eql(u8, inner.ts_kind, "use_wildcard")) {
                            try entries.append(arena, .{ .text = "*" });
                        } else {
                            // `use_as_clause`, `scoped_identifier`, nested
                            // `use_list`, `scoped_use_list`. v1 does NOT
                            // flatten nested groups - surface the raw source
                            // slice (which already spans `<lhs> as <rhs>` for
                            // an as-clause) as a single ImportSymbol so
                            // callers see something coherent.
                            // TODO(v2): flatten nested groups into individual
                            // symbols.
                            try entries.append(arena, .{ .text = nodeSource(source, inner.byte_range) });
                        }
                    },
                };
                return;
            }
            // Unknown shape: surface the raw slice so the renderer has
            // *something* to display.
            try entries.append(arena, .{ .text = nodeSource(source, l.byte_range) });
        },
    }
}

/// Render a `use_as_clause` as `"<last_segment_of_path> as <alias>"` by
/// taking a single source slice that spans both, relying on the source
/// being contiguous in the buffer.
fn renderUseAsClause(l: *const node.List, source: []const u8) []const u8 {
    if (l.children.len < 1) return nodeSource(source, l.byte_range);
    const path_node = &l.children[0];
    const last_child = &l.children[l.children.len - 1];
    const lhs_range = lastSegmentRange(path_node);
    return source[lhs_range.start..last_child.byteRange().end];
}

fn lastSegmentRange(n: *const node.Node) node.ByteRange {
    return switch (n.*) {
        .atom => |a| a.byte_range,
        .list => |l| blk: {
            if (std.mem.eql(u8, l.ts_kind, "scoped_identifier") and l.children.len > 0) {
                break :blk l.children[l.children.len - 1].byteRange();
            }
            break :blk l.byte_range;
        },
    };
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

// ── importGroupKey ─────────────────────────────────────────────────────────────

fn expectImportGroupKey(src: []const u8, expected: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), src);
    defer fx.deinit();

    const u = findTopDecl(&fx.res.tree.root.list, "use_declaration").?;
    const got = importGroupKey(u, fx.res.tree.source);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "importGroupKey: single-segment use opts out" {
    try expectImportGroupKey("use foo;\n", null);
}

test "importGroupKey: scoped path returns prefix" {
    try expectImportGroupKey("use foo::Bar;\n", "foo");
}

test "importGroupKey: deep scoped path drops final segment" {
    try expectImportGroupKey("use foo::bar::Baz;\n", "foo::bar");
}

test "importGroupKey: brace list returns parent prefix" {
    try expectImportGroupKey("use foo::{a, b};\n", "foo");
}

test "importGroupKey: deep brace list returns parent prefix" {
    try expectImportGroupKey("use foo::bar::{a};\n", "foo::bar");
}

test "importGroupKey: wildcard opts out" {
    try expectImportGroupKey("use foo::*;\n", null);
}

test "importGroupKey: pub use opts out" {
    try expectImportGroupKey("pub use foo::Bar;\n", null);
}

test "importGroupKey: std::sync::Arc" {
    try expectImportGroupKey("use std::sync::Arc;\n", "std::sync");
}

test "importGroupKey: crate::foo::Bar" {
    try expectImportGroupKey("use crate::foo::Bar;\n", "crate::foo");
}

// ── importSymbols ───────────────────────────────────────────────────────────────

fn expectImportSymbols(src: []const u8, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertRust(arena.allocator(), src);
    defer fx.deinit();

    const u = findTopDecl(&fx.res.tree.root.list, "use_declaration").?;
    const got = try importSymbols(arena.allocator(), u, fx.res.tree.source);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| {
        try testing.expectEqualStrings(e, g.text);
    }
}

test "importSymbols: single scoped name" {
    try expectImportSymbols("use foo::Bar;\n", &.{"Bar"});
}

test "importSymbols: brace list of identifiers" {
    try expectImportSymbols("use foo::{a, b};\n", &.{ "a", "b" });
}

test "importSymbols: brace list with self" {
    try expectImportSymbols("use foo::{self, Bar};\n", &.{ "self", "Bar" });
}

test "importSymbols: top-level as-clause renders last segment" {
    try expectImportSymbols("use foo::Bar as Baz;\n", &.{"Bar as Baz"});
}

test "importSymbols: as-clause inside brace list" {
    try expectImportSymbols(
        "use foo::{a, b as c, d};\n",
        &.{ "a", "b as c", "d" },
    );
}

test "importSymbols: multi-line brace list trims whitespace" {
    try expectImportSymbols(
        "use foo::{\n  a,\n  b,\n};\n",
        &.{ "a", "b" },
    );
}

test "importSymbols: deep scoped path returns last segment" {
    try expectImportSymbols("use foo::bar::Baz;\n", &.{"Baz"});
}

test "importSymbols: nested scoped as-clause keeps full path" {
    // Inside a brace list, `use_as_clause` should surface the raw source
    // slice so a scoped path on the lhs (`c::d as alias`) is preserved
    // verbatim rather than collapsed to its last segment.
    try expectImportSymbols(
        "use foo::{c::d as alias};\n",
        &.{"c::d as alias"},
    );
}

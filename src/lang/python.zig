//! Python language configuration.
//!
//! ## Identity & naming
//!
//! Most Python Decls carry their name as a direct `name` field on the
//! tree-sitter node:
//!
//! - `function_definition`: first code atom after the `def` keyword.
//! - `class_definition`: first code atom after the `class` keyword.
//! - `decorated_definition`: unwrap to the inner function/class_definition
//!   for both classify and name. Decorators remain part of the subtree so
//!   body diffs still catch decorator edits.
//! - `import_statement` (`import a.b, c`): return the first imported module
//!   path as a slice of the source.
//! - `import_from_statement` (`from x import y`): return the module being
//!   imported from.
//! - `future_import_statement` (`from __future__ import annotations`):
//!   grammar distinguishes this as its own kind; the "from" module is
//!   always `__future__` so we return that literal for a stable identity.
//! - `assignment` at module level: return the LHS if it's a single simple
//!   identifier; `a, b = 1, 2` or `a.b = 1` etc. collapse to anonymous.
//!
//! ## Bare statements
//!
//! `if_statement`, `for_statement`, `while_statement`, `try_statement`,
//! and `with_statement` at module level are Decls with no name: they
//! fall through to Added/Removed unless hash-equal.
//!
//! Tree-sitter-python elides `expression_statement` and `_simple_statements`
//! at module scope - bare expressions like `print("hi")` surface as
//! their inner node (`call`, `binary_operator`, etc.) directly under
//! `module`. We list the common forms in `decl_ts_kinds` so they
//! register as anonymous Decls.
//!
//! ## Blocks
//!
//! Python blocks use INDENT/DEDENT tokens, not brace-style delimiters, so
//! `block` is converted as an ordinary List with empty open/close delims.
//! Class and function bodies are wrapped in a `block` node whose direct
//! children are the inner Decls; that's what `container_list_of` returns
//! for `class_definition`.
//!
//! ## Comments vs docstrings
//!
//! `#` comments classify as `AtomKind.comment`; docstrings are plain
//! string expression statements, so edits to a docstring surface as a
//! regular non-comment-only body change in v1.

const std = @import("std");
const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "python",
    // Flatten literals so name extraction can scan direct code atoms.
    .atom_ts_kinds = &.{
        "string",
        "concatenated_string",
        "integer",
        "float",
        "true",
        "false",
        "none",
        "identifier",
    },
    // INDENT/DEDENT are not listed because tree-sitter-python's `block`
    // node does not expose brace-style delimiter tokens - it relies on
    // scanner-generated invisible tokens. Only bracket forms use these.
    .delimiter_ts_kinds = &.{
        "(", ")",
        "{", "}",
        "[", "]",
    },
    .comment_ts_kinds = &.{"comment"},
    .decl_ts_kinds = &.{
        "function_definition",
        "class_definition",
        "decorated_definition",
        "import_statement",
        "import_from_statement",
        "future_import_statement",
        "assignment",
        "if_statement",
        "for_statement",
        "while_statement",
        "try_statement",
        "with_statement",
        // Tree-sitter-python elides `expression_statement` at the module
        // level - bare expressions surface as their inner node type
        // directly. Listing the common forms lets them register as
        // anonymous Decls so `print("hi")` at module level diffs cleanly.
        "call",
        "binary_operator",
        "comparison_operator",
        "unary_operator",
        "augmented_assignment",
    },
    // `module` is the root container and is passed directly to
    // `alignDecls`; listing it is a harmless no-op. `class_definition`
    // needs dynamic resolution to descend into its `block` body, so we
    // route through `container_list_of`.
    .container_ts_kinds = &.{},
    .classify = classify,
    .extract_name = extractName,
    .container_list_of = containerListOf,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    if (std.mem.eql(u8, ts_kind, "function_definition")) return .function;
    if (std.mem.eql(u8, ts_kind, "class_definition")) return .container;
    if (std.mem.eql(u8, ts_kind, "decorated_definition")) return .other;
    if (std.mem.eql(u8, ts_kind, "import_statement")) return .import;
    if (std.mem.eql(u8, ts_kind, "import_from_statement")) return .import;
    if (std.mem.eql(u8, ts_kind, "future_import_statement")) return .import;
    if (std.mem.eql(u8, ts_kind, "assignment")) return .binding;
    if (std.mem.eql(u8, ts_kind, "augmented_assignment")) return .binding;
    return .other;
}

/// Classify a Decl including decorated_definition unwrapping. Tests and
/// (future) callers that need the post-unwrap kind should prefer this.
pub fn classifyDecl(list: *const node.List) result.DeclKind {
    if (std.mem.eql(u8, list.ts_kind, "decorated_definition")) {
        if (innerDefinition(list)) |inner| return classify(inner.ts_kind);
        return .other;
    }
    return classify(list.ts_kind);
}

fn extractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = source;
    return extractNameInner(list);
}

fn extractNameInner(list: *const node.List) ?[]const u8 {
    const ts = list.ts_kind;
    if (std.mem.eql(u8, ts, "decorated_definition")) {
        const inner = innerDefinition(list) orelse return null;
        return extractNameInner(inner);
    }
    if (std.mem.eql(u8, ts, "function_definition") or
        std.mem.eql(u8, ts, "class_definition"))
    {
        return firstNonKeywordAtom(list);
    }
    if (std.mem.eql(u8, ts, "import_statement")) {
        return firstImportTarget(list);
    }
    if (std.mem.eql(u8, ts, "import_from_statement")) {
        return importFromModule(list);
    }
    if (std.mem.eql(u8, ts, "future_import_statement")) {
        return "__future__";
    }
    if (std.mem.eql(u8, ts, "assignment") or
        std.mem.eql(u8, ts, "augmented_assignment"))
    {
        return simpleAssignmentTarget(list);
    }
    return null;
}

/// Keywords that may appear as direct atom children of a Decl before the
/// name (e.g. `def foo`, `class Foo`, `async def foo`). Byte-level check
/// because the converter strips ts_kinds from anonymous tokens.
const skip_kw = [_][]const u8{
    "def",
    "class",
    "async",
    "lambda",
    ":",
    "*",
    "**",
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

/// Find the inner `function_definition` or `class_definition` of a
/// `decorated_definition`. Decorators are wrapped in `decorator` Lists
/// and precede the inner def; returns null if no def/class is nested.
fn innerDefinition(list: *const node.List) ?*const node.List {
    for (list.children) |*child| switch (child.*) {
        .list => |inner| {
            if (std.mem.eql(u8, inner.ts_kind, "function_definition") or
                std.mem.eql(u8, inner.ts_kind, "class_definition"))
            {
                return &child.list;
            }
        },
        .atom => {},
    };
    return null;
}

/// First imported module path of an `import_statement`. Grammar wraps
/// each imported target in a `dotted_name` or `aliased_import` list.
fn firstImportTarget(list: *const node.List) ?[]const u8 {
    for (list.children) |*child| switch (child.*) {
        .list => |inner| {
            if (std.mem.eql(u8, inner.ts_kind, "dotted_name")) {
                return firstCodeAtom(&child.list);
            }
            if (std.mem.eql(u8, inner.ts_kind, "aliased_import")) {
                // The aliased form is `module as alias`; match on the
                // original module path by returning its first code atom.
                return firstCodeAtomRec(&child.list);
            }
        },
        .atom => |a| {
            if (a.kind == .code and !isSkipKeyword(a.bytes) and
                !std.mem.eql(u8, a.bytes, "import") and
                !std.mem.eql(u8, a.bytes, ","))
            {
                return a.bytes;
            }
        },
    };
    return null;
}

/// Module being imported from in `from X import ...`. The grammar tags
/// the module position with the `module_name` field, which surfaces as
/// a `dotted_name` child. There is also a `relative_import` node for
/// `from . import x` forms.
fn importFromModule(list: *const node.List) ?[]const u8 {
    for (list.children) |*child| switch (child.*) {
        .list => |inner| {
            if (std.mem.eql(u8, inner.ts_kind, "dotted_name")) {
                return firstCodeAtom(&child.list);
            }
            if (std.mem.eql(u8, inner.ts_kind, "relative_import")) {
                // `from . import x` - use the dotted prefix as identity.
                return firstCodeAtomRec(&child.list) orelse ".";
            }
        },
        .atom => {},
    };
    return null;
}

/// If the LHS of an `assignment` is a single simple identifier, return
/// it. Otherwise return null (tuple targets, attribute targets, etc.).
///
/// Grammar: `assignment` has a `left` field. In the converted SST the
/// LHS appears as the first List/atom before the `=` atom.
fn simpleAssignmentTarget(list: *const node.List) ?[]const u8 {
    // The first child is the LHS. It's either a single `identifier` atom
    // (flattened via atom_ts_kinds) or a more complex List (pattern /
    // attribute / subscript). Anything but an atom → anonymous.
    if (list.children.len == 0) return null;
    return switch (list.children[0]) {
        .atom => |a| if (a.kind == .code and !isSkipKeyword(a.bytes)) a.bytes else null,
        .list => null,
    };
}

fn firstCodeAtom(list: *const node.List) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .atom => |a| if (a.kind == .code) return a.bytes,
        .list => {},
    };
    return null;
}

/// Walk a List for the first code atom anywhere inside it.
fn firstCodeAtomRec(list: *const node.List) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .atom => |a| if (a.kind == .code) return a.bytes,
        .list => |inner| if (firstCodeAtomRec(&inner)) |got| return got,
    };
    return null;
}

/// For containers: `class_definition` → its `block` child (whose children
/// are the inner Decls). `decorated_definition` wrapping a class →
/// the inner class's block. Everything else returns null.
fn containerListOf(list: *const node.List) ?*const node.List {
    if (std.mem.eql(u8, list.ts_kind, "decorated_definition")) {
        const inner = innerDefinition(list) orelse return null;
        return containerListOf(inner);
    }
    if (!std.mem.eql(u8, list.ts_kind, "class_definition")) return null;
    for (list.children) |*child| switch (child.*) {
        .list => |inner| if (std.mem.eql(u8, inner.ts_kind, "block")) {
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

fn parsePython(src: []const u8) !*treez.Tree {
    const lang = try treez.Language.get("python");
    const parser = try treez.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang);
    return try parser.parseString(null, src);
}

const PyFixture = struct {
    ts_tree: *treez.Tree,
    res: convert.ConvertResult,

    fn deinit(self: *PyFixture) void {
        self.ts_tree.destroy();
    }
};

fn convertPython(arena: std.mem.Allocator, src: []const u8) !PyFixture {
    const ts_tree = try parsePython(src);
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
    try testing.expectEqual(result.DeclKind.function, classify("function_definition"));
    try testing.expectEqual(result.DeclKind.container, classify("class_definition"));
    try testing.expectEqual(result.DeclKind.other, classify("decorated_definition"));
    try testing.expectEqual(result.DeclKind.import, classify("import_statement"));
    try testing.expectEqual(result.DeclKind.import, classify("import_from_statement"));
    try testing.expectEqual(result.DeclKind.import, classify("future_import_statement"));
    try testing.expectEqual(result.DeclKind.binding, classify("assignment"));
    try testing.expectEqual(result.DeclKind.binding, classify("augmented_assignment"));
    try testing.expectEqual(result.DeclKind.other, classify("if_statement"));
    try testing.expectEqual(result.DeclKind.other, classify("for_statement"));
    try testing.expectEqual(result.DeclKind.other, classify("call"));
    try testing.expectEqual(result.DeclKind.other, classify("arbitrary_unlisted_kind"));
}

test "classifyDecl: decorated_definition unwraps to inner .function" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(),
        "@decorator\ndef foo():\n    pass\n",
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const d = findTopDecl(root, "decorated_definition").?;
    try testing.expectEqual(result.DeclKind.function, classifyDecl(d));
}

test "classifyDecl: decorated_definition unwraps to inner .container" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(),
        "@register\nclass Thing:\n    pass\n",
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const d = findTopDecl(root, "decorated_definition").?;
    try testing.expectEqual(result.DeclKind.container, classifyDecl(d));
}

// ── extractName ────────────────────────────────────────────────────────────

test "extractName: function_definition identifier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "def foo():\n    pass\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const fd = findTopDecl(root, "function_definition").?;
    const name = extractName(fd, fx.res.tree.source).?;
    try testing.expectEqualStrings("foo", name);
}

test "extractName: async function_definition identifier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "async def foo():\n    pass\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const fd = findTopDecl(root, "function_definition").?;
    const name = extractName(fd, fx.res.tree.source).?;
    try testing.expectEqualStrings("foo", name);
}

test "extractName: class_definition identifier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "class Thing:\n    pass\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const cd = findTopDecl(root, "class_definition").?;
    const name = extractName(cd, fx.res.tree.source).?;
    try testing.expectEqualStrings("Thing", name);
}

test "extractName: decorated_definition unwraps to inner function name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(),
        "@decorator\ndef foo():\n    pass\n",
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const dd = findTopDecl(root, "decorated_definition").?;
    const name = extractName(dd, fx.res.tree.source).?;
    try testing.expectEqualStrings("foo", name);
}

test "extractName: decorated_definition with multiple decorators unwraps to inner class" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(),
        "@a\n@b\nclass Thing:\n    pass\n",
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const dd = findTopDecl(root, "decorated_definition").?;
    const name = extractName(dd, fx.res.tree.source).?;
    try testing.expectEqualStrings("Thing", name);
}

test "extractName: import_statement single module" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "import os\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const im = findTopDecl(root, "import_statement").?;
    const name = extractName(im, fx.res.tree.source).?;
    try testing.expectEqualStrings("os", name);
}

test "extractName: import_statement dotted module returns first segment atom" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "import os.path\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const im = findTopDecl(root, "import_statement").?;
    const name = extractName(im, fx.res.tree.source).?;
    // dotted_name is flattened to its first segment's atom - good
    // enough for identity-key purposes (both sides agree).
    try testing.expectEqualStrings("os", name);
}

test "extractName: import_from_statement returns the source module" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "from os import path\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const im = findTopDecl(root, "import_from_statement").?;
    const name = extractName(im, fx.res.tree.source).?;
    try testing.expectEqualStrings("os", name);
}

test "extractName: future_import_statement returns __future__" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(),
        "from __future__ import annotations\n",
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const im = findTopDecl(root, "future_import_statement").?;
    const name = extractName(im, fx.res.tree.source).?;
    try testing.expectEqualStrings("__future__", name);
}

test "extractName: assignment with simple identifier LHS" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "x = 1\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const a = findTopDecl(root, "assignment").?;
    const name = extractName(a, fx.res.tree.source).?;
    try testing.expectEqualStrings("x", name);
}

test "extractName: assignment with tuple LHS is anonymous" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "a, b = 1, 2\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const a = findTopDecl(root, "assignment").?;
    try testing.expect(extractName(a, fx.res.tree.source) == null);
}

test "extractName: augmented_assignment with simple identifier LHS" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "x += 1\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const a = findTopDecl(root, "augmented_assignment").?;
    const name = extractName(a, fx.res.tree.source).?;
    try testing.expectEqualStrings("x", name);
}

test "extractName: bare module-level call is anonymous" {
    // Tree-sitter-python elides `expression_statement` at module level, so
    // `print("hi")` surfaces as a bare `call` node directly under `module`.
    // The task still wants this to be an anonymous Decl that participates
    // in alignment; `extract_name` returns null so it falls through to
    // Added/Removed unless hash-equal.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "print(\"hi\")\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const call = findTopDecl(root, "call").?;
    try testing.expect(extractName(call, fx.res.tree.source) == null);
}

test "extractName: if_statement at module level is anonymous" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(),
        "if __name__ == \"__main__\":\n    pass\n",
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const is = findTopDecl(root, "if_statement").?;
    try testing.expect(extractName(is, fx.res.tree.source) == null);
}

// ── containerListOf ────────────────────────────────────────────────────────

test "containerListOf: class_definition returns its block" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(),
        "class Thing:\n    def m(self):\n        pass\n",
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const cd = findTopDecl(root, "class_definition").?;
    const inner = containerListOf(cd).?;
    try testing.expectEqualStrings("block", inner.ts_kind);
}

test "containerListOf: decorated class returns inner block" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(),
        "@dec\nclass Thing:\n    def m(self):\n        pass\n",
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const dd = findTopDecl(root, "decorated_definition").?;
    const inner = containerListOf(dd).?;
    try testing.expectEqualStrings("block", inner.ts_kind);
}

test "containerListOf: function_definition is not a container" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "def foo():\n    pass\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const fd = findTopDecl(root, "function_definition").?;
    try testing.expect(containerListOf(fd) == null);
}

test "containerListOf: assignment is not a container" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var fx = try convertPython(arena_state.allocator(), "x = 1\n");
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    const a = findTopDecl(root, "assignment").?;
    try testing.expect(containerListOf(a) == null);
}

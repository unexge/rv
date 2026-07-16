//! TypeScript language configuration.
//!
//! v1 uses the `"typescript"` grammar. TSX support would be a second
//! `LangConfig` (likely a new `LanguageId.tsx` variant) and is out of scope
//! for v1.
//!
//! ## Grammar idiosyncrasies worth knowing
//!
//! - The root node type is `program`, not `source_file`.
//! - Overload signatures parse as `function_signature`, not
//!   `function_declaration`. The task description says "two
//!   function_declaration nodes"; the grammar disagrees. Both node types
//!   appear in `decl_ts_kinds` so overloads + implementation all surface
//!   as Decls. Two `function_signature`s with the same name disambiguate
//!   via the occurrence-index tiebreak in `diff/align.zig`.
//! - Top-level `namespace N {}` parses as `expression_statement >
//!   internal_module` (tree-sitter-typescript treats `namespace` as a
//!   contextual keyword). At top level it therefore does not surface as
//!   a Decl in v1. `internal_module` is still listed as a decl/container
//!   so that a nested namespace (inside another namespace) behaves
//!   correctly.
//! - `const { a, b } = obj` is a `lexical_declaration` whose
//!   `variable_declarator` has an `object_pattern` instead of an
//!   `identifier`. `extract_name` returns null for these.
//!
//! ## export_statement handling
//!
//! `export function foo() {}` parses as
//! `export_statement > [Atom "export", function_declaration]`. We keep
//! `export_statement` as the outer Decl so toggling `export` surfaces as
//! a Changed body edit (the `export` atom appears/disappears), and we
//! unwrap in `extract_name` so the name "foo" is visible. `classify`
//! only sees the outer ts_kind string and falls back to `.import`;
//! refining it to the inner kind would require a signature change on
//! `LangConfig.classify`, which is out of scope.
//!
//! Container handling for `export class Foo {}` is also kept simple:
//! export_statement is a leaf Decl; inner container changes show up as
//! leaf edits. `container_list_of` could be taught to descend through
//! export_statement in phase 2 if the UX demands it.

const std = @import("std");
const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "typescript",
    // Flatten literals and identifier-like named leaves into single Atoms
    // so the "scan direct atoms" name-extraction helper can find them.
    // Without flattening, named leaves (no children) would convert to
    // empty Lists and be invisible.
    .atom_ts_kinds = &.{
        "string",
        "template_string",
        "regex",
        "number",
        "true",
        "false",
        "null",
        "undefined",
        "identifier",
        "type_identifier",
        "property_identifier",
        "shorthand_property_identifier",
        "shorthand_property_identifier_pattern",
        "predefined_type",
        "this",
        "super",
    },
    .delimiter_ts_kinds = &.{
        "(", ")",
        "{", "}",
        "[", "]",
    },
    .comment_ts_kinds = &.{"comment"},
    .decl_ts_kinds = &.{
        "function_declaration",
        "function_signature",
        "generator_function_declaration",
        "method_definition",
        "abstract_method_signature",
        "class_declaration",
        "abstract_class_declaration",
        "interface_declaration",
        "type_alias_declaration",
        "enum_declaration",
        "variable_declaration",
        "lexical_declaration",
        "import_statement",
        "export_statement",
        "internal_module",
        "module",
    },
    // Containers descend via `container_list_of`: their bodies live one
    // level deeper (class_body / interface_body / statement_block), so
    // they can't use the static `container_ts_kinds` path which treats
    // the Decl list itself as the container.
    .container_ts_kinds = &.{},
    .classify = classify,
    .classify_decl = classifyDecl,
    .extract_name = extractName,
    .container_list_of = containerListOf,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    if (std.mem.eql(u8, ts_kind, "function_declaration")) return .function;
    if (std.mem.eql(u8, ts_kind, "function_signature")) return .function;
    if (std.mem.eql(u8, ts_kind, "generator_function_declaration")) return .function;
    if (std.mem.eql(u8, ts_kind, "method_definition")) return .function;
    if (std.mem.eql(u8, ts_kind, "abstract_method_signature")) return .function;
    if (std.mem.eql(u8, ts_kind, "class_declaration")) return .container;
    if (std.mem.eql(u8, ts_kind, "abstract_class_declaration")) return .container;
    if (std.mem.eql(u8, ts_kind, "interface_declaration")) return .container;
    if (std.mem.eql(u8, ts_kind, "enum_declaration")) return .container;
    if (std.mem.eql(u8, ts_kind, "internal_module")) return .container;
    if (std.mem.eql(u8, ts_kind, "module")) return .container;
    if (std.mem.eql(u8, ts_kind, "type_alias_declaration")) return .type_alias;
    if (std.mem.eql(u8, ts_kind, "variable_declaration")) return .binding;
    if (std.mem.eql(u8, ts_kind, "lexical_declaration")) return .binding;
    if (std.mem.eql(u8, ts_kind, "import_statement")) return .import;
    if (std.mem.eql(u8, ts_kind, "export_statement")) return .import;
    return .other;
}

fn classifyDecl(list: *const node.List) result.DeclKind {
    if (!std.mem.eql(u8, list.ts_kind, "export_statement")) {
        return classify(list.ts_kind);
    }
    for (list.children) |child| switch (child) {
        .list => |inner| {
            if (isUnwrappableExportKind(inner.ts_kind)) {
                return classify(inner.ts_kind);
            }
        },
        .atom => {},
    };
    return .import;
}

/// Modifier keywords and punctuation we skip when scanning direct atom
/// children for a Decl's name. Modifiers appear as anonymous tokens
/// (their ts_kind equals their literal text), not wrapped in named Lists
/// as Rust does, so they end up as code atoms in the converted List.
const skip_kw = [_][]const u8{
    "function",
    "class",
    "interface",
    "type",
    "enum",
    "const",
    "let",
    "var",
    "import",
    "export",
    "from",
    "default",
    "namespace",
    "module",
    "declare",
    "async",
    "static",
    "get",
    "set",
    "public",
    "private",
    "protected",
    "readonly",
    "abstract",
    "override",
    "*",
    "=",
    ";",
    ",",
};

fn isSkipKeyword(bytes: []const u8) bool {
    for (skip_kw) |kw| {
        if (std.mem.eql(u8, kw, bytes)) return true;
    }
    return false;
}

fn extractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = source;
    const ts = list.ts_kind;

    if (std.mem.eql(u8, ts, "function_declaration") or
        std.mem.eql(u8, ts, "function_signature") or
        std.mem.eql(u8, ts, "generator_function_declaration") or
        std.mem.eql(u8, ts, "method_definition") or
        std.mem.eql(u8, ts, "abstract_method_signature") or
        std.mem.eql(u8, ts, "class_declaration") or
        std.mem.eql(u8, ts, "abstract_class_declaration") or
        std.mem.eql(u8, ts, "interface_declaration") or
        std.mem.eql(u8, ts, "type_alias_declaration") or
        std.mem.eql(u8, ts, "enum_declaration") or
        std.mem.eql(u8, ts, "internal_module") or
        std.mem.eql(u8, ts, "module"))
    {
        return firstNonKeywordAtom(list);
    }

    if (std.mem.eql(u8, ts, "variable_declaration") or
        std.mem.eql(u8, ts, "lexical_declaration"))
    {
        return firstDeclaratorName(list);
    }

    if (std.mem.eql(u8, ts, "import_statement")) {
        return firstNonKeywordAtom(list);
    }

    if (std.mem.eql(u8, ts, "export_statement")) {
        return exportName(list);
    }

    return null;
}

/// Scan direct Atom children and return the first code atom whose bytes
/// aren't one of the modifier keywords. Used for
/// function/class/interface/type/enum/namespace/module declarations
/// (first significant identifier) and import declarations (first
/// significant atom, which is the quoted module source string - the
/// identifiers in `import X from "a"` live inside a wrapping
/// `import_clause` List and so never surface here).
///
/// NOTE: `variable_declaration` / `lexical_declaration` use
/// `firstDeclaratorName` instead - they need per-declarator inspection
/// to detect destructuring patterns, which this helper does not model.
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

/// For a variable / lexical declaration, return the identifier of the
/// first `variable_declarator`, or null if that declarator binds a
/// destructuring pattern. Subsequent declarators (`const a = 1, b = 2`)
/// are ignored per task spec.
fn firstDeclaratorName(list: *const node.List) ?[]const u8 {
    for (list.children) |c| switch (c) {
        .list => |inner| {
            if (std.mem.eql(u8, inner.ts_kind, "variable_declarator")) {
                return declaratorBindingName(inner);
            }
        },
        .atom => {},
    };
    return null;
}

/// Inspect a `variable_declarator` in source order: an `object_pattern` /
/// `array_pattern` List means destructuring (anonymous, returns null).
/// An identifier atom is the simple binding name. Stop at `=` to avoid
/// returning the RHS of a destructuring declarator (whose grammar shape
/// is `[pattern, "=", identifier]`).
fn declaratorBindingName(declarator: node.List) ?[]const u8 {
    for (declarator.children) |c| switch (c) {
        .list => |inner| {
            if (std.mem.eql(u8, inner.ts_kind, "object_pattern") or
                std.mem.eql(u8, inner.ts_kind, "array_pattern"))
            {
                return null;
            }
            // Any other list child (type_annotation, etc.) is not the
            // binding name; skip it and keep scanning for the identifier
            // atom or the `=` token.
        },
        .atom => |a| {
            if (a.kind != .code) continue;
            if (std.mem.eql(u8, a.bytes, "=")) return null;
            return a.bytes;
        },
    };
    return null;
}

/// Unwrap an `export_statement` to the inner declaration's name.
///
/// `export function foo() {}` → inner `function_declaration` → "foo".
/// `export const x = 1;` → inner `lexical_declaration` → "x".
/// `export default function foo() {}` → inner `function_declaration`
/// (after the "default" atom) → "foo".
///
/// Re-export forms without an inner declaration (`export { foo };`,
/// `export * from "a";`, `export default 42;`) fall back to the first
/// string atom, which is the module source for `export ... from "..."`
/// and null for the rest.
fn exportName(list: *const node.List) ?[]const u8 {
    for (list.children) |*c| switch (c.*) {
        .list => |inner| {
            if (isUnwrappableExportKind(inner.ts_kind)) {
                // `extractName` ignores its source parameter for TS (every
                // name comes from borrowed atom bytes, which already slice
                // into the original source). Passing "" is safe today; if
                // an inner branch ever starts consuming source, thread it
                // through here too.
                return extractName(&c.list, "");
            }
        },
        .atom => {},
    };
    // Fallback: `export * from "a";` / `export { foo } from "a";` - treat
    // the module source as the name. Bare re-exports with no source
    // (`export { foo };`) fall through to null.
    for (list.children) |c| switch (c) {
        .atom => |a| {
            if (a.kind != .code) continue;
            if (a.bytes.len == 0) continue;
            if (a.bytes[0] == '"' or a.bytes[0] == '\'') return a.bytes;
        },
        .list => {},
    };
    return null;
}

fn isUnwrappableExportKind(ts_kind: []const u8) bool {
    return std.mem.eql(u8, ts_kind, "function_declaration") or
        std.mem.eql(u8, ts_kind, "function_signature") or
        std.mem.eql(u8, ts_kind, "generator_function_declaration") or
        std.mem.eql(u8, ts_kind, "class_declaration") or
        std.mem.eql(u8, ts_kind, "abstract_class_declaration") or
        std.mem.eql(u8, ts_kind, "interface_declaration") or
        std.mem.eql(u8, ts_kind, "type_alias_declaration") or
        std.mem.eql(u8, ts_kind, "enum_declaration") or
        std.mem.eql(u8, ts_kind, "variable_declaration") or
        std.mem.eql(u8, ts_kind, "lexical_declaration") or
        std.mem.eql(u8, ts_kind, "internal_module") or
        std.mem.eql(u8, ts_kind, "module");
}

/// Inner-body list for container Decls. Class/interface/enum/namespace/
/// module wrap their members in a dedicated body List whose children are
/// the member Decls. Returning that inner list lets the aligner recurse
/// directly into the members.
fn containerListOf(list: *const node.List) ?*const node.List {
    const ts = list.ts_kind;
    if (std.mem.eql(u8, ts, "class_declaration") or
        std.mem.eql(u8, ts, "abstract_class_declaration"))
    {
        return findChildList(list, "class_body");
    }
    if (std.mem.eql(u8, ts, "interface_declaration")) {
        return findChildList(list, "interface_body") orelse
            findChildList(list, "object_type");
    }
    if (std.mem.eql(u8, ts, "internal_module") or
        std.mem.eql(u8, ts, "module"))
    {
        return findChildList(list, "statement_block");
    }
    // enum_declaration: enum members are `property_identifier`s /
    // `enum_assignment`s, not Decls in our model. Treat enum as a leaf
    // Decl - body edits appear as an edit script.
    return null;
}

fn findChildList(list: *const node.List, ts_kind: []const u8) ?*const node.List {
    for (list.children) |*child| switch (child.*) {
        .list => |inner| if (std.mem.eql(u8, inner.ts_kind, ts_kind)) return &child.list,
        .atom => {},
    };
    return null;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const treez = @import("treez");
const convert = @import("../sst/convert.zig");

fn parseTs(src: []const u8) !*treez.Tree {
    const lang = try treez.Language.get("typescript");
    const parser = try treez.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang);
    return try parser.parseString(null, src);
}

const TsFixture = struct {
    ts_tree: *treez.Tree,
    res: convert.ConvertResult,

    fn deinit(self: *TsFixture) void {
        self.ts_tree.destroy();
    }
};

fn convertTs(arena: std.mem.Allocator, src: []const u8) !TsFixture {
    const ts_tree = try parseTs(src);
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
    try testing.expectEqual(result.DeclKind.function, classify("function_signature"));
    try testing.expectEqual(result.DeclKind.function, classify("generator_function_declaration"));
    try testing.expectEqual(result.DeclKind.function, classify("method_definition"));
    try testing.expectEqual(result.DeclKind.function, classify("abstract_method_signature"));
    try testing.expectEqual(result.DeclKind.container, classify("class_declaration"));
    try testing.expectEqual(result.DeclKind.container, classify("abstract_class_declaration"));
    try testing.expectEqual(result.DeclKind.container, classify("interface_declaration"));
    try testing.expectEqual(result.DeclKind.container, classify("enum_declaration"));
    try testing.expectEqual(result.DeclKind.container, classify("internal_module"));
    try testing.expectEqual(result.DeclKind.container, classify("module"));
    try testing.expectEqual(result.DeclKind.type_alias, classify("type_alias_declaration"));
    try testing.expectEqual(result.DeclKind.binding, classify("variable_declaration"));
    try testing.expectEqual(result.DeclKind.binding, classify("lexical_declaration"));
    try testing.expectEqual(result.DeclKind.import, classify("import_statement"));
    try testing.expectEqual(result.DeclKind.import, classify("export_statement"));
    try testing.expectEqual(result.DeclKind.other, classify("arbitrary_unlisted_kind"));
}

// ── extractName ────────────────────────────────────────────────────────────

test "extractName: function_declaration identifier" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "function foo(): void {}\n");
    defer fx.deinit();

    const fd = findTopDecl(&fx.res.tree.root.list, "function_declaration").?;
    try testing.expectEqualStrings("foo", extractName(fd, fx.res.tree.source).?);
}

test "extractName: function_signature identifier (overload signature)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "function foo(x: number): void;\n");
    defer fx.deinit();

    const fs = findTopDecl(&fx.res.tree.root.list, "function_signature").?;
    try testing.expectEqualStrings("foo", extractName(fs, fx.res.tree.source).?);
}

test "extractName: class_declaration type_identifier" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "class C {}\n");
    defer fx.deinit();

    const c = findTopDecl(&fx.res.tree.root.list, "class_declaration").?;
    try testing.expectEqualStrings("C", extractName(c, fx.res.tree.source).?);
}

test "extractName: interface_declaration type_identifier" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "interface I { m(): void; }\n");
    defer fx.deinit();

    const i = findTopDecl(&fx.res.tree.root.list, "interface_declaration").?;
    try testing.expectEqualStrings("I", extractName(i, fx.res.tree.source).?);
}

test "extractName: type_alias_declaration" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "type Alias = number;\n");
    defer fx.deinit();

    const t = findTopDecl(&fx.res.tree.root.list, "type_alias_declaration").?;
    try testing.expectEqualStrings("Alias", extractName(t, fx.res.tree.source).?);
}

test "extractName: enum_declaration" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "enum E { A, B }\n");
    defer fx.deinit();

    const e = findTopDecl(&fx.res.tree.root.list, "enum_declaration").?;
    try testing.expectEqualStrings("E", extractName(e, fx.res.tree.source).?);
}

test "extractName: lexical_declaration (const) single binding" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "const x = 1;\n");
    defer fx.deinit();

    const ld = findTopDecl(&fx.res.tree.root.list, "lexical_declaration").?;
    try testing.expectEqualStrings("x", extractName(ld, fx.res.tree.source).?);
}

test "extractName: lexical_declaration with multiple declarators returns the first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "const a = 1, b = 2;\n");
    defer fx.deinit();

    const ld = findTopDecl(&fx.res.tree.root.list, "lexical_declaration").?;
    try testing.expectEqualStrings("a", extractName(ld, fx.res.tree.source).?);
}

test "extractName: variable_declaration (var)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "var y = 5;\n");
    defer fx.deinit();

    const vd = findTopDecl(&fx.res.tree.root.list, "variable_declaration").?;
    try testing.expectEqualStrings("y", extractName(vd, fx.res.tree.source).?);
}

test "extractName: destructuring object pattern returns null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "const { a, b } = obj;\n");
    defer fx.deinit();

    const ld = findTopDecl(&fx.res.tree.root.list, "lexical_declaration").?;
    try testing.expect(extractName(ld, fx.res.tree.source) == null);
}

test "extractName: destructuring array pattern returns null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "const [x, y] = arr;\n");
    defer fx.deinit();

    const ld = findTopDecl(&fx.res.tree.root.list, "lexical_declaration").?;
    try testing.expect(extractName(ld, fx.res.tree.source) == null);
}

test "extractName: import_statement returns module source string" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "import X from \"react\";\n");
    defer fx.deinit();

    const im = findTopDecl(&fx.res.tree.root.list, "import_statement").?;
    try testing.expectEqualStrings("\"react\"", extractName(im, fx.res.tree.source).?);
}

test "extractName: bare import returns module source" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "import \"side-effect\";\n");
    defer fx.deinit();

    const im = findTopDecl(&fx.res.tree.root.list, "import_statement").?;
    try testing.expectEqualStrings("\"side-effect\"", extractName(im, fx.res.tree.source).?);
}

test "extractName: export_statement unwraps to inner function_declaration name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "export function foo() {}\n");
    defer fx.deinit();

    const es = findTopDecl(&fx.res.tree.root.list, "export_statement").?;
    try testing.expectEqualStrings("foo", extractName(es, fx.res.tree.source).?);
}

test "extractName: export_statement with lexical_declaration unwraps to binding name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "export const x = 1;\n");
    defer fx.deinit();

    const es = findTopDecl(&fx.res.tree.root.list, "export_statement").?;
    try testing.expectEqualStrings("x", extractName(es, fx.res.tree.source).?);
}

test "extractName: export default function unwraps to inner name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "export default function foo() {}\n");
    defer fx.deinit();

    const es = findTopDecl(&fx.res.tree.root.list, "export_statement").?;
    try testing.expectEqualStrings("foo", extractName(es, fx.res.tree.source).?);
}

test "export_statement: classify inner decl is .function for export function" {
    // classify() only sees the outer ts_kind, so the unwrap is exercised
    // via extract_name; the inner-decl classification is verified by
    // pulling out the inner List and classifying that directly. This is
    // what the engine does one level down via containerListOf for class
    // exports.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "export function foo() {}\n");
    defer fx.deinit();

    const es = findTopDecl(&fx.res.tree.root.list, "export_statement").?;

    // Find the inner decl child, confirm it classifies as .function.
    var inner_kind: ?[]const u8 = null;
    for (es.children) |c| switch (c) {
        .list => |l| {
            if (isUnwrappableExportKind(l.ts_kind)) {
                inner_kind = l.ts_kind;
                break;
            }
        },
        .atom => {},
    };
    const kind = inner_kind orelse return error.NoInnerDecl;
    try testing.expectEqual(result.DeclKind.function, classify(kind));
}

test "extractName: bare re-export `export { foo };` returns null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "export { foo };\n");
    defer fx.deinit();

    const es = findTopDecl(&fx.res.tree.root.list, "export_statement").?;
    try testing.expect(extractName(es, fx.res.tree.source) == null);
}

test "extractName: method_definition via class descent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "class C { m() {} }\n");
    defer fx.deinit();

    const c = findTopDecl(&fx.res.tree.root.list, "class_declaration").?;
    const body = containerListOf(c).?;
    try testing.expectEqualStrings("class_body", body.ts_kind);
    const m = findTopDecl(body, "method_definition").?;
    try testing.expectEqualStrings("m", extractName(m, fx.res.tree.source).?);
}

test "extractName: method_definition with get/async modifiers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "class C { async get p() { return 1; } }\n");
    defer fx.deinit();

    const c = findTopDecl(&fx.res.tree.root.list, "class_declaration").?;
    const body = containerListOf(c).?;
    const m = findTopDecl(body, "method_definition").?;
    try testing.expectEqualStrings("p", extractName(m, fx.res.tree.source).?);
}

// ── containerListOf ────────────────────────────────────────────────────────

test "containerListOf: class_declaration returns class_body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "class C { m() {} }\n");
    defer fx.deinit();

    const c = findTopDecl(&fx.res.tree.root.list, "class_declaration").?;
    const inner = containerListOf(c).?;
    try testing.expectEqualStrings("class_body", inner.ts_kind);
}

test "containerListOf: interface_declaration returns interface_body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "interface I { m(): void; }\n");
    defer fx.deinit();

    const i = findTopDecl(&fx.res.tree.root.list, "interface_declaration").?;
    const inner = containerListOf(i).?;
    try testing.expectEqualStrings("interface_body", inner.ts_kind);
}

test "containerListOf: function_declaration is not a container" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "function f() {}\n");
    defer fx.deinit();

    const f = findTopDecl(&fx.res.tree.root.list, "function_declaration").?;
    try testing.expect(containerListOf(f) == null);
}

test "containerListOf: enum_declaration is not a container (leaf body)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(), "enum E { A, B }\n");
    defer fx.deinit();

    const e = findTopDecl(&fx.res.tree.root.list, "enum_declaration").?;
    try testing.expect(containerListOf(e) == null);
}

// ── overload disambiguation (task Q3 tiebreak) ─────────────────────────────

test "overload: two function_signature `foo` both surface as Decls" {
    // The occurrence-index tiebreak is tested in diff/align.zig; here we
    // verify that both overload signatures parse as separate Decl-kind
    // Lists with the same name, which is the precondition for that
    // tiebreak to fire.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fx = try convertTs(arena.allocator(),
        \\function foo(x: number): void;
        \\function foo(x: string): void;
        \\function foo(x: any): void {}
        \\
    );
    defer fx.deinit();

    const root = &fx.res.tree.root.list;
    var sig_count: usize = 0;
    var decl_count: usize = 0;
    for (root.children) |*child| switch (child.*) {
        .list => |l| {
            if (std.mem.eql(u8, l.ts_kind, "function_signature")) {
                sig_count += 1;
                try testing.expectEqualStrings("foo", extractName(&child.list, fx.res.tree.source).?);
            } else if (std.mem.eql(u8, l.ts_kind, "function_declaration")) {
                decl_count += 1;
                try testing.expectEqualStrings("foo", extractName(&child.list, fx.res.tree.source).?);
            }
        },
        .atom => {},
    };
    try testing.expectEqual(@as(usize, 2), sig_count);
    try testing.expectEqual(@as(usize, 1), decl_count);
}

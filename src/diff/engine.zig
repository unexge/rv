//! Engine entry point - the public face of rv.
//!
//! Orchestrates: parse both sides with tree-sitter → convert to SST → hash
//! → align top-level container → return `FileDiff`.

const std = @import("std");
const treez = @import("treez");

const registry = @import("../lang/registry.zig");
const convert = @import("../sst/convert.zig");
const hash_mod = @import("../sst/hash.zig");
const align_mod = @import("align.zig");
const result = @import("../diff/result.zig");
const node = @import("../sst/node.zig");
const edit = @import("edit.zig");

pub const EngineError = error{
    OutOfMemory,
    /// Tree-sitter grammar for the requested language could not be loaded,
    /// or parsing failed for other non-data reasons (version mismatch, etc).
    /// Parse errors in the input itself are NOT signalled this way - they
    /// appear as entries in `FileDiff.parse_errors`.
    GrammarLoadFailed,
};

/// Diff two source buffers in the given language.
///
/// Caller keeps ownership of `left_source` and `right_source`; the returned
/// `FileDiff` borrows them. The caller must keep both buffers alive until
/// `FileDiff.deinit()` is called.
///
/// Parse errors (malformed input) do NOT cause this function to return an
/// error - they are surfaced as entries in `FileDiff.parse_errors`, per Q6.
pub fn diffSources(
    gpa: std.mem.Allocator,
    language: registry.LanguageId,
    left_source: []const u8,
    right_source: []const u8,
) EngineError!result.FileDiff {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = registry.config(language);
    const ts_lang = try loadGrammar(language);

    const parser = treez.Parser.create() catch return error.GrammarLoadFailed;
    defer parser.destroy();
    parser.setLanguage(ts_lang) catch return error.GrammarLoadFailed;

    // ── Parse both sides. Each parse is scoped to its own `ts_tree`
    //    destroyed here; conversion copies the bytes we need into `arena`.
    const left_ts_tree = parser.parseString(null, left_source) catch
        return error.GrammarLoadFailed;
    defer left_ts_tree.destroy();

    const right_ts_tree = parser.parseString(null, right_source) catch
        return error.GrammarLoadFailed;
    defer right_ts_tree.destroy();

    const left_conv = try convert.fromTreeSitter(arena, left_ts_tree, left_source, cfg);
    const right_conv = try convert.fromTreeSitter(arena, right_ts_tree, right_source, cfg);

    // Assign sides: the converter writes a placeholder and documents that
    // the caller fills this in (see ConvertResult.parse_errors doc).
    for (left_conv.parse_errors) |*pe| pe.side = .left;
    for (right_conv.parse_errors) |*pe| pe.side = .right;

    hash_mod.hashTree(left_conv.tree);
    hash_mod.hashTree(right_conv.tree);

    // Merge parse errors (left first, then right - no ordering guarantee
    // beyond stability for golden diffs).
    const total_errs = left_conv.parse_errors.len + right_conv.parse_errors.len;
    const parse_errors = try arena.alloc(result.ParseError, total_errs);
    @memcpy(parse_errors[0..left_conv.parse_errors.len], left_conv.parse_errors);
    @memcpy(parse_errors[left_conv.parse_errors.len..], right_conv.parse_errors);

    // Roots must be Lists for alignment to walk children. A non-list root
    // only happens for catastrophically malformed input, where tree-sitter
    // promotes an ERROR node to the root position. The ERROR region is
    // already captured in `parse_errors`; fall back to an empty synthetic
    // container so the other side's Decls still surface as Added/Removed.
    const left_root = try rootAsList(arena, left_conv.tree);
    const right_root = try rootAsList(arena, right_conv.tree);

    const entries = try align_mod.alignDecls(
        arena,
        cfg,
        left_root,
        right_root,
        left_source,
        right_source,
    );

    return .{
        .language = language,
        .entries = entries,
        .parse_errors = parse_errors,
        .left_source = left_source,
        .right_source = right_source,
        .left_sst = left_conv.tree,
        .right_sst = right_conv.tree,
        .arena = arena_state,
    };
}

/// Resolve the grammar for a LanguageId. `treez.Language.get` takes a
/// comptime name, so we dispatch through a switch.
fn loadGrammar(id: registry.LanguageId) EngineError!*const treez.Language {
    return switch (id) {
        .zig => treez.Language.get("zig") catch error.GrammarLoadFailed,
        .rust => treez.Language.get("rust") catch error.GrammarLoadFailed,
        .go => treez.Language.get("go") catch error.GrammarLoadFailed,
        .python => treez.Language.get("python") catch error.GrammarLoadFailed,
        .typescript => treez.Language.get("typescript") catch error.GrammarLoadFailed,
    };
}

/// Return the tree's root as a pointer to a List. If the root is an atom
/// (the whole file is one big ERROR region), synthesise an empty container
/// so alignment treats that side as having no Decls.
fn rootAsList(arena: std.mem.Allocator, tree: *const node.Tree) !*const node.List {
    switch (tree.root) {
        .list => return &tree.root.list,
        .atom => {
            const empty = try arena.create(node.List);
            empty.* = .{
                .ts_kind = "",
                .open_delim = "",
                .close_delim = "",
                .children = &.{},
                .leading_trivia = &.{},
                .trailing_trivia = &.{},
                .byte_range = .{ .start = 0, .end = 0 },
                .hash = 0,
            };
            return empty;
        },
    }
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "diffSources: identical empty sources produce zero entries, zero errors, no leaks" {
    var fd = try diffSources(testing.allocator, .zig, "", "");
    defer fd.deinit();
    try testing.expectEqual(@as(usize, 0), fd.entries.len);
    try testing.expectEqual(@as(usize, 0), fd.parse_errors.len);
    try testing.expectEqual(@as(usize, 0), fd.left_source.len);
    try testing.expectEqual(@as(usize, 0), fd.right_source.len);
}

test "diffSources: identical non-trivial sources → all Unchanged, no moves" {
    const src =
        \\const std = @import("std");
        \\pub fn foo() void {}
        \\pub const answer: u32 = 42;
    ;
    var fd = try diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();

    try testing.expectEqual(@as(usize, 0), fd.parse_errors.len);
    try testing.expect(fd.entries.len >= 2);
    for (fd.entries) |e| {
        try testing.expect(e == .unchanged);
        try testing.expect(e.unchanged.moved == null);
    }
}

test "diffSources: borrows source buffers (pointer identity preserved)" {
    const src = "pub fn foo() void {}";
    var fd = try diffSources(testing.allocator, .zig, src, src);
    defer fd.deinit();
    try testing.expectEqual(@intFromPtr(src.ptr), @intFromPtr(fd.left_source.ptr));
    try testing.expectEqual(@intFromPtr(src.ptr), @intFromPtr(fd.right_source.ptr));
}

test "diffSources: parse error on left only is reported with side=.left" {
    const bad = "fn foo("; // unterminated
    const good = "fn foo() void {}";
    var fd = try diffSources(testing.allocator, .zig, bad, good);
    defer fd.deinit();

    try testing.expect(fd.parse_errors.len >= 1);
    for (fd.parse_errors) |pe| {
        try testing.expectEqual(edit.Side.left, pe.side);
    }
}

test "diffSources: parse errors from both sides keep their side labels" {
    const bad_left = "fn foo(";
    const bad_right = "fn foo(\nfn bar(";
    var fd = try diffSources(testing.allocator, .zig, bad_left, bad_right);
    defer fd.deinit();

    // At least one error per side.
    var saw_left = false;
    var saw_right = false;
    for (fd.parse_errors) |pe| {
        if (pe.side == .left) saw_left = true;
        if (pe.side == .right) saw_right = true;
    }
    try testing.expect(saw_left);
    try testing.expect(saw_right);
}

test "diffSources: rename function → Removed + Added" {
    const before = "pub fn foo() void {}\n";
    const after = "pub fn foo2() void {}\n";
    var fd = try diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    var added: usize = 0;
    var removed: usize = 0;
    for (fd.entries) |e| switch (e) {
        .added => added += 1,
        .removed => removed += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), added);
    try testing.expectEqual(@as(usize, 1), removed);
}

test "diffSources: body edit surfaces as Changed + body.leaf" {
    const before =
        \\pub fn foo() u32 { return 1; }
    ;
    const after =
        \\pub fn foo() u32 { return 2; }
    ;
    var fd = try diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    try testing.expectEqual(@as(usize, 1), fd.entries.len);
    try testing.expect(fd.entries[0] == .changed);
    try testing.expect(fd.entries[0].changed.body == .leaf);
}

test "diffSources: FileDiff.deinit frees everything (no leaks)" {
    // `testing.allocator` is a GeneralPurposeAllocator that tracks leaks and
    // fails the test if any bytes remain allocated when the test exits.
    const src_before =
        \\pub fn a() void {}
        \\pub fn b() void {}
    ;
    const src_after =
        \\pub fn a() void { const x = 1; _ = x; }
        \\pub fn c() void {}
    ;
    var fd = try diffSources(testing.allocator, .zig, src_before, src_after);
    fd.deinit();
}

test "diffSources: struct-as-namespace body change → Changed with body.container" {
    const before =
        \\pub const Thing = struct {
        \\    pub fn one() void {}
        \\};
    ;
    const after =
        \\pub const Thing = struct {
        \\    pub fn one() void {}
        \\    pub fn two() void {}
        \\};
    ;
    var fd = try diffSources(testing.allocator, .zig, before, after);
    defer fd.deinit();

    try testing.expectEqual(@as(usize, 1), fd.entries.len);
    try testing.expect(fd.entries[0] == .changed);
    try testing.expect(fd.entries[0].changed.body == .container);
}

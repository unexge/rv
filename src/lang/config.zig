//! Per-language configuration.
//!
//! One `LangConfig` instance per language lives in `lang/<name>.zig`. The
//! registry (`lang/registry.zig`) dispatches `LanguageId` → `*const LangConfig`.
//!
//! The config captures everything the language-agnostic engine needs to know
//! to process a given grammar.

const std = @import("std");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const LangConfig = struct {
    /// Grammar name as registered with treez (`treez.Language.get(name)`).
    grammar_name: []const u8,

    // ── SST conversion ──────────────────────────────────────────────────

    /// Tree-sitter node types that should be flattened into a single `Atom`
    /// even when the grammar gives them children (e.g. string literals whose
    /// grammar splits them into open/body/close).
    atom_ts_kinds: []const []const u8,

    /// Tree-sitter token strings consumed as the open/close delimiter of
    /// their enclosing List. Anything matching one of these at the beginning
    /// or end of a List's raw children is attached to `open_delim` /
    /// `close_delim` rather than emitted as an Atom child.
    delimiter_ts_kinds: []const []const u8,

    /// Tree-sitter node types that should be classified as `AtomKind.comment`.
    comment_ts_kinds: []const []const u8,

    // ── Decl recognition ────────────────────────────────────────────────

    /// Tree-sitter node types that are Decls. Decls participate in container
    /// alignment; non-Decl Lists appear in leaf edit scripts as ordinary
    /// structure.
    decl_ts_kinds: []const []const u8,

    /// Subset of `decl_ts_kinds` that are *containers* - their children are
    /// themselves Decls and they recurse into `DeclBody.container` on change.
    /// Every ts_kind appearing here must also appear in `decl_ts_kinds`.
    container_ts_kinds: []const []const u8,

    /// Map a TS node type to a cross-language `DeclKind`. Callers rely on
    /// this for broad pattern matching; `ts_kind` remains available for
    /// language-specific logic.
    classify: *const fn (ts_kind: []const u8) result.DeclKind,

    /// Extract the human-readable name of a Decl as a slice into `source`.
    /// Returns null for anonymous Decls (bare statements, comptime blocks).
    /// Used to build identity keys for alignment.
    extract_name: *const fn (list: *const node.List, source: []const u8) ?[]const u8,

    /// Optional: dynamic container detection for Decls whose ts_kind alone
    /// doesn't decide container-ness. Needed for Zig, where
    /// `const X = struct { ... };` is a container but its outer ts_kind is
    /// `variable_declaration` - identical to any non-container binding.
    ///
    /// When set and returns non-null, the returned List is the one whose
    /// children are the inner Decls (for a Zig var whose RHS is a
    /// struct/union/enum/opaque_declaration, that's the RHS list). Returns
    /// null for Decls that aren't containers.
    ///
    /// Takes precedence over `container_ts_kinds` when non-null. Defaults
    /// to null, in which case container detection falls back to
    /// `container_ts_kinds`.
    container_list_of: ?*const fn (list: *const node.List) ?*const node.List = null,

    // ── Import-group alignment ──────────────────────────────────────────

    /// Optional: identify the path prefix of an import-group decl so two
    /// declarations sharing the same prefix can be paired and rendered as a
    /// per-symbol diff (see `result.ImportGroupDiff`).
    ///
    /// Returning null means "this decl falls back to regular `extract_name`
    /// and never participates in import-group alignment". Common opt-out
    /// reasons: single-segment paths, wildcards, visibility modifiers.
    ///
    /// Returned slice borrows from `source`.
    ///
    /// Must be set together with `import_symbols`, or both must be null.
    import_group_key: ?*const fn (
        list: *const node.List,
        source: []const u8,
    ) ?[]const u8 = null,

    /// Optional: parse the leaf symbols of an import-group decl in source
    /// order (see `result.ImportSymbol`).
    ///
    /// Allocates the outer slice (and any synthesized symbol text) from
    /// `arena`. Inner slices borrow from `source` whenever possible.
    ///
    /// Must be set together with `import_group_key`, or both must be null.
    import_symbols: ?*const fn (
        arena: std.mem.Allocator,
        list: *const node.List,
        source: []const u8,
    ) std.mem.Allocator.Error![]const result.ImportSymbol = null,
};

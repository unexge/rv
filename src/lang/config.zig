//! Per-language configuration.
//!
//! One `LangConfig` instance per language lives in `lang/<name>.zig`. The
//! registry (`lang/registry.zig`) dispatches `LanguageId` → `*const LangConfig`.
//!
//! The config captures everything the language-agnostic engine needs to know
//! to process a given grammar.

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
};

//! Public result types.
//!
//! The engine's structured output. Recursive: containers (class, impl, mod,
//! namespace, trait, interface, Zig-struct-as-namespace) hold `[]DeclDiff`
//! children; leaves (function, const, type alias, import, etc.) hold a flat
//! `EditScript`.

const std = @import("std");
const node = @import("../sst/node.zig");
const edit = @import("edit.zig");
const registry = @import("../lang/registry.zig");

/// Cross-language Decl category. See Q9.
///
/// Fine-grained distinctions (class vs impl vs trait, struct vs enum) remain
/// available via `Decl.ts_kind`.
pub const DeclKind = enum {
    /// FnProto, function_item/declaration/definition, method_declaration.
    function,
    /// class, impl, trait, interface, mod, namespace, struct-as-namespace.
    /// Every container's Changed body is `DeclBody.container`.
    container,
    /// const, static, let, var, Zig container_field.
    binding,
    /// type X = Y aliases.
    type_alias,
    /// use, import, require, include statements.
    import,
    /// Zig `test "..." { ... }`.
    test_case,
    /// Language-specific forms (Python module-level expression statements,
    /// Zig comptime blocks, JS top-level expression statements, etc.).
    other,
};

/// A Decl is a typed view over an `sst.List` node that represents a
/// diffable unit (function, class, const, etc.). The list pointer resolves
/// against the `Tree` it came from (see `FileDiff.left_sst`/`right_sst`).
pub const Decl = struct {
    kind: DeclKind,
    /// Raw tree-sitter node type for fine-grained distinctions.
    ts_kind: []const u8,
    /// Human-readable name slice (into source). `null` for anonymous Decls
    /// (Python module-level bare statements, Zig comptime blocks, etc.).
    name: ?[]const u8,
    /// The underlying SST list for this Decl. Byte ranges and children come
    /// from here.
    list: *const node.List,
};

/// Move metadata. Populated when a Decl's index in its parent container
/// changed between left and right. `null` means same position.
pub const MoveInfo = struct {
    from_idx: usize,
    to_idx: usize,
};

/// A single symbol entry within an import group's leaf list.
///
/// `text` is a slice (typically borrowed from the source buffer) representing
/// one symbol as it would appear inside the brace list of a `use` declaration.
/// Whitespace and surrounding commas are trimmed.
///
/// Examples: `"Bar"`, `"Bar as Baz"`, `"self"`, `"*"`.
pub const ImportSymbol = struct {
    /// Raw source slice, trimmed of surrounding whitespace/commas.
    text: []const u8,
};

/// Per-symbol diff status for an `ImportGroupDiff`.
pub const ImportSymbolEntry = union(enum) {
    kept: ImportSymbol,
    added: ImportSymbol,
    removed: ImportSymbol,
};

/// Body for a paired import-group `Changed` entry.
///
/// Produced when two import declarations share the same path prefix (see
/// `LangConfig.import_group_key`) so the diff can describe the change as a
/// per-symbol delta inside that prefix instead of a full Added/Removed pair.
pub const ImportGroupDiff = struct {
    /// Shared path prefix that keyed the alignment, e.g. `"rumqttc"` or
    /// `"std::sync"`. Borrowed from one of the source buffers.
    prefix: []const u8,
    /// Right-side display order with removed entries spliced in next to
    /// their left-side anchor.
    entries: []const ImportSymbolEntry,
};

/// Body of a `Changed` entry.
///
/// `leaf` for leaf Decls (function bodies, const expressions, etc.) - a flat
/// edit script over the interior nodes.
///
/// `container` for container Decls - recursive alignment of their members.
///
/// `import_group` for paired import declarations whose path prefixes match -
/// the body lists per-symbol kept/added/removed entries.
pub const DeclBody = union(enum) {
    leaf: edit.EditScript,
    container: []const DeclDiff,
    import_group: ImportGroupDiff,
};

pub const DeclDiff = union(enum) {
    /// Present and hash-equal on both sides. May have moved in its parent's
    /// child list.
    unchanged: struct {
        decl: Decl,
        moved: ?MoveInfo,
    },
    /// Present on the right side only. Always inside the right SST.
    added: struct {
        decl: Decl,
    },
    /// Present on the left side only. Always inside the left SST.
    removed: struct {
        decl: Decl,
    },
    /// Same identity key on both sides but hash differs. `body` describes the
    /// internal change.
    changed: struct {
        old: Decl,
        new: Decl,
        body: DeclBody,
        moved: ?MoveInfo,
    },
};

pub const ParseError = struct {
    side: edit.Side,
    byte_range: node.ByteRange,
    kind: enum {
        /// Tree-sitter ERROR node.
        error_node,
        /// Tree-sitter MISSING node (inferred missing token).
        missing_token,
    },
};

/// Top-level public output. Owns two SSTs plus the diff itself. `deinit`
/// frees everything via its arena; source slices were borrowed from the
/// caller and are not freed.
pub const FileDiff = struct {
    language: registry.LanguageId,
    /// Top-level Decl diffs, in right-side order with Removed entries spliced
    /// in adjacent to their left-side anchors. See Q7 (revised).
    entries: []const DeclDiff,
    parse_errors: []const ParseError,
    /// Borrowed from caller. Not freed on deinit.
    left_source: []const u8,
    /// Borrowed from caller. Not freed on deinit.
    right_source: []const u8,
    /// Owned. Arena-allocated.
    left_sst: *const node.Tree,
    /// Owned. Arena-allocated.
    right_sst: *const node.Tree,
    /// Owns entries, SST nodes, parse_errors, edit scripts.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *FileDiff) void {
        self.arena.deinit();
    }
};

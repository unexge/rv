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

/// Body of a `Changed` entry.
///
/// `leaf` for leaf Decls (function bodies, const expressions, etc.) - a flat
/// edit script over the interior nodes.
///
/// `container` for container Decls - recursive alignment of their members.
pub const DeclBody = union(enum) {
    leaf: edit.EditScript,
    container: []const DeclDiff,
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

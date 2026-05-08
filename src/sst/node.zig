//! Simplified Syntax Tree (SST).
//!
//! The SST is the language-agnostic representation the diff engine operates
//! on. It is derived from a tree-sitter parse tree by `sst/convert.zig`.
//!
//! Every node is either an `Atom` (a leaf - identifier, literal, comment,
//! punctuation treated as opaque) or a `List` (an interior node with an
//! ordered sequence of children plus optional open/close delimiter strings).
//!
//! Whitespace between nodes is dropped during conversion. Byte positions are
//! preserved for rendering but are NOT used during diffing.

const std = @import("std");

pub const ByteRange = struct {
    start: u32,
    end: u32,
};

/// Kind of an atom. Drives rendering (comments render weakly by default) and
/// lets callers filter (e.g. --ignore-comments).
pub const AtomKind = enum {
    /// Ordinary source code: identifiers, literals, keywords, operators.
    code,
    /// Line or block comments (doc comments included).
    comment,
    /// Regions tree-sitter marked as ERROR or MISSING. Raw bytes preserved.
    @"error",
};

pub const Atom = struct {
    kind: AtomKind,
    /// Raw source slice. Points into the original source buffer; not owned.
    bytes: []const u8,
    byte_range: ByteRange,
    /// Content hash. Filled by `sst/hash.zig` after the tree is built. Until
    /// then, 0. Consumers must not read this before `hashTree` has run.
    hash: u64,
};

pub const List = struct {
    /// Raw tree-sitter node type, e.g. "function_item", "block", "arguments".
    ts_kind: []const u8,
    /// Opening delimiter if any (e.g. "(", "{", "["). Empty string otherwise.
    open_delim: []const u8,
    /// Closing delimiter if any. Empty string otherwise.
    close_delim: []const u8,
    /// Children in source order. Excludes trivia attached to this list - see
    /// leading_trivia / trailing_trivia.
    children: []const Node,
    /// Comments preceding this list within its parent (doc-comment style).
    /// Participates in the identity+content hash of this list.
    leading_trivia: []const Atom,
    /// Comments trailing this list within its parent. Only populated on the
    /// last child of a container when comments follow it before the
    /// container's close delimiter.
    trailing_trivia: []const Atom,
    byte_range: ByteRange,
    /// Content hash including ts_kind, delimiters, children, and trivia.
    /// Filled by `hashTree`.
    hash: u64,
};

pub const Node = union(enum) {
    atom: Atom,
    list: List,

    pub fn byteRange(self: Node) ByteRange {
        return switch (self) {
            .atom => |a| a.byte_range,
            .list => |l| l.byte_range,
        };
    }

    pub fn hash(self: Node) u64 {
        return switch (self) {
            .atom => |a| a.hash,
            .list => |l| l.hash,
        };
    }
};

/// Owning container for an SST. All nodes reachable from `root` live in the
/// arena accessible via the allocator that built this tree. Freed when the
/// owning `FileDiff` (or test) deinits its arena.
pub const Tree = struct {
    root: Node,
    /// Borrowed slice of the source this tree was parsed from.
    source: []const u8,
};

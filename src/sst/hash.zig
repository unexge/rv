//! SST content hashing.
//!
//! Pure-structural hash per Q8 - no language-aware normalisation.
//!
//! Hash of an Atom combines its `AtomKind` discriminant and its raw bytes.
//! Hash of a List combines its `ts_kind`, delimiters, children hashes, and
//! leading/trailing trivia hashes (so a doc-comment edit changes the enclosing
//! Decl's hash).

const std = @import("std");
const node = @import("node.zig");

/// Fill the `hash` field on every node in `tree` in post-order. Must be called
/// before the diff engine reads any hashes. Deterministic.
pub fn hashTree(tree: *node.Tree) void {
    _ = tree;
    @panic("TODO: post-order walk filling Atom.hash and List.hash");
}

/// Compute a hash without mutating. Used internally; exposed for property
/// tests ("hash(A) == hash(B) iff A structurally equals B").
pub fn hashNode(n: node.Node) u64 {
    _ = n;
    @panic("TODO: structural hash combining ts_kind / kind + contents");
}

//! Dijkstra-based leaf-body diffing.
//!
//! Implements the graph-search described in difftastic/autochrome: vertices
//! are pairs of cursors over two SST subtrees plus per-cursor stacks of
//! pending parent return positions; edges are match-advance, novel-L,
//! novel-R, descend-both, descend-L, descend-R, pop-L, pop-R; costs bias
//! toward matches and toward matched-movement over single-cursor movement.
//!
//! Used only for leaf Decls' body_diff. Container Decls recurse via
//! `align.zig` instead.

const std = @import("std");
const node = @import("../sst/node.zig");
const edit = @import("edit.zig");

pub const DiffError = error{
    OutOfMemory,
    NotImplemented,
};

/// Produce the lowest-cost `EditScript` transforming `left` into `right`.
///
/// Relies on `hash` having been filled on all nodes (see `sst/hash.zig`)-
/// equal hashes short-circuit to `match` edges at zero cost.
///
/// The returned script is arena-allocated via `arena`.
pub fn diffNodes(
    arena: std.mem.Allocator,
    left: *const node.Node,
    right: *const node.Node,
) DiffError!edit.EditScript {
    _ = arena;
    _ = left;
    _ = right;
    return error.NotImplemented;
}

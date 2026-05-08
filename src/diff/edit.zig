//! Edit script - the flat diff of a leaf Decl's body.
//!
//! Produced by Dijkstra's algorithm over the SST (see `diff/dijkstra.zig`).
//! Inside a `DeclDiff.changed` where the Decl is a *leaf*, the body is one of
//! these. For *container* Decls the body is a `[]DeclDiff` instead (recursion).

const std = @import("std");
const node = @import("../sst/node.zig");

pub const Side = enum { left, right };

pub const Edit = union(enum) {
    /// Two subtrees that the aligner paired. No output bytes change.
    match: struct {
        left: *const node.Node,
        right: *const node.Node,
    },
    /// A subtree present on one side but not the other.
    novel: struct {
        side: Side,
        node_ref: *const node.Node,
    },
};

pub const EditScript = struct {
    edits: []const Edit,
    /// Dijkstra path cost. Lower is better. Exposed for callers that want to
    /// rank diffs (e.g. future rename detection picking the lowest-cost
    /// pairing).
    total_cost: u64,

    /// True iff every `novel` edit in this script is on an atom whose kind is
    /// `.comment`, and there is at least one such edit. Lets the renderer
    /// classify a `Changed` Decl as cosmetic.
    pub fn isCommentOnly(self: EditScript) bool {
        _ = self;
        @panic("TODO: scan edits for all-comment novel atoms");
    }
};

//! Container alignment.
//!
//! Pairs Decls between two containers by the hybrid identity rule from Q3:
//!
//!   1. Hash-equal Decls → `DeclDiff.unchanged` (fast path).
//!   2. Among the rest, equal (kind, name, nth_occurrence) identity keys →
//!      `DeclDiff.changed` (run the leaf body-diff or recurse).
//!   3. Remaining leftovers → `DeclDiff.added` / `DeclDiff.removed`.
//!
//! Matching is set-based (Q7 revised): relative order is irrelevant for
//! pairing. When a matched pair's index differs between sides, `moved` is
//! populated.
//!
//! Output order: right-side order for matched and added entries, with
//! removed entries spliced in just before the right-side anchor of their
//! left-side neighbour.

const std = @import("std");
const node = @import("../sst/node.zig");
const config_mod = @import("../lang/config.zig");
const result = @import("../diff/result.zig");

pub const AlignError = error{
    OutOfMemory,
    NotImplemented,
};

/// Align the children of two container Lists.
///
/// `left_container` and `right_container` must both be List nodes whose
/// `ts_kind` appears in `cfg.container_ts_kinds`.
///
/// Recurses into child containers; calls into `dijkstra.zig` for leaf Decls
/// whose hash differs. Allocates everything in `arena`.
pub fn alignDecls(
    arena: std.mem.Allocator,
    cfg: *const config_mod.LangConfig,
    left_container: *const node.List,
    right_container: *const node.List,
    left_source: []const u8,
    right_source: []const u8,
) AlignError![]result.DeclDiff {
    _ = arena;
    _ = cfg;
    _ = left_container;
    _ = right_container;
    _ = left_source;
    _ = right_source;
    return error.NotImplemented;
}

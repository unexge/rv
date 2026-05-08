//! Tree-sitter → SST conversion.
//!
//! Walks a tree-sitter parse tree and produces an `sst.Tree` according to a
//! `LangConfig`. Responsibilities:
//!
//! 1. Flatten TS nodes listed in `atom_ts_kinds` into single Atoms even if
//!    they have children (e.g. string literals whose grammar splits them).
//! 2. Consume TS tokens listed in `delimiter_ts_kinds` as the open/close
//!    delimiters of their enclosing List rather than emitting them as child
//!    atoms.
//! 3. Classify Atoms via `comment_ts_kinds` → `AtomKind.comment`, ERROR /
//!    MISSING TS nodes → `AtomKind.@"error"`, everything else → `.code`.
//! 4. Attach comments adjacent to a List as `leading_trivia` / `trailing_trivia`
//!    on that List, so they participate in the List's hash (see Q5).
//! 5. Drop whitespace entirely.

const std = @import("std");
const treez = @import("treez");

const node = @import("node.zig");
const config_mod = @import("../lang/config.zig");
const result = @import("../diff/result.zig");

pub const ConvertError = error{
    OutOfMemory,
    /// Returned if the tree-sitter grammar named by the config could not be
    /// loaded (missing, name mismatch, etc.). Distinct from parse errors,
    /// which are data (see `ParseError`), not control flow.
    GrammarLoadFailed,
    NotImplemented,
};

pub const ConvertResult = struct {
    /// Newly allocated tree. Lives in `arena`.
    tree: *node.Tree,
    /// ERROR / MISSING regions encountered during conversion. `side` is left
    /// unset by the converter; the engine fills it in.
    parse_errors: []result.ParseError,
};

/// Convert a tree-sitter tree into an SST.
///
/// All SST allocations go through `arena`. The returned tree borrows `source`
/// for its atoms; caller must keep `source` alive as long as the tree is used.
pub fn fromTreeSitter(
    arena: std.mem.Allocator,
    ts_tree: treez.Tree,
    source: []const u8,
    cfg: *const config_mod.LangConfig,
) ConvertError!ConvertResult {
    _ = arena;
    _ = ts_tree;
    _ = source;
    _ = cfg;
    return error.NotImplemented;
}

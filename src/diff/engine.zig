//! Engine entry point - the public face of rv.
//!
//! Orchestrates: parse both sides with tree-sitter → convert to SST → hash
//! → align top-level container → return `FileDiff`.

const std = @import("std");
const treez = @import("treez");

const registry = @import("../lang/registry.zig");
const result = @import("../diff/result.zig");

pub const EngineError = error{
    OutOfMemory,
    /// Tree-sitter grammar for the requested language could not be loaded.
    GrammarLoadFailed,
    NotImplemented,
};

/// Diff two source buffers in the given language.
///
/// Caller keeps ownership of `left_source` and `right_source`; the returned
/// `FileDiff` borrows them. The caller must keep both buffers alive until
/// `FileDiff.deinit()` is called.
///
/// Parse errors (malformed input) do NOT cause this function to return an
/// error - they are surfaced as entries in `FileDiff.parse_errors`, per Q6.
pub fn diffSources(
    gpa: std.mem.Allocator,
    language: registry.LanguageId,
    left_source: []const u8,
    right_source: []const u8,
) EngineError!result.FileDiff {
    _ = gpa;
    _ = language;
    _ = left_source;
    _ = right_source;
    return error.NotImplemented;
}

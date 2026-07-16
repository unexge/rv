//! rv - semantic diff engine for Zig, Rust, Go, Python, and TypeScript.
//!
//! Tree-sitter based. See `diff/engine.zig` for the public entry point.

const std = @import("std");

// ── Public API ─────────────────────────────────────────────────────────────

pub const LanguageId = @import("lang/registry.zig").LanguageId;
pub const languageFromPath = @import("lang/registry.zig").languageFromPath;

pub const AtomKind = @import("sst/node.zig").AtomKind;
pub const List = @import("sst/node.zig").List;
pub const Node = @import("sst/node.zig").Node;

pub const DeclKind = @import("diff/result.zig").DeclKind;
pub const Decl = @import("diff/result.zig").Decl;
pub const MoveInfo = @import("diff/result.zig").MoveInfo;
pub const DeclBody = @import("diff/result.zig").DeclBody;
pub const DeclDiff = @import("diff/result.zig").DeclDiff;
pub const ImportSymbol = @import("diff/result.zig").ImportSymbol;
pub const ImportSymbolEntry = @import("diff/result.zig").ImportSymbolEntry;
pub const ImportGroupDiff = @import("diff/result.zig").ImportGroupDiff;
pub const ParseError = @import("diff/result.zig").ParseError;
pub const FileDiff = @import("diff/result.zig").FileDiff;

pub const Side = @import("diff/edit.zig").Side;
pub const Edit = @import("diff/edit.zig").Edit;
pub const EditScript = @import("diff/edit.zig").EditScript;

pub const diffSources = @import("diff/engine.zig").diffSources;
pub const EngineError = @import("diff/engine.zig").EngineError;
pub const max_source_bytes = @import("diff/engine.zig").max_source_bytes;

// Ensure submodule tests are picked up by `zig build test`.
comptime {
    _ = @import("lang/config.zig");
    _ = @import("lang/registry.zig");
    _ = @import("lang/zig.zig");
    _ = @import("lang/rust.zig");
    _ = @import("lang/go.zig");
    _ = @import("lang/python.zig");
    _ = @import("lang/typescript.zig");
    _ = @import("sst/node.zig");
    _ = @import("sst/convert.zig");
    _ = @import("sst/hash.zig");
    _ = @import("diff/edit.zig");
    _ = @import("diff/result.zig");
    _ = @import("diff/align.zig");
    _ = @import("diff/dijkstra.zig");
    _ = @import("diff/engine.zig");
    _ = @import("testing.zig");
    _ = @import("golden_test.zig");
}

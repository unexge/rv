//! Zig language configuration.
//!
//! Concrete TS kind tables (atoms, delimiters, comments, decls, containers)
//! and the classify/extract_name functions are filled in by the first Zig
//! implementation task.

const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "zig",
    .atom_ts_kinds = &.{}, // TODO
    .delimiter_ts_kinds = &.{}, // TODO
    .comment_ts_kinds = &.{}, // TODO: line_comment, doc_comment
    .decl_ts_kinds = &.{}, // TODO: FnProto, VarDecl, TestDecl, ContainerField, ComptimeDecl
    .container_ts_kinds = &.{}, // TODO: struct/union/enum/opaque container values
    .classify = classify,
    .extract_name = extractName,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    _ = ts_kind;
    @panic("TODO: classify Zig ts_kinds into DeclKind");
}

fn extractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = list;
    _ = source;
    @panic("TODO: extract Zig decl name (FnProto.IDENTIFIER, VarDecl identifier, test name literal)");
}

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
    // Flatten these TS node types into a single Atom even when the grammar
    // splits them into sub-tokens (e.g. string → [", content, "]). Keeps
    // leaf literals comparable as single bytes.
    .atom_ts_kinds = &.{
        "string",
        "multiline_string",
        "character",
        "integer",
        "float",
        "identifier",
        "builtin_identifier",
        "builtin_type",
        "escape_sequence",
    },
    // Anonymous punctuation tokens that delimit a List. The TS node type for
    // an anonymous token equals its literal text, so matching on these
    // strings is sound.
    .delimiter_ts_kinds = &.{
        "(", ")",
        "{", "}",
        "[", "]",
    },
    .comment_ts_kinds = &.{"comment"},
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

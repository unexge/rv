//! Go language configuration.

const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "go",
    .atom_ts_kinds = &.{}, // TODO: interpreted_string_literal, raw_string_literal, rune_literal
    .delimiter_ts_kinds = &.{}, // TODO
    .comment_ts_kinds = &.{}, // TODO: comment
    .decl_ts_kinds = &.{}, // TODO: function_declaration, method_declaration, type_declaration, var_declaration, const_declaration, import_declaration
    .container_ts_kinds = &.{}, // TODO: source_file only (Go has no nested top-level containers in v1)
    .classify = classify,
    .extract_name = extractName,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    _ = ts_kind;
    @panic("TODO: classify Go ts_kinds into DeclKind");
}

fn extractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = list;
    _ = source;
    @panic("TODO: extract Go decl name (method: receiver_type.name; function: name; type: type_spec.name)");
}

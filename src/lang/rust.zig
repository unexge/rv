//! Rust language configuration.

const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "rust",
    .atom_ts_kinds = &.{}, // TODO: string_literal, raw_string_literal, char_literal
    .delimiter_ts_kinds = &.{}, // TODO
    .comment_ts_kinds = &.{}, // TODO: line_comment, block_comment
    .decl_ts_kinds = &.{}, // TODO: function_item, struct_item, enum_item, impl_item, trait_item, mod_item, use_declaration, const_item, static_item, type_item, macro_*
    .container_ts_kinds = &.{}, // TODO: mod_item, impl_item, trait_item, source_file
    .classify = classify,
    .extract_name = extractName,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    _ = ts_kind;
    @panic("TODO: classify Rust ts_kinds into DeclKind");
}

fn extractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = list;
    _ = source;
    @panic("TODO: extract Rust decl name (function_item.name, impl_item.type+trait, etc.)");
}

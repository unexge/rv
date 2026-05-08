//! TypeScript language configuration.
//!
//! v1 uses the `"typescript"` grammar. TSX support would be a second
//! `LangConfig` (likely a new `LanguageId.tsx` variant) and is out of scope
//! for v1.

const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "typescript",
    .atom_ts_kinds = &.{}, // TODO: string, template_string, regex
    .delimiter_ts_kinds = &.{}, // TODO
    .comment_ts_kinds = &.{}, // TODO: comment
    .decl_ts_kinds = &.{}, // TODO: function_declaration, class_declaration, interface_declaration, type_alias_declaration, enum_declaration, variable_declaration, import_statement, export_statement
    .container_ts_kinds = &.{}, // TODO: program, class_declaration, interface_declaration, namespace, module, enum_declaration
    .classify = classify,
    .extract_name = extractName,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    _ = ts_kind;
    @panic("TODO: classify TypeScript ts_kinds into DeclKind");
}

fn extractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = list;
    _ = source;
    @panic("TODO: extract TS decl name; handle variable_declaration binding patterns");
}

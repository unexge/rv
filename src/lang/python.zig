//! Python language configuration.

const config_mod = @import("config.zig");
const node = @import("../sst/node.zig");
const result = @import("../diff/result.zig");

pub const config: config_mod.LangConfig = .{
    .grammar_name = "python",
    .atom_ts_kinds = &.{}, // TODO: string, concatenated_string, integer, float
    .delimiter_ts_kinds = &.{}, // TODO: (, ), [, ], {, }  - note: block uses INDENT/DEDENT, not delimiters
    .comment_ts_kinds = &.{}, // TODO: comment
    .decl_ts_kinds = &.{}, // TODO: function_definition, class_definition, decorated_definition, import_*, assignment (module-level)
    .container_ts_kinds = &.{}, // TODO: module, class_definition
    .classify = classify,
    .extract_name = extractName,
};

fn classify(ts_kind: []const u8) result.DeclKind {
    _ = ts_kind;
    @panic("TODO: classify Python ts_kinds into DeclKind");
}

fn extractName(list: *const node.List, source: []const u8) ?[]const u8 {
    _ = list;
    _ = source;
    @panic("TODO: extract Python decl name; unwrap decorated_definition to inner def/class first");
}

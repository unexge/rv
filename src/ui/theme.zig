//! Syntax-highlighting theme for atom-level source tokens (Option 1 of the
//! tree-sitter-queries task).
//!
//! Atoms in the SST carry `AtomKind` (code/comment/error) and raw `bytes`,
//! not the original `ts_kind` - tree-sitter's node type is dropped during
//! `sst/convert.zig` conversion. So classification here is bytes-driven:
//! per-language keyword/primitive tables plus a few lexical rules (first
//! char is a quote → string, is a digit → number, etc.).
//!
//! This is deliberately coarser than real tree-sitter highlight queries
//! would give (graduating to those is Option 2 in the task description).
//! For the acceptance case - "Rust fixture shows `fn`, `pub`, `let` as
//! keywords, strings in a distinct colour" - bytes-driven classification
//! is enough.
//!
//! `style(class, base)` layers the syntax colour on top of a base style
//! chosen for the diff marker (added/removed/changed). Unclassified
//! tokens (`.ident`, `.punct`, `.other`) keep the base fg so the diff
//! marker colour still shows through in source lines. Classified tokens
//! (keywords, types, strings, numbers, comments) replace the fg; this is
//! how the Option (c) "apply diff colour only to novel spans, leave the
//! rest syntax-themed" blend from the task's Decisions section shows up
//! in practice.

const std = @import("std");
const vaxis = @import("vaxis");
const rv = @import("rv");

pub const TokenClass = enum {
    keyword,
    type,
    string,
    number,
    comment,
    punct,
    ident,
    other,
    /// Per-byte tint for an added inline run (added symbol inside an
    /// import-group, or added bytes spliced into a 1:1 leaf word-diff).
    /// Distinct from the file-level `.added` marker style so a green
    /// span on a yellow `.changed` row reads as a within-row tint rather
    /// than a full added line.
    inline_added,
    /// Per-byte tint for a removed inline run, the counterpart to
    /// `.inline_added`.
    inline_removed,
};

/// Classify an SST atom. `atom_kind` comes from conversion; `bytes` is the
/// raw source slice the atom covers. Whitespace is already stripped by
/// conversion so `bytes` is non-empty for any real atom; callers that pass
/// `bytes.len == 0` get `.other`.
pub fn classOf(lang: rv.LanguageId, atom_kind: rv.AtomKind, bytes: []const u8) TokenClass {
    if (atom_kind == .comment) return .comment;
    if (atom_kind == .@"error") return .other;
    if (bytes.len == 0) return .other;

    const c0 = bytes[0];

    // Quoted literals: "...", '...', `...` (backtick for Go raw strings /
    // TS template literals).
    if (c0 == '"' or c0 == '\'' or c0 == '`') return .string;

    // Rust prefixed / raw strings: r"..." / r#"..."# / r##"..."## / b"..." /
    // br"..." / br#"..."# / c"..." / b'x'. The prefix (optional `b`/`c`,
    // optional `r`, optional `#`s) must be followed by `"` — otherwise e.g.
    // `r#type` is just a raw identifier and must not be classified as string.
    if (lang == .rust and bytes.len >= 2) {
        var i: usize = 0;
        if (bytes[i] == 'b' or bytes[i] == 'c') i += 1;
        const consumed_r = i < bytes.len and bytes[i] == 'r';
        if (consumed_r) i += 1;
        if (i > 0) {
            if (consumed_r) while (i < bytes.len and bytes[i] == '#') : (i += 1) {};
            if (i < bytes.len and bytes[i] == '"') return .string;
        }
        // `b'x'` byte-char literal — no raw hashes allowed.
        if (c0 == 'b' and bytes[1] == '\'') return .string;
    }

    if (std.ascii.isDigit(c0)) return .number;

    if (std.ascii.isAlphabetic(c0) or c0 == '_' or c0 == '@') {
        if (isKeyword(lang, bytes)) return .keyword;
        if (isPrimitive(lang, bytes)) return .type;
        // Convention: type names start with uppercase across all supported
        // languages. Still useful for Rust/TS/Go; Python gets a few false
        // positives on `True`/`False`/`None` but those also land in the
        // keyword list and short-circuit above.
        if (std.ascii.isUpper(c0)) return .type;
        return .ident;
    }

    return .punct;
}

/// Layer a `TokenClass` on top of a base vaxis.Style. Unclassified classes
/// (`.ident`, `.punct`, `.other`) leave the base untouched so the diff
/// marker colour still tints the rest of the source line; classified
/// tokens override the foreground with their theme colour.
pub fn style(class: TokenClass, base: vaxis.Style) vaxis.Style {
    var s = base;
    switch (class) {
        // Indexed ANSI colours so we inherit the user's palette. Choices
        // match the de-facto convention of most terminal themes:
        //   magenta = keyword, cyan = type, yellow/green = literal, grey = comment.
        .keyword => s.fg = .{ .index = 5 },
        .type => s.fg = .{ .index = 6 },
        .string => s.fg = .{ .index = 2 },
        .number => s.fg = .{ .index = 3 },
        .comment => {
            s.fg = .{ .index = 8 };
            s.dim = true;
        },
        // Bold + underline / strikethrough lift the per-byte tint above
        // its surrounding `.changed` row colour and distinguish it from
        // a regular `.added` / `.removed` source line (which carries the
        // same fg without these attributes).
        .inline_added => {
            s.fg = .{ .index = 2 };
            s.bold = true;
            s.ul_style = .single;
        },
        .inline_removed => {
            s.fg = .{ .index = 1 };
            s.bold = true;
            s.strikethrough = true;
        },
        .ident, .punct, .other => {},
    }
    return s;
}

// ── per-language keyword / primitive tables ────────────────────────────────

fn isKeyword(lang: rv.LanguageId, bytes: []const u8) bool {
    const list: []const []const u8 = switch (lang) {
        .zig => &zig_keywords,
        .rust => &rust_keywords,
        .go => &go_keywords,
        .python => &python_keywords,
        .typescript => &typescript_keywords,
    };
    return contains(list, bytes);
}

fn isPrimitive(lang: rv.LanguageId, bytes: []const u8) bool {
    const list: []const []const u8 = switch (lang) {
        .zig => &zig_primitives,
        .rust => &rust_primitives,
        .go => &go_primitives,
        .python => &python_primitives,
        .typescript => &typescript_primitives,
    };
    return contains(list, bytes);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

// Zig keywords (ziglang.org/documentation/master/#Keyword-Reference).
const zig_keywords = [_][]const u8{
    "align",  "allowzero",   "and",            "anyframe",  "anytype",     "asm",
    "async",  "await",       "break",          "callconv",  "catch",       "comptime",
    "const",  "continue",    "defer",          "else",      "enum",        "errdefer",
    "error",  "export",      "extern",         "fn",        "for",         "if",
    "inline", "linksection", "noalias",        "noinline",  "nosuspend",   "opaque",
    "or",     "orelse",      "packed",         "pub",       "resume",      "return",
    "struct", "suspend",     "switch",         "test",      "threadlocal", "try",
    "union",  "unreachable", "usingnamespace", "var",       "volatile",    "while",
    "true",   "false",       "null",           "undefined",
};
const zig_primitives = [_][]const u8{
    "void",       "bool",        "noreturn",     "type",         "anyerror",       "anyopaque",
    "u8",         "u16",         "u32",          "u64",          "u128",           "usize",
    "i8",         "i16",         "i32",          "i64",          "i128",           "isize",
    "f16",        "f32",         "f64",          "f80",          "f128",           "c_char",
    "c_int",      "c_uint",      "c_long",       "c_ulong",      "c_short",        "c_ushort",
    "c_longlong", "c_ulonglong", "c_longdouble", "comptime_int", "comptime_float",
};

const rust_keywords = [_][]const u8{
    "as",     "async",  "await", "break",  "const",       "continue", "crate",
    "dyn",    "else",   "enum",  "extern", "false",       "fn",       "for",
    "if",     "impl",   "in",    "let",    "loop",        "match",    "mod",
    "move",   "mut",    "pub",   "ref",    "return",      "self",     "Self",
    "static", "struct", "super", "trait",  "true",        "type",     "unsafe",
    "use",    "where",  "while", "yield",  "macro_rules",
};
const rust_primitives = [_][]const u8{
    "bool", "char", "str", "u8",  "u16",  "u32",   "u64", "u128", "usize",
    "i8",   "i16",  "i32", "i64", "i128", "isize", "f32", "f64",  "()",
};

const go_keywords = [_][]const u8{
    "break",     "case",   "chan",    "const",       "continue",
    "default",   "defer",  "else",    "fallthrough", "for",
    "func",      "go",     "goto",    "if",          "import",
    "interface", "map",    "package", "range",       "return",
    "select",    "struct", "switch",  "type",        "var",
    "true",      "false",  "nil",     "iota",
};
const go_primitives = [_][]const u8{
    "bool",    "byte",      "rune",       "string",
    "int",     "int8",      "int16",      "int32",
    "int64",   "uint",      "uint8",      "uint16",
    "uint32",  "uint64",    "uintptr",    "float32",
    "float64", "complex64", "complex128", "error",
    "any",
};

const python_keywords = [_][]const u8{
    "False",  "None",     "True",  "and",    "as",       "assert",
    "async",  "await",    "break", "class",  "continue", "def",
    "del",    "elif",     "else",  "except", "finally",  "for",
    "from",   "global",   "if",    "import", "in",       "is",
    "lambda", "nonlocal", "not",   "or",     "pass",     "raise",
    "return", "try",      "while", "with",   "yield",    "match",
    "case",   "self",     "cls",
};
const python_primitives = [_][]const u8{
    "int", "float",     "bool",    "str",    "bytes", "list", "tuple", "dict",
    "set", "frozenset", "complex", "object", "type",
};

const typescript_keywords = [_][]const u8{
    "abstract",  "as",         "async",    "await",    "break",
    "case",      "catch",      "class",    "const",    "continue",
    "debugger",  "declare",    "default",  "delete",   "do",
    "else",      "enum",       "export",   "extends",  "false",
    "finally",   "for",        "from",     "function", "get",
    "if",        "implements", "import",   "in",       "instanceof",
    "interface", "is",         "keyof",    "let",      "namespace",
    "new",       "null",       "of",       "package",  "private",
    "protected", "public",     "readonly", "return",   "satisfies",
    "set",       "static",     "super",    "switch",   "this",
    "throw",     "true",       "try",      "type",     "typeof",
    "undefined", "var",        "void",     "while",    "with",
    "yield",     "module",     "override", "asserts",
};
const typescript_primitives = [_][]const u8{
    "any",    "unknown", "never",   "object",
    "string", "number",  "boolean", "bigint",
    "symbol",
};

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "classOf: comment kind always wins over bytes" {
    // Even if the bytes happen to match a keyword, `.comment` takes over.
    try testing.expectEqual(TokenClass.comment, classOf(.rust, .comment, "// fn pub"));
    try testing.expectEqual(TokenClass.comment, classOf(.zig, .comment, "/* x */"));
}

test "classOf: error atom classifies as .other" {
    try testing.expectEqual(TokenClass.other, classOf(.rust, .@"error", "<incomplete>"));
}

test "classOf: empty bytes → .other" {
    try testing.expectEqual(TokenClass.other, classOf(.rust, .code, ""));
}

test "classOf: Rust raw identifiers are idents, not strings" {
    // `r#type` / `r#async` / `b#foo` are raw identifiers, not raw strings —
    // classification must require a `"` after the `#`s before deciding string.
    try testing.expectEqual(TokenClass.ident, classOf(.rust, .code, "r#type"));
    try testing.expectEqual(TokenClass.ident, classOf(.rust, .code, "r#async"));
}

test "classOf: Rust keywords, types, strings, numbers" {
    try testing.expectEqual(TokenClass.keyword, classOf(.rust, .code, "fn"));
    try testing.expectEqual(TokenClass.keyword, classOf(.rust, .code, "pub"));
    try testing.expectEqual(TokenClass.keyword, classOf(.rust, .code, "let"));
    try testing.expectEqual(TokenClass.keyword, classOf(.rust, .code, "impl"));
    try testing.expectEqual(TokenClass.type, classOf(.rust, .code, "u32"));
    try testing.expectEqual(TokenClass.type, classOf(.rust, .code, "String"));
    try testing.expectEqual(TokenClass.string, classOf(.rust, .code, "\"hi\""));
    try testing.expectEqual(TokenClass.string, classOf(.rust, .code, "'a'"));
    try testing.expectEqual(TokenClass.string, classOf(.rust, .code, "r\"raw\""));
    try testing.expectEqual(TokenClass.string, classOf(.rust, .code, "b\"bytes\""));
    try testing.expectEqual(TokenClass.string, classOf(.rust, .code, "br\"raw bytes\""));
    try testing.expectEqual(TokenClass.string, classOf(.rust, .code, "r#\"raw hash\"#"));
    try testing.expectEqual(TokenClass.number, classOf(.rust, .code, "42"));
    try testing.expectEqual(TokenClass.number, classOf(.rust, .code, "0xff"));
    try testing.expectEqual(TokenClass.number, classOf(.rust, .code, "3.14"));
    try testing.expectEqual(TokenClass.ident, classOf(.rust, .code, "foo"));
    try testing.expectEqual(TokenClass.punct, classOf(.rust, .code, "->"));
    try testing.expectEqual(TokenClass.punct, classOf(.rust, .code, ";"));
}

test "classOf: Zig keywords and primitives" {
    try testing.expectEqual(TokenClass.keyword, classOf(.zig, .code, "fn"));
    try testing.expectEqual(TokenClass.keyword, classOf(.zig, .code, "pub"));
    try testing.expectEqual(TokenClass.keyword, classOf(.zig, .code, "const"));
    try testing.expectEqual(TokenClass.type, classOf(.zig, .code, "u32"));
    try testing.expectEqual(TokenClass.type, classOf(.zig, .code, "void"));
    try testing.expectEqual(TokenClass.string, classOf(.zig, .code, "\"x\""));
}

test "classOf: Go / Python / TypeScript sample" {
    try testing.expectEqual(TokenClass.keyword, classOf(.go, .code, "func"));
    try testing.expectEqual(TokenClass.type, classOf(.go, .code, "int"));

    try testing.expectEqual(TokenClass.keyword, classOf(.python, .code, "def"));
    try testing.expectEqual(TokenClass.keyword, classOf(.python, .code, "True"));

    try testing.expectEqual(TokenClass.keyword, classOf(.typescript, .code, "function"));
    try testing.expectEqual(TokenClass.type, classOf(.typescript, .code, "number"));
    try testing.expectEqual(TokenClass.string, classOf(.typescript, .code, "`tpl`"));
}

test "style: keyword overrides fg, ident leaves base intact" {
    const base: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
    const kw = style(.keyword, base);
    try testing.expect(kw.fg == .index and kw.fg.index == 5);
    try testing.expect(kw.bold);

    const id = style(.ident, base);
    try testing.expect(id.fg == .index and id.fg.index == 3);
    try testing.expect(id.bold);
}

test "style: comment carries dim" {
    const base: vaxis.Style = .{};
    const c = style(.comment, base);
    try testing.expect(c.dim);
}

test "style: inline classes are visually distinct from file-level add/remove" {
    // A regular `.added` source line uses fg index 2 with no bold; the
    // per-byte `.inline_added` class layered on a `.changed` row's
    // yellow base must end up structurally different so the user can
    // tell a within-row tint from a full added line.
    const added_row_base: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const changed_row_base: vaxis.Style = .{ .fg = .{ .index = 3 } };

    const inline_added = style(.inline_added, changed_row_base);
    const inline_removed = style(.inline_removed, changed_row_base);

    try testing.expect(!added_row_base.eql(inline_added));
    try testing.expect(!added_row_base.eql(inline_removed));
    try testing.expect(inline_added.bold);
    try testing.expect(inline_removed.bold);
    try testing.expect(inline_added.fg == .index and inline_added.fg.index == 2);
    try testing.expect(inline_removed.fg == .index and inline_removed.fg.index == 1);
    try testing.expectEqual(vaxis.Style.Underline.single, inline_added.ul_style);
    try testing.expect(inline_removed.strikethrough);
}

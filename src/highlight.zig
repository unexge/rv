const std = @import("std");
const Allocator = std.mem.Allocator;
const treez = @import("treez");

/// Syntax highlight categories
pub const HighlightType = enum {
    none,
    keyword,
    type_,
    function,
    string,
    number,
    comment,
    operator,
    punctuation,
    constant,
    variable,
};

/// A highlighted span within source code
pub const HighlightSpan = struct {
    start_byte: u32,
    end_byte: u32,
    highlight: HighlightType,
};

/// Supported languages for syntax highlighting
pub const Language = enum {
    zig,
    rust,
    python,
    javascript,
    typescript,
    go,
    c,
    cpp,
    java,
    json,
    yaml,
    toml,
    bash,

    /// Detect language from file extension
    pub fn fromExtension(ext: []const u8) ?Language {
        if (std.mem.eql(u8, ext, "zig")) return .zig;
        if (std.mem.eql(u8, ext, "rs")) return .rust;
        if (std.mem.eql(u8, ext, "py")) return .python;
        if (std.mem.eql(u8, ext, "js") or std.mem.eql(u8, ext, "mjs") or std.mem.eql(u8, ext, "cjs")) return .javascript;
        if (std.mem.eql(u8, ext, "ts") or std.mem.eql(u8, ext, "tsx")) return .typescript;
        if (std.mem.eql(u8, ext, "go")) return .go;
        if (std.mem.eql(u8, ext, "c") or std.mem.eql(u8, ext, "h")) return .c;
        if (std.mem.eql(u8, ext, "cpp") or std.mem.eql(u8, ext, "cc") or std.mem.eql(u8, ext, "cxx") or std.mem.eql(u8, ext, "hpp")) return .cpp;
        if (std.mem.eql(u8, ext, "java")) return .java;
        if (std.mem.eql(u8, ext, "json")) return .json;
        if (std.mem.eql(u8, ext, "yaml") or std.mem.eql(u8, ext, "yml")) return .yaml;
        if (std.mem.eql(u8, ext, "toml")) return .toml;
        if (std.mem.eql(u8, ext, "sh") or std.mem.eql(u8, ext, "bash")) return .bash;
        return null;
    }

    /// Detect language from file path
    pub fn fromPath(path: []const u8) ?Language {
        const basename = std.fs.path.basename(path);
        const ext_start = std.mem.lastIndexOf(u8, basename, ".") orelse return null;
        if (ext_start == 0) return null;
        return fromExtension(basename[ext_start + 1 ..]);
    }
};

/// Syntax highlighter using tree-sitter
pub const Highlighter = struct {
    allocator: Allocator,
    parser: *treez.Parser,
    language: *const treez.Language,

    pub const Error = error{
        LanguageNotSupported,
        ParserCreationFailed,
        ParseFailed,
    } || Allocator.Error;

    /// Create a new highlighter for the given language
    pub fn init(allocator: Allocator, lang: Language) Error!Highlighter {
        const ts_lang = getTreeSitterLanguage(lang) catch return error.LanguageNotSupported;

        const parser = treez.Parser.create() catch return error.ParserCreationFailed;
        errdefer parser.destroy();

        parser.setLanguage(ts_lang) catch return error.ParserCreationFailed;

        return Highlighter{
            .allocator = allocator,
            .parser = parser,
            .language = ts_lang,
        };
    }

    pub fn deinit(self: *Highlighter) void {
        self.parser.destroy();
    }

    /// Highlight source code and return spans
    pub fn highlight(self: *Highlighter, source: []const u8) Error![]HighlightSpan {
        const tree = self.parser.parseString(null, source) catch return error.ParseFailed;
        defer tree.destroy();

        var spans: std.ArrayList(HighlightSpan) = .empty;
        errdefer spans.deinit(self.allocator);

        // Iterative tree traversal
        var cursor = treez.Tree.Cursor.create(tree.getRootNode());
        defer cursor.destroy();

        var reached_root = false;
        while (!reached_root) {
            const node = cursor.getCurrentNode();
            const node_type = node.getType();

            const hl_type = inferHighlight(node_type);
            if (hl_type != .none) {
                try spans.append(self.allocator, .{
                    .start_byte = node.getStartByte(),
                    .end_byte = node.getEndByte(),
                    .highlight = hl_type,
                });
            }

            if (cursor.gotoFirstChild()) continue;
            if (cursor.gotoNextSibling()) continue;

            var retrace = true;
            while (retrace) {
                if (!cursor.gotoParent()) {
                    reached_root = true;
                    retrace = false;
                } else if (cursor.gotoNextSibling()) {
                    retrace = false;
                }
            }
        }

        // Sort by start position
        std.mem.sort(HighlightSpan, spans.items, {}, struct {
            fn lessThan(_: void, a: HighlightSpan, b: HighlightSpan) bool {
                return a.start_byte < b.start_byte;
            }
        }.lessThan);

        return spans.toOwnedSlice(self.allocator);
    }
};

fn getTreeSitterLanguage(lang: Language) !*const treez.Language {
    return switch (lang) {
        .zig => treez.Language.get("zig"),
        .rust => treez.Language.get("rust"),
        .python => treez.Language.get("python"),
        .javascript => treez.Language.get("javascript"),
        .typescript => treez.Language.get("typescript"),
        .go => treez.Language.get("go"),
        .c => treez.Language.get("c"),
        .cpp => treez.Language.get("cpp"),
        .java => treez.Language.get("java"),
        .json => treez.Language.get("json"),
        .yaml => treez.Language.get("yaml"),
        .toml => treez.Language.get("toml"),
        .bash => treez.Language.get("bash"),
    };
}

/// Infer highlight type from node type name
fn inferHighlight(node_type: []const u8) HighlightType {
    // Comments
    if (std.mem.indexOf(u8, node_type, "comment") != null) return .comment;

    // Strings
    if (std.mem.indexOf(u8, node_type, "string") != null) return .string;
    if (std.mem.eql(u8, node_type, "character") or std.mem.eql(u8, node_type, "char_literal")) return .string;

    // Numbers
    if (std.mem.eql(u8, node_type, "integer") or
        std.mem.eql(u8, node_type, "float") or
        std.mem.eql(u8, node_type, "number") or
        std.mem.eql(u8, node_type, "integer_literal") or
        std.mem.eql(u8, node_type, "float_literal"))
    {
        return .number;
    }

    // Built-in types
    if (std.mem.eql(u8, node_type, "builtin_type") or
        std.mem.eql(u8, node_type, "primitive_type") or
        std.mem.eql(u8, node_type, "type_identifier"))
    {
        return .type_;
    }

    // Common type keywords
    if (std.mem.eql(u8, node_type, "void") or
        std.mem.eql(u8, node_type, "bool") or
        std.mem.eql(u8, node_type, "type") or
        std.mem.eql(u8, node_type, "anytype") or
        std.mem.eql(u8, node_type, "noreturn"))
    {
        return .type_;
    }

    // Functions
    if (std.mem.indexOf(u8, node_type, "function") != null) return .function;
    if (std.mem.eql(u8, node_type, "call_expression")) return .function;
    if (std.mem.eql(u8, node_type, "builtin_identifier")) return .function;

    // Keywords - common across languages
    if (std.mem.eql(u8, node_type, "const") or
        std.mem.eql(u8, node_type, "var") or
        std.mem.eql(u8, node_type, "let") or
        std.mem.eql(u8, node_type, "fn") or
        std.mem.eql(u8, node_type, "pub") or
        std.mem.eql(u8, node_type, "return") or
        std.mem.eql(u8, node_type, "if") or
        std.mem.eql(u8, node_type, "else") or
        std.mem.eql(u8, node_type, "for") or
        std.mem.eql(u8, node_type, "while") or
        std.mem.eql(u8, node_type, "break") or
        std.mem.eql(u8, node_type, "continue") or
        std.mem.eql(u8, node_type, "switch") or
        std.mem.eql(u8, node_type, "defer") or
        std.mem.eql(u8, node_type, "errdefer") or
        std.mem.eql(u8, node_type, "try") or
        std.mem.eql(u8, node_type, "catch") or
        std.mem.eql(u8, node_type, "struct") or
        std.mem.eql(u8, node_type, "enum") or
        std.mem.eql(u8, node_type, "union") or
        std.mem.eql(u8, node_type, "async") or
        std.mem.eql(u8, node_type, "await") or
        std.mem.eql(u8, node_type, "comptime") or
        std.mem.eql(u8, node_type, "inline") or
        std.mem.eql(u8, node_type, "extern") or
        std.mem.eql(u8, node_type, "export") or
        std.mem.eql(u8, node_type, "import") or
        std.mem.eql(u8, node_type, "class") or
        std.mem.eql(u8, node_type, "def") or
        std.mem.eql(u8, node_type, "func"))
    {
        return .keyword;
    }

    // Constants
    if (std.mem.eql(u8, node_type, "true") or
        std.mem.eql(u8, node_type, "false") or
        std.mem.eql(u8, node_type, "null") or
        std.mem.eql(u8, node_type, "undefined") or
        std.mem.eql(u8, node_type, "nil") or
        std.mem.eql(u8, node_type, "none"))
    {
        return .constant;
    }

    return .none;
}

// Tests
test "Language.fromExtension" {
    try std.testing.expectEqual(Language.zig, Language.fromExtension("zig").?);
    try std.testing.expectEqual(Language.rust, Language.fromExtension("rs").?);
    try std.testing.expectEqual(Language.python, Language.fromExtension("py").?);
    try std.testing.expect(Language.fromExtension("unknown") == null);
}

test "Language.fromPath" {
    try std.testing.expectEqual(Language.zig, Language.fromPath("src/main.zig").?);
    try std.testing.expectEqual(Language.rust, Language.fromPath("lib.rs").?);
    try std.testing.expect(Language.fromPath(".gitignore") == null);
}

test "Highlighter basic" {
    const allocator = std.testing.allocator;

    var highlighter = try Highlighter.init(allocator, .zig);
    defer highlighter.deinit();

    const spans = try highlighter.highlight("const x = 42;");
    defer allocator.free(spans);

    try std.testing.expect(spans.len > 0);
}

test "Highlighter finds keywords and types" {
    const allocator = std.testing.allocator;

    var highlighter = try Highlighter.init(allocator, .zig);
    defer highlighter.deinit();

    const spans = try highlighter.highlight("pub fn main() void {}");
    defer allocator.free(spans);

    var found_keyword = false;
    var found_type = false;
    for (spans) |span| {
        if (span.highlight == .keyword) found_keyword = true;
        if (span.highlight == .type_) found_type = true;
    }
    try std.testing.expect(found_keyword);
    try std.testing.expect(found_type);
}

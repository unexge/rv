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

/// Infer highlight type from tree-sitter node type name.
/// Tree-sitter grammars use semantic parent nodes (like `builtin_type`, `string`)
/// that cover their children, so we match those container nodes rather than
/// enumerating every possible child (e.g., we match `builtin_type` not `void`).
/// Keywords are the exception - tree-sitter uses the keyword text as the node type.
fn inferHighlight(node_type: []const u8) HighlightType {
    // Comments - any node containing "comment"
    if (std.mem.indexOf(u8, node_type, "comment") != null) return .comment;

    // Strings - container nodes (covers quotes and content)
    if (std.mem.eql(u8, node_type, "string") or
        std.mem.eql(u8, node_type, "string_literal") or
        std.mem.eql(u8, node_type, "interpreted_string_literal") or
        std.mem.eql(u8, node_type, "raw_string_literal") or
        std.mem.eql(u8, node_type, "character") or
        std.mem.eql(u8, node_type, "char_literal") or
        std.mem.eql(u8, node_type, "rune_literal"))
    {
        return .string;
    }

    // Numbers - container nodes
    if (std.mem.eql(u8, node_type, "integer") or
        std.mem.eql(u8, node_type, "float") or
        std.mem.eql(u8, node_type, "number") or
        std.mem.eql(u8, node_type, "integer_literal") or
        std.mem.eql(u8, node_type, "float_literal"))
    {
        return .number;
    }

    // Types - container nodes that wrap specific type names
    if (std.mem.eql(u8, node_type, "builtin_type") or
        std.mem.eql(u8, node_type, "primitive_type") or
        std.mem.eql(u8, node_type, "type_identifier"))
    {
        return .type_;
    }

    // Builtin function calls (like @import, @intCast)
    if (std.mem.eql(u8, node_type, "builtin_identifier")) {
        return .function;
    }

    // Keywords - tree-sitter uses the keyword text as the node type
    // These are common across many languages
    if (std.mem.eql(u8, node_type, "const") or
        std.mem.eql(u8, node_type, "var") or
        std.mem.eql(u8, node_type, "let") or
        std.mem.eql(u8, node_type, "fn") or
        std.mem.eql(u8, node_type, "func") or
        std.mem.eql(u8, node_type, "def") or
        std.mem.eql(u8, node_type, "pub") or
        std.mem.eql(u8, node_type, "return") or
        std.mem.eql(u8, node_type, "if") or
        std.mem.eql(u8, node_type, "else") or
        std.mem.eql(u8, node_type, "for") or
        std.mem.eql(u8, node_type, "while") or
        std.mem.eql(u8, node_type, "loop") or
        std.mem.eql(u8, node_type, "do") or
        std.mem.eql(u8, node_type, "break") or
        std.mem.eql(u8, node_type, "continue") or
        std.mem.eql(u8, node_type, "switch") or
        std.mem.eql(u8, node_type, "match") or
        std.mem.eql(u8, node_type, "case") or
        std.mem.eql(u8, node_type, "default") or
        std.mem.eql(u8, node_type, "defer") or
        std.mem.eql(u8, node_type, "try") or
        std.mem.eql(u8, node_type, "catch") or
        std.mem.eql(u8, node_type, "throw") or
        std.mem.eql(u8, node_type, "finally") or
        std.mem.eql(u8, node_type, "struct") or
        std.mem.eql(u8, node_type, "enum") or
        std.mem.eql(u8, node_type, "union") or
        std.mem.eql(u8, node_type, "class") or
        std.mem.eql(u8, node_type, "interface") or
        std.mem.eql(u8, node_type, "trait") or
        std.mem.eql(u8, node_type, "impl") or
        std.mem.eql(u8, node_type, "async") or
        std.mem.eql(u8, node_type, "await") or
        std.mem.eql(u8, node_type, "import") or
        std.mem.eql(u8, node_type, "export") or
        std.mem.eql(u8, node_type, "from") or
        std.mem.eql(u8, node_type, "use") or
        std.mem.eql(u8, node_type, "mod") or
        std.mem.eql(u8, node_type, "package") or
        std.mem.eql(u8, node_type, "static") or
        std.mem.eql(u8, node_type, "extern") or
        std.mem.eql(u8, node_type, "inline") or
        std.mem.eql(u8, node_type, "public") or
        std.mem.eql(u8, node_type, "private") or
        std.mem.eql(u8, node_type, "protected") or
        std.mem.eql(u8, node_type, "new") or
        std.mem.eql(u8, node_type, "this") or
        std.mem.eql(u8, node_type, "self") or
        std.mem.eql(u8, node_type, "super") or
        std.mem.eql(u8, node_type, "as") or
        std.mem.eql(u8, node_type, "in") or
        std.mem.eql(u8, node_type, "is") or
        std.mem.eql(u8, node_type, "not") or
        std.mem.eql(u8, node_type, "and") or
        std.mem.eql(u8, node_type, "or") or
        std.mem.eql(u8, node_type, "typeof") or
        std.mem.eql(u8, node_type, "sizeof") or
        std.mem.eql(u8, node_type, "yield") or
        std.mem.eql(u8, node_type, "with") or
        std.mem.eql(u8, node_type, "lambda") or
        std.mem.eql(u8, node_type, "goto") or
        std.mem.eql(u8, node_type, "select") or
        std.mem.eql(u8, node_type, "chan") or
        std.mem.eql(u8, node_type, "go") or
        std.mem.eql(u8, node_type, "range") or
        std.mem.eql(u8, node_type, "mut") or
        std.mem.eql(u8, node_type, "ref") or
        std.mem.eql(u8, node_type, "move") or
        std.mem.eql(u8, node_type, "unsafe") or
        std.mem.eql(u8, node_type, "where") or
        std.mem.eql(u8, node_type, "dyn") or
        std.mem.eql(u8, node_type, "crate") or
        // Zig-specific keywords (node type = keyword text)
        std.mem.eql(u8, node_type, "comptime") or
        std.mem.eql(u8, node_type, "errdefer") or
        std.mem.eql(u8, node_type, "orelse") or
        std.mem.eql(u8, node_type, "test") or
        std.mem.eql(u8, node_type, "error") or
        std.mem.eql(u8, node_type, "suspend") or
        std.mem.eql(u8, node_type, "resume") or
        std.mem.eql(u8, node_type, "nosuspend") or
        std.mem.eql(u8, node_type, "threadlocal") or
        std.mem.eql(u8, node_type, "usingnamespace") or
        std.mem.eql(u8, node_type, "asm") or
        std.mem.eql(u8, node_type, "volatile") or
        std.mem.eql(u8, node_type, "allowzero") or
        std.mem.eql(u8, node_type, "packed") or
        std.mem.eql(u8, node_type, "align") or
        std.mem.eql(u8, node_type, "linksection") or
        std.mem.eql(u8, node_type, "callconv") or
        std.mem.eql(u8, node_type, "noinline"))
    {
        return .keyword;
    }

    // Constants / boolean literals
    if (std.mem.eql(u8, node_type, "true") or
        std.mem.eql(u8, node_type, "false") or
        std.mem.eql(u8, node_type, "null") or
        std.mem.eql(u8, node_type, "nil") or
        std.mem.eql(u8, node_type, "none") or
        std.mem.eql(u8, node_type, "None") or
        std.mem.eql(u8, node_type, "True") or
        std.mem.eql(u8, node_type, "False") or
        std.mem.eql(u8, node_type, "undefined") or
        std.mem.eql(u8, node_type, "unreachable") or
        std.mem.eql(u8, node_type, "null_literal") or
        std.mem.eql(u8, node_type, "boolean"))
    {
        return .constant;
    }

    // Operators (single and compound)
    if (node_type.len <= 3 and node_type.len >= 1) {
        const c = node_type[0];
        if (c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or
            c == '=' or c == '!' or c == '<' or c == '>' or c == '&' or
            c == '|' or c == '^' or c == '~' or c == '?' or c == '.')
        {
            return .operator;
        }
        if (node_type.len == 2 and (std.mem.eql(u8, node_type, "::") or
            std.mem.eql(u8, node_type, "..")))
        {
            return .operator;
        }
    }

    // Punctuation
    if (node_type.len == 1) {
        const c = node_type[0];
        if (c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or
            c == '}' or c == ',' or c == ';' or c == ':' or c == '@' or c == '#')
        {
            return .punctuation;
        }
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

test "Highlighter finds strings numbers and operators" {
    const allocator = std.testing.allocator;

    var highlighter = try Highlighter.init(allocator, .zig);
    defer highlighter.deinit();

    const source =
        \\const msg = "hello";
        \\var x = 42;
        \\if (x > 10) {}
    ;

    const spans = try highlighter.highlight(source);
    defer allocator.free(spans);

    var found_string = false;
    var found_number = false;
    var found_operator = false;
    for (spans) |span| {
        if (span.highlight == .string) found_string = true;
        if (span.highlight == .number) found_number = true;
        if (span.highlight == .operator) found_operator = true;
    }
    try std.testing.expect(found_string);
    try std.testing.expect(found_number);
    try std.testing.expect(found_operator);
}

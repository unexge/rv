//! Language registry.
//!
//! Single source of truth for which languages rv supports. Adding a sixth
//! language = add an enum variant + a per-language config file + a switch arm.

const std = @import("std");
const config_mod = @import("config.zig");

const zig_lang = @import("zig.zig");
const rust_lang = @import("rust.zig");
const go_lang = @import("go.zig");
const python_lang = @import("python.zig");
const typescript_lang = @import("typescript.zig");

pub const LanguageId = enum {
    zig,
    rust,
    go,
    python,
    typescript,
};

/// Best-effort language inference from a file path's extension. Returns null
/// if unrecognised; callers may fall back to explicit selection.
pub fn languageFromPath(path: []const u8) ?LanguageId {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    if (std.mem.eql(u8, ext, ".py")) return .python;
    if (std.mem.eql(u8, ext, ".ts")) return .typescript;
    if (std.mem.eql(u8, ext, ".mts")) return .typescript;
    if (std.mem.eql(u8, ext, ".cts")) return .typescript;
    return null;
}

/// Config for a given language. Always returns a valid pointer - `LanguageId`
/// is closed.
pub fn config(id: LanguageId) *const config_mod.LangConfig {
    return switch (id) {
        .zig => &zig_lang.config,
        .rust => &rust_lang.config,
        .go => &go_lang.config,
        .python => &python_lang.config,
        .typescript => &typescript_lang.config,
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "languageFromPath: recognises .zig" {
    try testing.expectEqual(LanguageId.zig, languageFromPath("src/main.zig").?);
    try testing.expectEqual(LanguageId.zig, languageFromPath("main.zig").?);
}

test "languageFromPath: recognises .rs" {
    try testing.expectEqual(LanguageId.rust, languageFromPath("src/lib.rs").?);
}

test "languageFromPath: recognises .go" {
    try testing.expectEqual(LanguageId.go, languageFromPath("cmd/app/main.go").?);
}

test "languageFromPath: recognises .py" {
    try testing.expectEqual(LanguageId.python, languageFromPath("a/b.py").?);
}

test "languageFromPath: recognises .ts, .mts, .cts" {
    try testing.expectEqual(LanguageId.typescript, languageFromPath("x.ts").?);
    try testing.expectEqual(LanguageId.typescript, languageFromPath("x.mts").?);
    try testing.expectEqual(LanguageId.typescript, languageFromPath("x.cts").?);
}

test "languageFromPath: unknown extension returns null" {
    try testing.expect(languageFromPath("README.md") == null);
    try testing.expect(languageFromPath("noext") == null);
    try testing.expect(languageFromPath("a.tsx") == null); // TSX deferred to phase 2
    try testing.expect(languageFromPath("") == null);
}

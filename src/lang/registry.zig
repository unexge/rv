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
    _ = path;
    @panic("TODO: map .zig/.rs/.go/.py/.ts|.tsx to LanguageId");
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

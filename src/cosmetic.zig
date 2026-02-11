const std = @import("std");
const Allocator = std.mem.Allocator;
const difft = @import("difft.zig");
const highlight = @import("highlight.zig");
const collapse = @import("collapse.zig");
const treez = @import("treez");

/// Category of a change - whether it's cosmetic or semantic
pub const ChangeCategory = enum {
    /// Change that only affects comments (no logic change)
    comment,
    /// Change that only affects whitespace/formatting
    whitespace,
    /// Change that renames identifiers without changing logic
    rename,
    /// Change where code was moved to a different location
    moved,
    /// Change that affects actual program logic
    semantic,

    /// Returns true if this category is considered cosmetic (can be hidden)
    pub fn isCosmetic(self: ChangeCategory) bool {
        return switch (self) {
            .comment, .whitespace, .rename, .moved => true,
            .semantic => false,
        };
    }

    /// Returns a human-readable label for this category
    pub fn label(self: ChangeCategory) []const u8 {
        return switch (self) {
            .comment => "comment",
            .whitespace => "whitespace",
            .rename => "rename",
            .moved => "moved",
            .semantic => "semantic",
        };
    }

    /// Returns a symbol/icon for display
    pub fn symbol(self: ChangeCategory) []const u8 {
        return switch (self) {
            .comment => "💬",
            .whitespace => "⎵",
            .rename => "≈",
            .moved => "→",
            .semantic => "•",
        };
    }
};

/// Result of analyzing a change for cosmetic classification
pub const CosmeticAnalysis = struct {
    /// The determined category of the change
    category: ChangeCategory,
    /// Confidence score from 0.0 (low) to 1.0 (high)
    confidence: f32,
    /// Optional details explaining the classification
    details: ?[]const u8,
    /// For renames: the old identifier name
    old_name: ?[]const u8 = null,
    /// For renames: the new identifier name
    new_name: ?[]const u8 = null,
    /// For moved: the original line number
    moved_from_line: ?u32 = null,
    /// For moved: the new line number
    moved_to_line: ?u32 = null,

    /// Create a semantic analysis result (default for non-cosmetic changes)
    pub fn semantic() CosmeticAnalysis {
        return .{
            .category = .semantic,
            .confidence = 1.0,
            .details = null,
        };
    }

    /// Create a comment-only analysis result
    pub fn commentOnly(confidence: f32, details: ?[]const u8) CosmeticAnalysis {
        return .{
            .category = .comment,
            .confidence = confidence,
            .details = details,
        };
    }

    /// Create a whitespace-only analysis result
    pub fn whitespaceOnly(confidence: f32, details: ?[]const u8) CosmeticAnalysis {
        return .{
            .category = .whitespace,
            .confidence = confidence,
            .details = details,
        };
    }

    /// Create a rename analysis result
    pub fn renameChange(confidence: f32, old_name: ?[]const u8, new_name: ?[]const u8) CosmeticAnalysis {
        return .{
            .category = .rename,
            .confidence = confidence,
            .details = null,
            .old_name = old_name,
            .new_name = new_name,
        };
    }

    /// Create a moved construct analysis result
    pub fn movedConstruct(confidence: f32, from_line: u32, to_line: u32) CosmeticAnalysis {
        return .{
            .category = .moved,
            .confidence = confidence,
            .details = null,
            .moved_from_line = from_line,
            .moved_to_line = to_line,
        };
    }
};

/// Configuration for cosmetic change detection thresholds
pub const CosmeticConfig = struct {
    /// Minimum confidence to classify a change as cosmetic (0.0-1.0)
    min_confidence: f32 = 0.8,
    /// Minimum similarity score for "moved" detection (0.0-1.0)
    move_similarity_threshold: f32 = 0.95,
    /// Whether to include comment-only changes as cosmetic
    detect_comments: bool = true,
    /// Whether to include whitespace-only changes as cosmetic
    detect_whitespace: bool = true,
    /// Whether to include renames as cosmetic
    detect_renames: bool = true,
    /// Whether to include moved constructs as cosmetic
    detect_moved: bool = true,

    /// Default configuration with all detection enabled
    pub fn default() CosmeticConfig {
        return .{};
    }

    /// Strict configuration requiring higher confidence
    pub fn strict() CosmeticConfig {
        return .{
            .min_confidence = 0.95,
            .move_similarity_threshold = 0.99,
        };
    }
};

/// Information about a moved construct
pub const MovedConstruct = struct {
    /// Name of the moved construct
    name: []const u8,
    /// Type of the construct (function, struct, etc.)
    node_type: collapse.NodeType,
    /// Original location
    old_start_line: u32,
    old_end_line: u32,
    /// New location
    new_start_line: u32,
    new_end_line: u32,
    /// Similarity score (1.0 = identical)
    similarity: f32,
};

/// Mapping from old identifier name to new identifier name
pub const IdentifierMapping = struct {
    old_name: []const u8,
    new_name: []const u8,
    /// Number of occurrences of this rename
    count: u32 = 1,
};

// ============================================================================
// Stub functions for future implementation
// ============================================================================

/// Analyze a change to determine if it's cosmetic or semantic
/// This is the main entry point for cosmetic detection.
pub fn analyzeChange(
    allocator: Allocator,
    entry: difft.DiffEntry,
    old_content: ?[]const u8,
    new_content: ?[]const u8,
    config: CosmeticConfig,
) !CosmeticAnalysis {
    _ = allocator;
    _ = old_content;
    _ = new_content;

    // First check for comment-only changes (cheapest check using difft highlight info)
    if (config.detect_comments) {
        if (isCommentOnly(entry)) {
            return CosmeticAnalysis.commentOnly(1.0, "only comments changed");
        }
    }

    // Check for whitespace-only changes
    if (config.detect_whitespace) {
        if (isWhitespaceOnly(entry)) {
            return CosmeticAnalysis.whitespaceOnly(1.0, "only whitespace changed");
        }
    }

    // Rename and moved detection require more complex analysis
    // These will be implemented in separate tasks

    return CosmeticAnalysis.semantic();
}

/// Check if a diff entry contains only comment changes
/// Uses difft's highlight field to identify comment tokens
pub fn isCommentOnly(entry: difft.DiffEntry) bool {
    return areChangesCommentOnly(entry.lhs, entry.rhs);
}

/// Check if changes from both sides are comment-only
/// This is the core logic shared between entry-level and change-level analysis
fn areChangesCommentOnly(lhs: ?difft.Side, rhs: ?difft.Side) bool {
    // Check lhs changes
    if (lhs) |l| {
        for (l.changes) |change| {
            if (change.highlight != .comment) {
                return false;
            }
        }
    }

    // Check rhs changes
    if (rhs) |r| {
        for (r.changes) |change| {
            if (change.highlight != .comment) {
                return false;
            }
        }
    }

    // Both sides must have at least one change to be a "comment change"
    const has_lhs_changes = lhs != null and lhs.?.changes.len > 0;
    const has_rhs_changes = rhs != null and rhs.?.changes.len > 0;

    return has_lhs_changes or has_rhs_changes;
}

/// Check if an array of changes contains only comments
/// Useful when analyzing individual change arrays separately
pub fn isChangesArrayCommentOnly(changes: []const difft.Change) bool {
    if (changes.len == 0) return false;

    for (changes) |change| {
        if (change.highlight != .comment) {
            return false;
        }
    }
    return true;
}

/// Analyze a diff entry to determine if it's a comment-only change
/// Returns a CosmeticAnalysis struct with category, confidence, and details
pub fn analyzeLineForComments(entry: difft.DiffEntry) CosmeticAnalysis {
    const lhs_comment_only = if (entry.lhs) |lhs|
        isChangesArrayCommentOnly(lhs.changes)
    else
        true; // No lhs = nothing non-comment on lhs

    const rhs_comment_only = if (entry.rhs) |rhs|
        isChangesArrayCommentOnly(rhs.changes)
    else
        true; // No rhs = nothing non-comment on rhs

    // Determine the type of comment change
    const has_lhs = entry.lhs != null and entry.lhs.?.changes.len > 0;
    const has_rhs = entry.rhs != null and entry.rhs.?.changes.len > 0;

    // If neither side has changes, it's not a comment change
    if (!has_lhs and !has_rhs) {
        return CosmeticAnalysis.semantic();
    }

    // If only one side has changes and they're comments
    if (has_lhs and !has_rhs and lhs_comment_only) {
        return CosmeticAnalysis.commentOnly(1.0, "comment removed");
    }
    if (!has_lhs and has_rhs and rhs_comment_only) {
        return CosmeticAnalysis.commentOnly(1.0, "comment added");
    }

    // Both sides have changes - check if all are comments
    if (has_lhs and has_rhs and lhs_comment_only and rhs_comment_only) {
        return CosmeticAnalysis.commentOnly(1.0, "comment modified");
    }

    // Mixed changes (code and comments) - this is semantic
    return CosmeticAnalysis.semantic();
}

/// Categorize comment type based on content (for informational purposes)
pub const CommentType = enum {
    /// Single-line comment (// or #)
    line,
    /// Doc comment (/// or /** */)
    doc,
    /// Block comment (/* */)
    block,
    /// Unknown comment format
    unknown,

    pub fn label(self: CommentType) []const u8 {
        return switch (self) {
            .line => "line comment",
            .doc => "doc comment",
            .block => "block comment",
            .unknown => "comment",
        };
    }
};

/// Detect the type of comment from its content
pub fn detectCommentType(content: []const u8) CommentType {
    const trimmed = std.mem.trimStart(u8, content, " \t");

    // Doc comments (Rust/Zig style)
    if (std.mem.startsWith(u8, trimmed, "///")) return .doc;
    if (std.mem.startsWith(u8, trimmed, "//!")) return .doc;

    // Doc comments (Java/JS style)
    if (std.mem.startsWith(u8, trimmed, "/**")) return .doc;

    // Block comments
    if (std.mem.startsWith(u8, trimmed, "/*")) return .block;

    // Line comments
    if (std.mem.startsWith(u8, trimmed, "//")) return .line;
    if (std.mem.startsWith(u8, trimmed, "#")) return .line;

    // Check for end of block comment
    if (std.mem.endsWith(u8, std.mem.trimEnd(u8, content, " \t\n"), "*/")) return .block;

    return .unknown;
}

/// Check if a diff entry contains only whitespace changes
/// Compares content after stripping whitespace
pub fn isWhitespaceOnly(entry: difft.DiffEntry) bool {
    // Get the full content from both sides by concatenating all changes
    const lhs_content = getFullContentFromSide(entry.lhs);
    const rhs_content = getFullContentFromSide(entry.rhs);

    // If both are empty, no change to compare
    if (lhs_content.len == 0 and rhs_content.len == 0) {
        return false;
    }

    // Compare after stripping whitespace
    return contentEqualIgnoringWhitespace(lhs_content, rhs_content);
}

/// Helper to get the full content from a side (concatenates all change content)
fn getFullContentFromSide(side: ?difft.Side) []const u8 {
    if (side) |s| {
        if (s.changes.len == 0) return "";
        // For simplicity, just return the first change's content
        // In practice, changes rarely span multiple content segments for whitespace
        return s.changes[0].content;
    }
    return "";
}

/// Analyze a diff entry to determine if it's a whitespace-only change
/// Returns a CosmeticAnalysis struct with category, confidence, and details
pub fn analyzeLineForWhitespace(entry: difft.DiffEntry) CosmeticAnalysis {
    const lhs_content = getFullContentFromSide(entry.lhs);
    const rhs_content = getFullContentFromSide(entry.rhs);

    const has_lhs = entry.lhs != null and entry.lhs.?.changes.len > 0;
    const has_rhs = entry.rhs != null and entry.rhs.?.changes.len > 0;

    // If neither side has changes, it's not a whitespace change
    if (!has_lhs and !has_rhs) {
        return CosmeticAnalysis.semantic();
    }

    // Check for blank line added/removed
    if (has_rhs and !has_lhs) {
        if (isBlankOrWhitespaceOnly(rhs_content)) {
            return CosmeticAnalysis.whitespaceOnly(1.0, "blank line added");
        }
        return CosmeticAnalysis.semantic();
    }

    if (has_lhs and !has_rhs) {
        if (isBlankOrWhitespaceOnly(lhs_content)) {
            return CosmeticAnalysis.whitespaceOnly(1.0, "blank line removed");
        }
        return CosmeticAnalysis.semantic();
    }

    // Both sides have content - check if they're equal ignoring whitespace
    if (!contentEqualIgnoringWhitespace(lhs_content, rhs_content)) {
        return CosmeticAnalysis.semantic();
    }

    // Determine the type of whitespace change
    const detail = detectWhitespaceChangeType(lhs_content, rhs_content);
    return CosmeticAnalysis.whitespaceOnly(1.0, detail);
}

/// Check if a string contains only whitespace (or is empty)
fn isBlankOrWhitespaceOnly(content: []const u8) bool {
    for (content) |c| {
        if (!std.ascii.isWhitespace(c)) {
            return false;
        }
    }
    return true;
}

/// Detect the specific type of whitespace change
fn detectWhitespaceChangeType(old: []const u8, new: []const u8) []const u8 {
    // Check for tab vs space conversion
    const old_has_tabs = std.mem.indexOf(u8, old, "\t") != null;
    const new_has_tabs = std.mem.indexOf(u8, new, "\t") != null;
    if (old_has_tabs != new_has_tabs) {
        if (old_has_tabs) {
            return "tabs converted to spaces";
        } else {
            return "spaces converted to tabs";
        }
    }

    // Check for trailing whitespace changes
    const old_trimmed = std.mem.trimEnd(u8, old, " \t");
    const new_trimmed = std.mem.trimEnd(u8, new, " \t");
    if (old_trimmed.len != old.len or new_trimmed.len != new.len) {
        if (old_trimmed.len != old.len and new_trimmed.len == new.len) {
            return "trailing whitespace removed";
        } else if (old_trimmed.len == old.len and new_trimmed.len != new.len) {
            return "trailing whitespace added";
        }
        return "trailing whitespace changed";
    }

    // Check for leading whitespace (indentation) changes
    const old_leading = countLeadingWhitespace(old);
    const new_leading = countLeadingWhitespace(new);
    if (old_leading != new_leading) {
        if (new_leading > old_leading) {
            return "indentation increased";
        } else {
            return "indentation decreased";
        }
    }

    return "whitespace changed";
}

/// Count leading whitespace characters
fn countLeadingWhitespace(content: []const u8) usize {
    var count: usize = 0;
    for (content) |c| {
        if (std.ascii.isWhitespace(c)) {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

/// Compare two strings ignoring all whitespace
fn contentEqualIgnoringWhitespace(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;

    while (ai < a.len and bi < b.len) {
        // Skip whitespace in a
        while (ai < a.len and std.ascii.isWhitespace(a[ai])) {
            ai += 1;
        }
        // Skip whitespace in b
        while (bi < b.len and std.ascii.isWhitespace(b[bi])) {
            bi += 1;
        }

        // If both reached the end, they're equal
        if (ai >= a.len and bi >= b.len) {
            return true;
        }

        // If only one reached the end, they differ
        if (ai >= a.len or bi >= b.len) {
            return false;
        }

        // Compare non-whitespace characters
        if (a[ai] != b[bi]) {
            return false;
        }

        ai += 1;
        bi += 1;
    }

    // Skip remaining whitespace
    while (ai < a.len and std.ascii.isWhitespace(a[ai])) {
        ai += 1;
    }
    while (bi < b.len and std.ascii.isWhitespace(b[bi])) {
        bi += 1;
    }

    return ai >= a.len and bi >= b.len;
}

/// Check if a change is a rename (identifiers changed but structure is the same)
/// Returns true if the code structure is identical after normalizing identifiers
pub fn isRename(
    allocator: Allocator,
    old_content: []const u8,
    new_content: []const u8,
    lang: highlight.Language,
) !bool {
    // First quick check: if contents are identical, it's not a rename
    if (std.mem.eql(u8, old_content, new_content)) {
        return false;
    }

    // If content is identical ignoring whitespace, it's a whitespace change, not a rename
    if (contentEqualIgnoringWhitespace(old_content, new_content)) {
        return false;
    }

    // Try to normalize both versions and compare
    const old_normalized = normalizeIdentifiers(allocator, old_content, lang) catch |err| {
        // If parsing fails, we can't determine if it's a rename
        if (err == error.LanguageNotSupported or err == error.ParserCreationFailed or err == error.ParseFailed) {
            return false;
        }
        return err;
    };
    defer allocator.free(old_normalized);

    const new_normalized = normalizeIdentifiers(allocator, new_content, lang) catch |err| {
        if (err == error.LanguageNotSupported or err == error.ParserCreationFailed or err == error.ParseFailed) {
            return false;
        }
        return err;
    };
    defer allocator.free(new_normalized);

    // If normalized versions are equal (ignoring whitespace), it's a rename
    return contentEqualIgnoringWhitespace(old_normalized, new_normalized);
}

/// Normalize identifiers in source code by replacing them with placeholders
/// This allows comparing code structure while ignoring identifier names
pub fn normalizeIdentifiers(
    allocator: Allocator,
    content: []const u8,
    lang: highlight.Language,
) ![]const u8 {
    // Return empty slice for empty content
    if (content.len == 0) {
        return allocator.dupe(u8, "");
    }

    // Check if content has any meaningful text
    var has_content = false;
    for (content) |ch| {
        if (ch > 32) {
            has_content = true;
            break;
        }
    }
    if (!has_content) {
        return allocator.dupe(u8, content);
    }

    // Get tree-sitter language
    const ts_lang = getTreeSitterLanguage(lang) catch {
        return error.LanguageNotSupported;
    };

    // Create parser
    const parser = treez.Parser.create() catch {
        return error.ParserCreationFailed;
    };
    defer parser.destroy();

    parser.setLanguage(ts_lang) catch {
        return error.ParserCreationFailed;
    };

    // Parse the content
    const tree = parser.parseString(null, content) catch {
        return error.ParseFailed;
    };
    defer tree.destroy();

    // Extract all identifier spans
    var identifiers: std.ArrayList(IdentifierSpan) = .empty;
    defer identifiers.deinit(allocator);

    // Walk the tree to find identifiers
    var cursor = treez.Tree.Cursor.create(tree.getRootNode());
    defer cursor.destroy();

    var reached_root = false;
    while (!reached_root) {
        const node = cursor.getCurrentNode();
        const node_type = node.getType();

        // Check if this is an identifier node
        if (isIdentifierNodeType(node_type)) {
            const start = node.getStartByte();
            const end = node.getEndByte();
            if (start < content.len and end <= content.len and end > start) {
                try identifiers.append(allocator, .{
                    .start = start,
                    .end = end,
                    .name = content[start..end],
                });
            }
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

    // Sort by position (should already be sorted but ensure it)
    std.mem.sort(IdentifierSpan, identifiers.items, {}, struct {
        fn lessThan(_: void, a: IdentifierSpan, b: IdentifierSpan) bool {
            return a.start < b.start;
        }
    }.lessThan);

    // Build normalized string by replacing identifiers with placeholders
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // Map from original identifier name to placeholder ID
    var id_map = std.StringHashMap(u32).init(allocator);
    defer id_map.deinit();

    var next_id: u32 = 0;
    var pos: usize = 0;

    for (identifiers.items) |ident| {
        // Add content before this identifier
        if (ident.start > pos) {
            try result.appendSlice(allocator, content[pos..ident.start]);
        }

        // Get or create placeholder ID for this identifier
        const gop = try id_map.getOrPut(ident.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = next_id;
            next_id += 1;
        }
        const placeholder_id = gop.value_ptr.*;

        // Write placeholder
        var buf: [20]u8 = undefined;
        const placeholder = std.fmt.bufPrint(&buf, "_id{d}", .{placeholder_id}) catch "_id";
        try result.appendSlice(allocator, placeholder);

        pos = ident.end;
    }

    // Add remaining content after the last identifier
    if (pos < content.len) {
        try result.appendSlice(allocator, content[pos..]);
    }

    return result.toOwnedSlice(allocator);
}

/// A span representing an identifier in the source
const IdentifierSpan = struct {
    start: u32,
    end: u32,
    name: []const u8,
};

/// Check if a tree-sitter node type represents an identifier
fn isIdentifierNodeType(node_type: []const u8) bool {
    // Common identifier node types across languages
    return std.mem.eql(u8, node_type, "identifier") or
        std.mem.eql(u8, node_type, "field_identifier") or
        std.mem.eql(u8, node_type, "type_identifier") or
        std.mem.eql(u8, node_type, "property_identifier") or
        std.mem.eql(u8, node_type, "shorthand_property_identifier") or
        std.mem.eql(u8, node_type, "shorthand_property_identifier_pattern") or
        // Rust-specific
        std.mem.eql(u8, node_type, "field_identifier") or
        std.mem.eql(u8, node_type, "type_identifier") or
        // Python-specific
        std.mem.eql(u8, node_type, "identifier") or
        // Go-specific
        std.mem.eql(u8, node_type, "field_identifier") or
        std.mem.eql(u8, node_type, "type_identifier") or
        std.mem.eql(u8, node_type, "package_identifier") or
        // Java-specific
        std.mem.eql(u8, node_type, "identifier") or
        std.mem.eql(u8, node_type, "type_identifier");
}

/// Get tree-sitter language for parsing
fn getTreeSitterLanguage(lang: highlight.Language) !*const treez.Language {
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

/// Extract identifier mappings between old and new versions
/// Returns a list of old_name → new_name mappings
pub fn extractIdentifierMappings(
    allocator: Allocator,
    old_content: []const u8,
    new_content: []const u8,
    lang: highlight.Language,
) ![]IdentifierMapping {
    // Extract identifiers from both versions in order
    var old_identifiers = try extractIdentifiersOrdered(allocator, old_content, lang);
    defer allocator.free(old_identifiers);

    var new_identifiers = try extractIdentifiersOrdered(allocator, new_content, lang);
    defer allocator.free(new_identifiers);

    // If different number of identifiers, can't map
    if (old_identifiers.len != new_identifiers.len) {
        return &[_]IdentifierMapping{};
    }

    // Build mappings for identifiers that changed
    var mappings: std.ArrayList(IdentifierMapping) = .empty;
    errdefer mappings.deinit(allocator);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (old_identifiers, 0..) |old_ident, i| {
        const new_ident = new_identifiers[i];
        if (!std.mem.eql(u8, old_ident, new_ident)) {
            // Only add unique mappings
            const key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ old_ident, new_ident });
            defer allocator.free(key);

            const gop = try seen.getOrPut(key);
            if (!gop.found_existing) {
                // Count occurrences
                var count: u32 = 1;
                for (old_identifiers[i + 1 ..], i + 1..) |other_old, j| {
                    if (j < new_identifiers.len and
                        std.mem.eql(u8, other_old, old_ident) and
                        std.mem.eql(u8, new_identifiers[j], new_ident))
                    {
                        count += 1;
                    }
                }

                try mappings.append(allocator, .{
                    .old_name = try allocator.dupe(u8, old_ident),
                    .new_name = try allocator.dupe(u8, new_ident),
                    .count = count,
                });
            }
        }
    }

    return mappings.toOwnedSlice(allocator);
}

/// Extract all identifiers from source in order of appearance
fn extractIdentifiersOrdered(
    allocator: Allocator,
    content: []const u8,
    lang: highlight.Language,
) ![][]const u8 {
    if (content.len == 0) {
        return &[_][]const u8{};
    }

    // Get tree-sitter language
    const ts_lang = getTreeSitterLanguage(lang) catch {
        return &[_][]const u8{};
    };

    // Create parser
    const parser = treez.Parser.create() catch {
        return &[_][]const u8{};
    };
    defer parser.destroy();

    parser.setLanguage(ts_lang) catch {
        return &[_][]const u8{};
    };

    // Parse the content
    const tree = parser.parseString(null, content) catch {
        return &[_][]const u8{};
    };
    defer tree.destroy();

    // Extract all identifier names in order
    var identifiers: std.ArrayList(IdentifierSpan) = .empty;
    defer identifiers.deinit(allocator);

    // Walk the tree to find identifiers
    var cursor = treez.Tree.Cursor.create(tree.getRootNode());
    defer cursor.destroy();

    var reached_root = false;
    while (!reached_root) {
        const node = cursor.getCurrentNode();
        const node_type = node.getType();

        if (isIdentifierNodeType(node_type)) {
            const start = node.getStartByte();
            const end = node.getEndByte();
            if (start < content.len and end <= content.len and end > start) {
                try identifiers.append(allocator, .{
                    .start = start,
                    .end = end,
                    .name = content[start..end],
                });
            }
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

    // Sort by position
    std.mem.sort(IdentifierSpan, identifiers.items, {}, struct {
        fn lessThan(_: void, a: IdentifierSpan, b: IdentifierSpan) bool {
            return a.start < b.start;
        }
    }.lessThan);

    // Extract just the names in order
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(allocator);

    for (identifiers.items) |ident| {
        try result.append(allocator, ident.name);
    }

    return result.toOwnedSlice(allocator);
}

/// Analyze a diff entry to determine if it's a rename
/// Returns a CosmeticAnalysis with details about what was renamed
pub fn analyzeLineForRename(
    allocator: Allocator,
    entry: difft.DiffEntry,
    old_full_content: ?[]const u8,
    new_full_content: ?[]const u8,
    lang: highlight.Language,
) !CosmeticAnalysis {
    // Get the content from both sides
    const lhs_content = getFullContentFromSide(entry.lhs);
    const rhs_content = getFullContentFromSide(entry.rhs);

    // Need both sides to detect a rename
    if (lhs_content.len == 0 or rhs_content.len == 0) {
        return CosmeticAnalysis.semantic();
    }

    // Use full content if available, otherwise use just the line content
    const old_to_check = old_full_content orelse lhs_content;
    const new_to_check = new_full_content orelse rhs_content;

    // Check if it's a rename
    if (try isRename(allocator, old_to_check, new_to_check, lang)) {
        // Try to extract the first mapping to show what was renamed
        const mappings = try extractIdentifierMappings(allocator, old_to_check, new_to_check, lang);
        defer {
            for (mappings) |m| {
                allocator.free(m.old_name);
                allocator.free(m.new_name);
            }
            allocator.free(mappings);
        }

        if (mappings.len > 0) {
            return CosmeticAnalysis.renameChange(1.0, mappings[0].old_name, mappings[0].new_name);
        }
        return CosmeticAnalysis.renameChange(0.9, null, null);
    }

    return CosmeticAnalysis.semantic();
}

/// Free identifier mappings
pub fn freeIdentifierMappings(allocator: Allocator, mappings: []IdentifierMapping) void {
    for (mappings) |m| {
        allocator.free(m.old_name);
        allocator.free(m.new_name);
    }
    allocator.free(mappings);
}

/// Find moved constructs between old and new versions (stub - to be implemented in n5n5jkj2)
pub fn findMovedConstructs(
    allocator: Allocator,
    old_regions: []const collapse.CollapsibleRegion,
    new_regions: []const collapse.CollapsibleRegion,
    old_content: []const u8,
    new_content: []const u8,
) ![]MovedConstruct {
    _ = allocator;
    _ = old_regions;
    _ = new_regions;
    _ = old_content;
    _ = new_content;
    // TODO: Implement in task n5n5jkj2
    return &[_]MovedConstruct{};
}

/// Compare two construct bodies and return a similarity score (stub - to be implemented in n5n5jkj2)
pub fn compareConstructBodies(old_body: []const u8, new_body: []const u8) f32 {
    _ = old_body;
    _ = new_body;
    // TODO: Implement in task n5n5jkj2
    return 0.0;
}

/// Strip all whitespace from content (allocates new string)
pub fn stripWhitespace(allocator: Allocator, content: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (content) |c| {
        if (!std.ascii.isWhitespace(c)) {
            try result.append(allocator, c);
        }
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "ChangeCategory.isCosmetic returns true for cosmetic categories" {
    try std.testing.expect(ChangeCategory.comment.isCosmetic());
    try std.testing.expect(ChangeCategory.whitespace.isCosmetic());
    try std.testing.expect(ChangeCategory.rename.isCosmetic());
    try std.testing.expect(ChangeCategory.moved.isCosmetic());
    try std.testing.expect(!ChangeCategory.semantic.isCosmetic());
}

test "ChangeCategory.label returns correct labels" {
    try std.testing.expectEqualStrings("comment", ChangeCategory.comment.label());
    try std.testing.expectEqualStrings("semantic", ChangeCategory.semantic.label());
}

test "CosmeticAnalysis.semantic creates semantic result" {
    const analysis = CosmeticAnalysis.semantic();
    try std.testing.expectEqual(ChangeCategory.semantic, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
}

test "CosmeticAnalysis.commentOnly creates comment result" {
    const analysis = CosmeticAnalysis.commentOnly(0.9, "test details");
    try std.testing.expectEqual(ChangeCategory.comment, analysis.category);
    try std.testing.expectEqual(@as(f32, 0.9), analysis.confidence);
    try std.testing.expectEqualStrings("test details", analysis.details.?);
}

test "CosmeticAnalysis.renameChange stores old and new names" {
    const analysis = CosmeticAnalysis.renameChange(0.85, "foo", "bar");
    try std.testing.expectEqual(ChangeCategory.rename, analysis.category);
    try std.testing.expectEqualStrings("foo", analysis.old_name.?);
    try std.testing.expectEqualStrings("bar", analysis.new_name.?);
}

test "CosmeticAnalysis.movedConstruct stores line numbers" {
    const analysis = CosmeticAnalysis.movedConstruct(0.95, 10, 50);
    try std.testing.expectEqual(ChangeCategory.moved, analysis.category);
    try std.testing.expectEqual(@as(u32, 10), analysis.moved_from_line.?);
    try std.testing.expectEqual(@as(u32, 50), analysis.moved_to_line.?);
}

test "CosmeticConfig.default has expected values" {
    const config = CosmeticConfig.default();
    try std.testing.expectEqual(@as(f32, 0.8), config.min_confidence);
    try std.testing.expect(config.detect_comments);
    try std.testing.expect(config.detect_whitespace);
    try std.testing.expect(config.detect_renames);
    try std.testing.expect(config.detect_moved);
}

test "CosmeticConfig.strict has higher thresholds" {
    const config = CosmeticConfig.strict();
    try std.testing.expectEqual(@as(f32, 0.95), config.min_confidence);
    try std.testing.expectEqual(@as(f32, 0.99), config.move_similarity_threshold);
}

test "contentEqualIgnoringWhitespace returns true for same content" {
    try std.testing.expect(contentEqualIgnoringWhitespace("abc", "abc"));
    try std.testing.expect(contentEqualIgnoringWhitespace("a b c", "abc"));
    try std.testing.expect(contentEqualIgnoringWhitespace("  abc  ", "abc"));
    try std.testing.expect(contentEqualIgnoringWhitespace("a\tb\nc", "abc"));
}

test "contentEqualIgnoringWhitespace returns false for different content" {
    try std.testing.expect(!contentEqualIgnoringWhitespace("abc", "abd"));
    try std.testing.expect(!contentEqualIgnoringWhitespace("abc", "abcd"));
    try std.testing.expect(!contentEqualIgnoringWhitespace("abc", "ab"));
}

test "stripWhitespace removes all whitespace" {
    const allocator = std.testing.allocator;

    const result1 = try stripWhitespace(allocator, "  hello  world  ");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("helloworld", result1);

    const result2 = try stripWhitespace(allocator, "a\tb\nc");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("abc", result2);

    const result3 = try stripWhitespace(allocator, "");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("", result3);
}

test "isCommentOnly returns true when all changes are comments" {
    // Create a diff entry with only comment changes
    const comment_change = difft.Change{
        .start = 0,
        .end = 10,
        .content = "// comment",
        .highlight = .comment,
    };
    const changes = [_]difft.Change{comment_change};

    const entry = difft.DiffEntry{
        .lhs = null,
        .rhs = .{
            .line_number = 1,
            .changes = &changes,
        },
    };

    try std.testing.expect(isCommentOnly(entry));
}

test "isCommentOnly returns false when changes include non-comments" {
    const comment_change = difft.Change{
        .start = 0,
        .end = 10,
        .content = "// comment",
        .highlight = .comment,
    };
    const code_change = difft.Change{
        .start = 0,
        .end = 5,
        .content = "code",
        .highlight = .normal,
    };
    const changes = [_]difft.Change{ comment_change, code_change };

    const entry = difft.DiffEntry{
        .lhs = null,
        .rhs = .{
            .line_number = 1,
            .changes = &changes,
        },
    };

    try std.testing.expect(!isCommentOnly(entry));
}

test "isCommentOnly returns false for empty changes" {
    const entry = difft.DiffEntry{
        .lhs = null,
        .rhs = null,
    };

    try std.testing.expect(!isCommentOnly(entry));
}

test "isWhitespaceOnly returns true for indentation-only change" {
    const lhs_change = difft.Change{
        .start = 0,
        .end = 4,
        .content = "    code",
        .highlight = .normal,
    };
    const rhs_change = difft.Change{
        .start = 0,
        .end = 2,
        .content = "  code",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 1,
            .changes = &[_]difft.Change{lhs_change},
        },
        .rhs = .{
            .line_number = 1,
            .changes = &[_]difft.Change{rhs_change},
        },
    };

    try std.testing.expect(isWhitespaceOnly(entry));
}

test "isWhitespaceOnly returns false for content change" {
    const lhs_change = difft.Change{
        .start = 0,
        .end = 3,
        .content = "foo",
        .highlight = .normal,
    };
    const rhs_change = difft.Change{
        .start = 0,
        .end = 3,
        .content = "bar",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 1,
            .changes = &[_]difft.Change{lhs_change},
        },
        .rhs = .{
            .line_number = 1,
            .changes = &[_]difft.Change{rhs_change},
        },
    };

    try std.testing.expect(!isWhitespaceOnly(entry));
}

// ============================================================================
// Comment-only detection tests (task e3kylg09)
// ============================================================================

test "isChangesArrayCommentOnly returns true for comment-only array" {
    const changes = [_]difft.Change{
        .{ .start = 0, .end = 10, .content = "// hello", .highlight = .comment },
        .{ .start = 11, .end = 20, .content = "// world", .highlight = .comment },
    };
    try std.testing.expect(isChangesArrayCommentOnly(&changes));
}

test "isChangesArrayCommentOnly returns false for mixed array" {
    const changes = [_]difft.Change{
        .{ .start = 0, .end = 10, .content = "// hello", .highlight = .comment },
        .{ .start = 11, .end = 20, .content = "code", .highlight = .normal },
    };
    try std.testing.expect(!isChangesArrayCommentOnly(&changes));
}

test "isChangesArrayCommentOnly returns false for empty array" {
    const changes = [_]difft.Change{};
    try std.testing.expect(!isChangesArrayCommentOnly(&changes));
}

test "analyzeLineForComments detects comment added" {
    const comment_change = difft.Change{
        .start = 0,
        .end = 15,
        .content = "// new comment",
        .highlight = .comment,
    };

    const entry = difft.DiffEntry{
        .lhs = null,
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{comment_change},
        },
    };

    const analysis = analyzeLineForComments(entry);
    try std.testing.expectEqual(ChangeCategory.comment, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("comment added", analysis.details.?);
}

test "analyzeLineForComments detects comment removed" {
    const comment_change = difft.Change{
        .start = 0,
        .end = 15,
        .content = "// old comment",
        .highlight = .comment,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{comment_change},
        },
        .rhs = null,
    };

    const analysis = analyzeLineForComments(entry);
    try std.testing.expectEqual(ChangeCategory.comment, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("comment removed", analysis.details.?);
}

test "analyzeLineForComments detects comment modified" {
    const old_comment = difft.Change{
        .start = 0,
        .end = 10,
        .content = "// old",
        .highlight = .comment,
    };
    const new_comment = difft.Change{
        .start = 0,
        .end = 10,
        .content = "// new",
        .highlight = .comment,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{old_comment},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{new_comment},
        },
    };

    const analysis = analyzeLineForComments(entry);
    try std.testing.expectEqual(ChangeCategory.comment, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("comment modified", analysis.details.?);
}

test "analyzeLineForComments returns semantic for code AND comment changed" {
    const comment_change = difft.Change{
        .start = 0,
        .end = 10,
        .content = "// comment",
        .highlight = .comment,
    };
    const code_change = difft.Change{
        .start = 0,
        .end = 10,
        .content = "let x = 1",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{comment_change},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{code_change},
        },
    };

    const analysis = analyzeLineForComments(entry);
    try std.testing.expectEqual(ChangeCategory.semantic, analysis.category);
}

test "analyzeLineForComments returns semantic for no changes" {
    const entry = difft.DiffEntry{
        .lhs = null,
        .rhs = null,
    };

    const analysis = analyzeLineForComments(entry);
    try std.testing.expectEqual(ChangeCategory.semantic, analysis.category);
}

test "analyzeLineForComments returns semantic for empty changes" {
    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 1,
            .changes = &[_]difft.Change{},
        },
        .rhs = .{
            .line_number = 1,
            .changes = &[_]difft.Change{},
        },
    };

    const analysis = analyzeLineForComments(entry);
    try std.testing.expectEqual(ChangeCategory.semantic, analysis.category);
}

test "detectCommentType identifies line comments" {
    try std.testing.expectEqual(CommentType.line, detectCommentType("// hello"));
    try std.testing.expectEqual(CommentType.line, detectCommentType("  // indented"));
    try std.testing.expectEqual(CommentType.line, detectCommentType("# python style"));
}

test "detectCommentType identifies doc comments" {
    try std.testing.expectEqual(CommentType.doc, detectCommentType("/// doc comment"));
    try std.testing.expectEqual(CommentType.doc, detectCommentType("//! module doc"));
    try std.testing.expectEqual(CommentType.doc, detectCommentType("/** javadoc"));
}

test "detectCommentType identifies block comments" {
    try std.testing.expectEqual(CommentType.block, detectCommentType("/* block */"));
    try std.testing.expectEqual(CommentType.block, detectCommentType("  /* indented"));
    try std.testing.expectEqual(CommentType.block, detectCommentType("end of block */"));
}

test "detectCommentType returns unknown for non-comments" {
    try std.testing.expectEqual(CommentType.unknown, detectCommentType("not a comment"));
    try std.testing.expectEqual(CommentType.unknown, detectCommentType("x = 1"));
}

// ============================================================================
// Whitespace-only detection tests (task 0ljqfg96)
// ============================================================================

test "analyzeLineForWhitespace detects blank line added" {
    const blank_change = difft.Change{
        .start = 0,
        .end = 0,
        .content = "   ",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = null,
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{blank_change},
        },
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.whitespace, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("blank line added", analysis.details.?);
}

test "analyzeLineForWhitespace detects blank line removed" {
    const blank_change = difft.Change{
        .start = 0,
        .end = 0,
        .content = "",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{blank_change},
        },
        .rhs = null,
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.whitespace, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("blank line removed", analysis.details.?);
}

test "analyzeLineForWhitespace detects indentation increase" {
    const old_change = difft.Change{
        .start = 0,
        .end = 6,
        .content = "  code",
        .highlight = .normal,
    };
    const new_change = difft.Change{
        .start = 0,
        .end = 8,
        .content = "    code",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{old_change},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{new_change},
        },
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.whitespace, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("indentation increased", analysis.details.?);
}

test "analyzeLineForWhitespace detects indentation decrease" {
    const old_change = difft.Change{
        .start = 0,
        .end = 8,
        .content = "    code",
        .highlight = .normal,
    };
    const new_change = difft.Change{
        .start = 0,
        .end = 6,
        .content = "  code",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{old_change},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{new_change},
        },
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.whitespace, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("indentation decreased", analysis.details.?);
}

test "analyzeLineForWhitespace detects tabs to spaces conversion" {
    const old_change = difft.Change{
        .start = 0,
        .end = 5,
        .content = "\tcode",
        .highlight = .normal,
    };
    const new_change = difft.Change{
        .start = 0,
        .end = 8,
        .content = "    code",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{old_change},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{new_change},
        },
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.whitespace, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("tabs converted to spaces", analysis.details.?);
}

test "analyzeLineForWhitespace detects spaces to tabs conversion" {
    const old_change = difft.Change{
        .start = 0,
        .end = 8,
        .content = "    code",
        .highlight = .normal,
    };
    const new_change = difft.Change{
        .start = 0,
        .end = 5,
        .content = "\tcode",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{old_change},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{new_change},
        },
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.whitespace, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("spaces converted to tabs", analysis.details.?);
}

test "analyzeLineForWhitespace detects trailing whitespace removed" {
    const old_change = difft.Change{
        .start = 0,
        .end = 8,
        .content = "code    ",
        .highlight = .normal,
    };
    const new_change = difft.Change{
        .start = 0,
        .end = 4,
        .content = "code",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{old_change},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{new_change},
        },
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.whitespace, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("trailing whitespace removed", analysis.details.?);
}

test "analyzeLineForWhitespace detects trailing whitespace added" {
    const old_change = difft.Change{
        .start = 0,
        .end = 4,
        .content = "code",
        .highlight = .normal,
    };
    const new_change = difft.Change{
        .start = 0,
        .end = 8,
        .content = "code    ",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{old_change},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{new_change},
        },
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.whitespace, analysis.category);
    try std.testing.expectEqual(@as(f32, 1.0), analysis.confidence);
    try std.testing.expectEqualStrings("trailing whitespace added", analysis.details.?);
}

test "analyzeLineForWhitespace returns semantic for code change" {
    const old_change = difft.Change{
        .start = 0,
        .end = 3,
        .content = "foo",
        .highlight = .normal,
    };
    const new_change = difft.Change{
        .start = 0,
        .end = 3,
        .content = "bar",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{old_change},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{new_change},
        },
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.semantic, analysis.category);
}

test "analyzeLineForWhitespace returns semantic for no changes" {
    const entry = difft.DiffEntry{
        .lhs = null,
        .rhs = null,
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.semantic, analysis.category);
}

test "analyzeLineForWhitespace returns semantic for content addition" {
    const new_change = difft.Change{
        .start = 0,
        .end = 10,
        .content = "let x = 1;",
        .highlight = .normal,
    };

    const entry = difft.DiffEntry{
        .lhs = null,
        .rhs = .{
            .line_number = 5,
            .changes = &[_]difft.Change{new_change},
        },
    };

    const analysis = analyzeLineForWhitespace(entry);
    try std.testing.expectEqual(ChangeCategory.semantic, analysis.category);
}

test "isBlankOrWhitespaceOnly returns true for empty string" {
    try std.testing.expect(isBlankOrWhitespaceOnly(""));
}

test "isBlankOrWhitespaceOnly returns true for whitespace-only" {
    try std.testing.expect(isBlankOrWhitespaceOnly("   "));
    try std.testing.expect(isBlankOrWhitespaceOnly("\t\t"));
    try std.testing.expect(isBlankOrWhitespaceOnly(" \t \n "));
}

test "isBlankOrWhitespaceOnly returns false for content" {
    try std.testing.expect(!isBlankOrWhitespaceOnly("code"));
    try std.testing.expect(!isBlankOrWhitespaceOnly("  code  "));
}

test "countLeadingWhitespace counts correctly" {
    try std.testing.expectEqual(@as(usize, 0), countLeadingWhitespace("code"));
    try std.testing.expectEqual(@as(usize, 2), countLeadingWhitespace("  code"));
    try std.testing.expectEqual(@as(usize, 4), countLeadingWhitespace("    code"));
    try std.testing.expectEqual(@as(usize, 1), countLeadingWhitespace("\tcode"));
    try std.testing.expectEqual(@as(usize, 3), countLeadingWhitespace("   "));
}

// ============================================================================
// Rename detection tests (task hi4eluj3)
// ============================================================================

test "isRename returns false for identical content" {
    const allocator = std.testing.allocator;
    const content = "const foo = 42;";
    const result = try isRename(allocator, content, content, .zig);
    try std.testing.expect(!result);
}

test "isRename returns false for whitespace-only changes" {
    const allocator = std.testing.allocator;
    const old = "const foo = 42;";
    const new = "const  foo  =  42;";
    const result = try isRename(allocator, old, new, .zig);
    try std.testing.expect(!result);
}

test "isRename detects simple variable rename" {
    const allocator = std.testing.allocator;
    const old = "const foo = 42;";
    const new = "const bar = 42;";
    const result = try isRename(allocator, old, new, .zig);
    try std.testing.expect(result);
}

test "isRename detects function parameter rename" {
    const allocator = std.testing.allocator;
    const old = "fn process(value: u32) void { _ = value; }";
    const new = "fn process(count: u32) void { _ = count; }";
    const result = try isRename(allocator, old, new, .zig);
    try std.testing.expect(result);
}

test "isRename detects multiple renames in same code" {
    const allocator = std.testing.allocator;
    const old = "const foo = bar + baz;";
    const new = "const x = y + z;";
    const result = try isRename(allocator, old, new, .zig);
    try std.testing.expect(result);
}

test "isRename returns false for logic change" {
    const allocator = std.testing.allocator;
    const old = "const foo = bar + baz;";
    const new = "const foo = bar * baz;"; // Changed + to *
    const result = try isRename(allocator, old, new, .zig);
    try std.testing.expect(!result);
}

test "isRename returns false for added code" {
    const allocator = std.testing.allocator;
    const old = "const foo = 42;";
    const new = "const foo = 42; const bar = 10;";
    const result = try isRename(allocator, old, new, .zig);
    try std.testing.expect(!result);
}

test "isRename returns false for unsupported language" {
    const allocator = std.testing.allocator;
    const old = "foo: bar";
    const new = "baz: qux";
    // YAML identifiers aren't parsed the same way
    const result = try isRename(allocator, old, new, .yaml);
    // Should return false gracefully for unsupported/unparseable content
    try std.testing.expect(!result);
}

test "normalizeIdentifiers replaces identifiers with placeholders" {
    const allocator = std.testing.allocator;
    const source = "const foo = bar;";
    const normalized = try normalizeIdentifiers(allocator, source, .zig);
    defer allocator.free(normalized);

    // foo should become _id0, bar should become _id1
    // The exact output depends on tree-sitter parsing, but should contain _id
    try std.testing.expect(std.mem.indexOf(u8, normalized, "_id") != null);
    // Original identifiers should not be present
    try std.testing.expect(std.mem.indexOf(u8, normalized, "foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, normalized, "bar") == null);
}

test "normalizeIdentifiers handles empty content" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeIdentifiers(allocator, "", .zig);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("", normalized);
}

test "normalizeIdentifiers handles whitespace-only content" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeIdentifiers(allocator, "   \n\t  ", .zig);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("   \n\t  ", normalized);
}

test "normalizeIdentifiers produces consistent output for same identifier" {
    const allocator = std.testing.allocator;
    // Same identifier used multiple times should get same placeholder
    const source = "const foo = foo + foo;";
    const normalized = try normalizeIdentifiers(allocator, source, .zig);
    defer allocator.free(normalized);

    // Count occurrences of _id0
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOf(u8, normalized[i..], "_id0")) |pos| {
        count += 1;
        i = i + pos + 4;
    }
    // foo appears 3 times, so _id0 should appear 3 times
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "extractIdentifierMappings finds renamed identifiers" {
    const allocator = std.testing.allocator;
    const old = "const foo = 42;";
    const new = "const bar = 42;";

    const mappings = try extractIdentifierMappings(allocator, old, new, .zig);
    defer freeIdentifierMappings(allocator, mappings);

    // Should find the foo -> bar mapping
    try std.testing.expect(mappings.len >= 1);

    var found_rename = false;
    for (mappings) |m| {
        if (std.mem.eql(u8, m.old_name, "foo") and std.mem.eql(u8, m.new_name, "bar")) {
            found_rename = true;
            break;
        }
    }
    try std.testing.expect(found_rename);
}

test "extractIdentifierMappings returns empty for different structure" {
    const allocator = std.testing.allocator;
    const old = "const foo = 42;";
    const new = "const bar = baz + 42;"; // Different number of identifiers

    const mappings = try extractIdentifierMappings(allocator, old, new, .zig);
    defer freeIdentifierMappings(allocator, mappings);

    // Should return empty since structure differs
    try std.testing.expectEqual(@as(usize, 0), mappings.len);
}

test "isIdentifierNodeType recognizes common identifier types" {
    try std.testing.expect(isIdentifierNodeType("identifier"));
    try std.testing.expect(isIdentifierNodeType("field_identifier"));
    try std.testing.expect(isIdentifierNodeType("type_identifier"));
    try std.testing.expect(!isIdentifierNodeType("function_declaration"));
    try std.testing.expect(!isIdentifierNodeType("string"));
}

test "isRename with function rename" {
    const allocator = std.testing.allocator;
    const old =
        \\fn processData(input: []const u8) void {
        \\    _ = input;
        \\}
    ;
    const new =
        \\fn handleData(input: []const u8) void {
        \\    _ = input;
        \\}
    ;
    const result = try isRename(allocator, old, new, .zig);
    try std.testing.expect(result);
}

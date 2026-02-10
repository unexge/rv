const std = @import("std");
const Allocator = std.mem.Allocator;
const difft = @import("difft.zig");
const highlight = @import("highlight.zig");
const collapse = @import("collapse.zig");

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
    const trimmed = std.mem.trimLeft(u8, content, " \t");

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
    if (std.mem.endsWith(u8, std.mem.trimRight(u8, content, " \t\n"), "*/")) return .block;

    return .unknown;
}

/// Check if a diff entry contains only whitespace changes
/// Compares content after stripping whitespace
pub fn isWhitespaceOnly(entry: difft.DiffEntry) bool {
    // Get the full content from both sides
    const lhs_content = if (entry.lhs) |lhs| blk: {
        var result: []const u8 = "";
        for (lhs.changes) |change| {
            result = if (result.len == 0) change.content else result;
        }
        break :blk result;
    } else "";

    const rhs_content = if (entry.rhs) |rhs| blk: {
        var result: []const u8 = "";
        for (rhs.changes) |change| {
            result = if (result.len == 0) change.content else result;
        }
        break :blk result;
    } else "";

    // If both are empty, no change to compare
    if (lhs_content.len == 0 and rhs_content.len == 0) {
        return false;
    }

    // Compare after stripping whitespace
    return contentEqualIgnoringWhitespace(lhs_content, rhs_content);
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

/// Check if a change is a rename (stub - to be implemented in hi4eluj3)
pub fn isRename(
    allocator: Allocator,
    old_content: []const u8,
    new_content: []const u8,
    lang: highlight.Language,
) !bool {
    _ = allocator;
    _ = old_content;
    _ = new_content;
    _ = lang;
    // TODO: Implement in task hi4eluj3
    return false;
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
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    for (content) |c| {
        if (!std.ascii.isWhitespace(c)) {
            try result.append(c);
        }
    }

    return result.toOwnedSlice();
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

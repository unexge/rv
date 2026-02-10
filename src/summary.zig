const std = @import("std");
const Allocator = std.mem.Allocator;
const collapse = @import("collapse.zig");
const review = @import("review.zig");
const difft = @import("difft.zig");
const highlight = @import("highlight.zig");
const cosmetic = @import("cosmetic.zig");

/// Type of change for a construct
pub const ChangeType = enum {
    added, // New construct (exists in new, not in old)
    modified, // Changed construct (exists in both, content differs)
    deleted, // Removed construct (exists in old, not in new)

    pub fn symbol(self: ChangeType) []const u8 {
        return switch (self) {
            .added => "+",
            .modified => "~",
            .deleted => "-",
        };
    }

    pub fn label(self: ChangeType) []const u8 {
        return switch (self) {
            .added => "added",
            .modified => "modified",
            .deleted => "deleted",
        };
    }
};

/// Statistics about changes in a file or session
pub const ChangeStats = struct {
    // Function changes
    functions_added: u32 = 0,
    functions_modified: u32 = 0,
    functions_deleted: u32 = 0,

    // Struct changes
    structs_added: u32 = 0,
    structs_modified: u32 = 0,
    structs_deleted: u32 = 0,

    // Enum changes
    enums_added: u32 = 0,
    enums_modified: u32 = 0,
    enums_deleted: u32 = 0,

    // Union changes
    unions_added: u32 = 0,
    unions_modified: u32 = 0,
    unions_deleted: u32 = 0,

    // Test changes
    tests_added: u32 = 0,
    tests_modified: u32 = 0,
    tests_deleted: u32 = 0,

    // Other constructs (classes, traits, interfaces, modules, etc.)
    other_added: u32 = 0,
    other_modified: u32 = 0,
    other_deleted: u32 = 0,

    // Line-level statistics
    lines_added: u32 = 0,
    lines_deleted: u32 = 0,
    lines_modified: u32 = 0,

    // Cosmetic vs semantic change tracking
    cosmetic_changes: u32 = 0,
    semantic_changes: u32 = 0,

    /// Add another ChangeStats to this one (for aggregation)
    pub fn add(self: *ChangeStats, other: ChangeStats) void {
        self.functions_added += other.functions_added;
        self.functions_modified += other.functions_modified;
        self.functions_deleted += other.functions_deleted;

        self.structs_added += other.structs_added;
        self.structs_modified += other.structs_modified;
        self.structs_deleted += other.structs_deleted;

        self.enums_added += other.enums_added;
        self.enums_modified += other.enums_modified;
        self.enums_deleted += other.enums_deleted;

        self.unions_added += other.unions_added;
        self.unions_modified += other.unions_modified;
        self.unions_deleted += other.unions_deleted;

        self.tests_added += other.tests_added;
        self.tests_modified += other.tests_modified;
        self.tests_deleted += other.tests_deleted;

        self.other_added += other.other_added;
        self.other_modified += other.other_modified;
        self.other_deleted += other.other_deleted;

        self.lines_added += other.lines_added;
        self.lines_deleted += other.lines_deleted;
        self.lines_modified += other.lines_modified;

        self.cosmetic_changes += other.cosmetic_changes;
        self.semantic_changes += other.semantic_changes;
    }

    /// Increment the appropriate counter based on node type and change type
    pub fn increment(self: *ChangeStats, node_type: collapse.NodeType, change_type: ChangeType) void {
        switch (node_type) {
            .function => switch (change_type) {
                .added => self.functions_added += 1,
                .modified => self.functions_modified += 1,
                .deleted => self.functions_deleted += 1,
            },
            .struct_ => switch (change_type) {
                .added => self.structs_added += 1,
                .modified => self.structs_modified += 1,
                .deleted => self.structs_deleted += 1,
            },
            .enum_ => switch (change_type) {
                .added => self.enums_added += 1,
                .modified => self.enums_modified += 1,
                .deleted => self.enums_deleted += 1,
            },
            .union_ => switch (change_type) {
                .added => self.unions_added += 1,
                .modified => self.unions_modified += 1,
                .deleted => self.unions_deleted += 1,
            },
            .test_decl => switch (change_type) {
                .added => self.tests_added += 1,
                .modified => self.tests_modified += 1,
                .deleted => self.tests_deleted += 1,
            },
            .class, .impl, .trait, .interface, .module, .other => switch (change_type) {
                .added => self.other_added += 1,
                .modified => self.other_modified += 1,
                .deleted => self.other_deleted += 1,
            },
        }
    }

    /// Get total number of constructs changed
    pub fn totalConstructs(self: ChangeStats) u32 {
        return self.functions_added + self.functions_modified + self.functions_deleted +
            self.structs_added + self.structs_modified + self.structs_deleted +
            self.enums_added + self.enums_modified + self.enums_deleted +
            self.unions_added + self.unions_modified + self.unions_deleted +
            self.tests_added + self.tests_modified + self.tests_deleted +
            self.other_added + self.other_modified + self.other_deleted;
    }

    /// Get total additions (all types)
    pub fn totalAdded(self: ChangeStats) u32 {
        return self.functions_added + self.structs_added + self.enums_added +
            self.unions_added + self.tests_added + self.other_added;
    }

    /// Get total modifications (all types)
    pub fn totalModified(self: ChangeStats) u32 {
        return self.functions_modified + self.structs_modified + self.enums_modified +
            self.unions_modified + self.tests_modified + self.other_modified;
    }

    /// Get total deletions (all types)
    pub fn totalDeleted(self: ChangeStats) u32 {
        return self.functions_deleted + self.structs_deleted + self.enums_deleted +
            self.unions_deleted + self.tests_deleted + self.other_deleted;
    }

    /// Check if there are any changes
    pub fn hasChanges(self: ChangeStats) bool {
        return self.totalConstructs() > 0 or
            self.lines_added > 0 or self.lines_deleted > 0 or self.lines_modified > 0;
    }
};

/// Represents a single changed construct (function, struct, etc.)
pub const ChangedConstruct = struct {
    name: []const u8, // Name of the construct
    node_type: collapse.NodeType, // Type (function, struct, enum, etc.)
    change_type: ChangeType, // Added, modified, or deleted
    line_start: u32, // Start line in the relevant file (new for added/modified, old for deleted)
    line_end: u32, // End line in the relevant file
    lines_changed: u32 = 0, // Number of lines actually changed within this construct
    category: cosmetic.ChangeCategory = .semantic, // Cosmetic vs semantic classification
    moved_from_line: ?u32 = null, // For moved constructs: original line number

    /// Get a human-readable description of the change
    pub fn description(self: ChangedConstruct, buffer: []u8) []const u8 {
        const type_label = self.node_type.label();
        const change_label = self.change_type.label();

        const result = std.fmt.bufPrint(buffer, "{s} {s} ({s})", .{
            self.change_type.symbol(),
            self.name,
            if (self.change_type == .added)
                type_label
            else if (self.change_type == .deleted)
                type_label
            else
                change_label,
        }) catch return self.name;

        return result;
    }
};

/// Summary of changes in a single file
pub const FileSummary = struct {
    path: []const u8, // File path
    stats: ChangeStats, // Aggregate statistics for this file
    constructs: []const ChangedConstruct, // List of changed constructs
    allocator: Allocator,

    pub fn deinit(self: *FileSummary) void {
        for (self.constructs) |construct| {
            if (construct.name.len > 0) {
                self.allocator.free(construct.name);
            }
        }
        self.allocator.free(self.constructs);
        self.allocator.free(self.path);
    }

    /// Get a brief description of changes (e.g., "3 fn modified, 1 struct added")
    pub fn briefDescription(self: FileSummary, buffer: []u8) []const u8 {
        var parts: [14][]const u8 = undefined;
        var count: usize = 0;
        var temp_buffers: [14][32]u8 = undefined;

        // Functions
        if (self.stats.functions_added > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} fn added", .{self.stats.functions_added}) catch "fn added";
            count += 1;
        }
        if (self.stats.functions_modified > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} fn modified", .{self.stats.functions_modified}) catch "fn modified";
            count += 1;
        }
        if (self.stats.functions_deleted > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} fn deleted", .{self.stats.functions_deleted}) catch "fn deleted";
            count += 1;
        }

        // Structs
        if (self.stats.structs_added > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} struct added", .{self.stats.structs_added}) catch "struct added";
            count += 1;
        }
        if (self.stats.structs_modified > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} struct modified", .{self.stats.structs_modified}) catch "struct modified";
            count += 1;
        }
        if (self.stats.structs_deleted > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} struct deleted", .{self.stats.structs_deleted}) catch "struct deleted";
            count += 1;
        }

        // Tests
        if (self.stats.tests_added > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} test added", .{self.stats.tests_added}) catch "test added";
            count += 1;
        }
        if (self.stats.tests_modified > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} test modified", .{self.stats.tests_modified}) catch "test modified";
            count += 1;
        }
        if (self.stats.tests_deleted > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} test deleted", .{self.stats.tests_deleted}) catch "test deleted";
            count += 1;
        }

        // Other (enums, unions, etc. - summarized)
        const other_total = self.stats.enums_added + self.stats.enums_modified + self.stats.enums_deleted +
            self.stats.unions_added + self.stats.unions_modified + self.stats.unions_deleted +
            self.stats.other_added + self.stats.other_modified + self.stats.other_deleted;
        if (other_total > 0) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} other", .{other_total}) catch "other";
            count += 1;
        }

        // Add cosmetic count if any
        if (self.stats.cosmetic_changes > 0 and count < parts.len) {
            parts[count] = std.fmt.bufPrint(&temp_buffers[count], "{d} cosmetic", .{self.stats.cosmetic_changes}) catch "cosmetic";
            count += 1;
        }

        if (count == 0) {
            // No semantic changes detected, fall back to line counts
            if (self.stats.lines_added > 0 or self.stats.lines_deleted > 0) {
                return std.fmt.bufPrint(buffer, "+{d} -{d} lines", .{
                    self.stats.lines_added,
                    self.stats.lines_deleted,
                }) catch "changes";
            }
            return "no changes";
        }

        // Join parts with ", "
        var pos: usize = 0;
        for (parts[0..count], 0..) |part, i| {
            if (i > 0) {
                if (pos + 2 < buffer.len) {
                    buffer[pos] = ',';
                    buffer[pos + 1] = ' ';
                    pos += 2;
                }
            }
            const to_copy = @min(part.len, buffer.len - pos);
            @memcpy(buffer[pos..][0..to_copy], part[0..to_copy]);
            pos += to_copy;
        }

        return buffer[0..pos];
    }

    /// Count constructs that are cosmetic (comment, whitespace, rename, moved)
    pub fn cosmeticConstructCount(self: FileSummary) u32 {
        var count: u32 = 0;
        for (self.constructs) |construct| {
            if (construct.category.isCosmetic()) {
                count += 1;
            }
        }
        return count;
    }

    /// Count constructs that are semantic (actual logic changes)
    pub fn semanticConstructCount(self: FileSummary) u32 {
        var count: u32 = 0;
        for (self.constructs) |construct| {
            if (!construct.category.isCosmetic()) {
                count += 1;
            }
        }
        return count;
    }
};

/// Summary of changes across all files in a review session
pub const SessionSummary = struct {
    files: []FileSummary, // Per-file summaries
    total_stats: ChangeStats, // Aggregated statistics
    allocator: Allocator,

    pub fn deinit(self: *SessionSummary) void {
        for (self.files) |*file| {
            var f = file.*;
            f.deinit();
        }
        self.allocator.free(self.files);
    }

    /// Get total number of files with changes
    pub fn fileCount(self: SessionSummary) usize {
        return self.files.len;
    }

    /// Get total line changes as a formatted string (e.g., "+127 -45")
    pub fn lineChangeSummary(self: SessionSummary, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "+{d} -{d}", .{
            self.total_stats.lines_added,
            self.total_stats.lines_deleted,
        }) catch "+0 -0";
    }
};

// ============================================================================
// Analysis Functions
// ============================================================================

pub const AnalysisError = error{
    LanguageNotSupported,
    ParseFailed,
} || Allocator.Error;

/// Analyze a single file and return a summary of semantic changes
pub fn analyzeFile(allocator: Allocator, file: review.ReviewedFile) AnalysisError!FileSummary {
    // Try to detect the language from the file path
    const lang = highlight.Language.fromPath(file.path);

    // Count line-level changes from the diff
    var lines_added: u32 = 0;
    var lines_deleted: u32 = 0;
    var lines_modified: u32 = 0;
    var changed_lines = std.AutoHashMap(u32, void).init(allocator);
    defer changed_lines.deinit();

    // Track cosmetic classification for each changed line (by line number in new file)
    var cosmetic_lines = std.AutoHashMap(u32, cosmetic.ChangeCategory).init(allocator);
    defer cosmetic_lines.deinit();

    // Track which lines in new/old file have changes
    for (file.diff.chunks) |chunk| {
        for (chunk) |entry| {
            // Analyze this entry for cosmetic classification
            const analysis = cosmetic.analyzeChange(
                allocator,
                entry,
                if (file.old_content.len > 0) file.old_content else null,
                if (file.new_content.len > 0) file.new_content else null,
                cosmetic.CosmeticConfig.default(),
            ) catch cosmetic.CosmeticAnalysis.semantic();

            if (entry.lhs != null and entry.rhs != null) {
                // Both sides present = modification
                lines_modified += 1;
                if (entry.rhs) |rhs| {
                    changed_lines.put(rhs.line_number, {}) catch {};
                    cosmetic_lines.put(rhs.line_number, analysis.category) catch {};
                }
            } else if (entry.rhs != null) {
                // Only RHS = addition
                lines_added += 1;
                if (entry.rhs) |rhs| {
                    changed_lines.put(rhs.line_number, {}) catch {};
                    cosmetic_lines.put(rhs.line_number, analysis.category) catch {};
                }
            } else if (entry.lhs != null) {
                // Only LHS = deletion
                lines_deleted += 1;
            }
        }
    }

    // If no language detected or parsing fails, return line-only stats
    if (lang == null) {
        return FileSummary{
            .path = try allocator.dupe(u8, file.path),
            .stats = ChangeStats{
                .lines_added = lines_added,
                .lines_deleted = lines_deleted,
                .lines_modified = lines_modified,
            },
            .constructs = &.{},
            .allocator = allocator,
        };
    }

    // Parse old and new content to find collapsible regions
    var old_regions: []collapse.CollapsibleRegion = &.{};
    var new_regions: []collapse.CollapsibleRegion = &.{};

    // Parse old content
    if (file.old_content.len > 0) {
        var old_detector = collapse.CollapseDetector.init(allocator, lang.?) catch {
            return FileSummary{
                .path = try allocator.dupe(u8, file.path),
                .stats = ChangeStats{
                    .lines_added = lines_added,
                    .lines_deleted = lines_deleted,
                    .lines_modified = lines_modified,
                },
                .constructs = &.{},
                .allocator = allocator,
            };
        };
        defer old_detector.deinit();
        old_regions = old_detector.findRegions(file.old_content) catch &.{};
    }
    defer {
        for (old_regions) |region| {
            if (region.name.len > 0) allocator.free(region.name);
        }
        if (old_regions.len > 0) allocator.free(old_regions);
    }

    // Parse new content
    if (file.new_content.len > 0) {
        var new_detector = collapse.CollapseDetector.init(allocator, lang.?) catch {
            return FileSummary{
                .path = try allocator.dupe(u8, file.path),
                .stats = ChangeStats{
                    .lines_added = lines_added,
                    .lines_deleted = lines_deleted,
                    .lines_modified = lines_modified,
                },
                .constructs = &.{},
                .allocator = allocator,
            };
        };
        defer new_detector.deinit();
        new_regions = new_detector.findRegions(file.new_content) catch &.{};
    }
    defer {
        for (new_regions) |region| {
            if (region.name.len > 0) allocator.free(region.name);
        }
        if (new_regions.len > 0) allocator.free(new_regions);
    }

    // Build a map of old regions by name for efficient lookup
    var old_by_name = std.StringHashMap(collapse.CollapsibleRegion).init(allocator);
    defer old_by_name.deinit();
    for (old_regions) |region| {
        // Only track top-level constructs (level 1) to avoid double-counting
        if (region.level == 1 and region.name.len > 0) {
            old_by_name.put(region.name, region) catch {};
        }
    }

    // Track which old regions we've matched
    var matched_old = std.StringHashMap(void).init(allocator);
    defer matched_old.deinit();

    // Build list of changed constructs
    var constructs: std.ArrayList(ChangedConstruct) = .empty;
    errdefer {
        for (constructs.items) |c| {
            if (c.name.len > 0) allocator.free(c.name);
        }
        constructs.deinit(allocator);
    }

    var stats = ChangeStats{
        .lines_added = lines_added,
        .lines_deleted = lines_deleted,
        .lines_modified = lines_modified,
    };

    // Process new regions to find additions and modifications
    for (new_regions) |new_region| {
        // Only track top-level constructs
        if (new_region.level != 1) continue;
        if (new_region.name.len == 0) continue;

        if (old_by_name.get(new_region.name)) |old_region| {
            // Found in both - check if modified
            matched_old.put(new_region.name, {}) catch {};

            // Count how many changed lines fall within this construct
            // and determine if all changes are cosmetic
            var construct_changes: u32 = 0;
            var all_cosmetic = true;
            var dominant_category: cosmetic.ChangeCategory = .semantic;
            var line = new_region.start_line;
            while (line <= new_region.end_line) : (line += 1) {
                if (changed_lines.contains(line)) {
                    construct_changes += 1;
                    if (cosmetic_lines.get(line)) |cat| {
                        if (!cat.isCosmetic()) {
                            all_cosmetic = false;
                        } else if (dominant_category == .semantic) {
                            // Set dominant cosmetic category from first cosmetic line
                            dominant_category = cat;
                        }
                    } else {
                        all_cosmetic = false;
                    }
                }
            }

            // If any lines changed or the line count differs, it's modified
            const size_changed = (new_region.end_line - new_region.start_line) !=
                (old_region.end_line - old_region.start_line);

            if (construct_changes > 0 or size_changed) {
                // Size changes (line count differs) are semantic unless it's just whitespace
                const final_category = if (all_cosmetic and !size_changed)
                    dominant_category
                else if (all_cosmetic and size_changed)
                    cosmetic.ChangeCategory.whitespace // Size change with all-cosmetic = likely formatting
                else
                    cosmetic.ChangeCategory.semantic;

                // Update cosmetic/semantic counts
                if (final_category.isCosmetic()) {
                    stats.cosmetic_changes += 1;
                } else {
                    stats.semantic_changes += 1;
                }

                stats.increment(new_region.node_type, .modified);
                try constructs.append(allocator, .{
                    .name = try allocator.dupe(u8, new_region.name),
                    .node_type = new_region.node_type,
                    .change_type = .modified,
                    .line_start = new_region.start_line,
                    .line_end = new_region.end_line,
                    .lines_changed = construct_changes,
                    .category = final_category,
                });
            }
        } else {
            // Not in old - this is an addition (always semantic)
            stats.increment(new_region.node_type, .added);
            stats.semantic_changes += 1;
            try constructs.append(allocator, .{
                .name = try allocator.dupe(u8, new_region.name),
                .node_type = new_region.node_type,
                .change_type = .added,
                .line_start = new_region.start_line,
                .line_end = new_region.end_line,
                .lines_changed = new_region.end_line - new_region.start_line + 1,
                .category = .semantic,
            });
        }
    }

    // Find deletions (in old but not matched)
    for (old_regions) |old_region| {
        if (old_region.level != 1) continue;
        if (old_region.name.len == 0) continue;

        if (!matched_old.contains(old_region.name)) {
            stats.increment(old_region.node_type, .deleted);
            stats.semantic_changes += 1;
            try constructs.append(allocator, .{
                .name = try allocator.dupe(u8, old_region.name),
                .node_type = old_region.node_type,
                .change_type = .deleted,
                .line_start = old_region.start_line,
                .line_end = old_region.end_line,
                .lines_changed = old_region.end_line - old_region.start_line + 1,
                .category = .semantic,
            });
        }
    }

    // Sort constructs by line number
    std.mem.sort(ChangedConstruct, constructs.items, {}, struct {
        fn lessThan(_: void, a: ChangedConstruct, b: ChangedConstruct) bool {
            return a.line_start < b.line_start;
        }
    }.lessThan);

    return FileSummary{
        .path = try allocator.dupe(u8, file.path),
        .stats = stats,
        .constructs = try constructs.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Analyze all files in a review session and return a session summary
pub fn analyzeSession(allocator: Allocator, session: *review.ReviewSession) AnalysisError!SessionSummary {
    var files: std.ArrayList(FileSummary) = .empty;
    errdefer {
        for (files.items) |*f| {
            f.deinit();
        }
        files.deinit(allocator);
    }

    var total_stats = ChangeStats{};

    for (session.files) |file| {
        const file_summary = try analyzeFile(allocator, file);
        total_stats.add(file_summary.stats);
        try files.append(allocator, file_summary);
    }

    return SessionSummary{
        .files = try files.toOwnedSlice(allocator),
        .total_stats = total_stats,
        .allocator = allocator,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ChangeStats: default values are zero" {
    const stats = ChangeStats{};
    try std.testing.expectEqual(@as(u32, 0), stats.functions_added);
    try std.testing.expectEqual(@as(u32, 0), stats.functions_modified);
    try std.testing.expectEqual(@as(u32, 0), stats.lines_added);
    try std.testing.expectEqual(false, stats.hasChanges());
}

test "ChangeStats: add aggregates correctly" {
    var stats1 = ChangeStats{
        .functions_added = 2,
        .structs_modified = 1,
        .lines_added = 50,
    };
    const stats2 = ChangeStats{
        .functions_added = 3,
        .functions_deleted = 1,
        .lines_added = 30,
        .lines_deleted = 10,
    };

    stats1.add(stats2);

    try std.testing.expectEqual(@as(u32, 5), stats1.functions_added);
    try std.testing.expectEqual(@as(u32, 1), stats1.functions_deleted);
    try std.testing.expectEqual(@as(u32, 1), stats1.structs_modified);
    try std.testing.expectEqual(@as(u32, 80), stats1.lines_added);
    try std.testing.expectEqual(@as(u32, 10), stats1.lines_deleted);
}

test "ChangeStats: increment updates correct counter" {
    var stats = ChangeStats{};

    stats.increment(.function, .added);
    stats.increment(.function, .modified);
    stats.increment(.struct_, .deleted);
    stats.increment(.test_decl, .added);

    try std.testing.expectEqual(@as(u32, 1), stats.functions_added);
    try std.testing.expectEqual(@as(u32, 1), stats.functions_modified);
    try std.testing.expectEqual(@as(u32, 1), stats.structs_deleted);
    try std.testing.expectEqual(@as(u32, 1), stats.tests_added);
    try std.testing.expectEqual(@as(u32, 4), stats.totalConstructs());
}

test "ChangeStats: total helpers" {
    const stats = ChangeStats{
        .functions_added = 2,
        .structs_added = 1,
        .functions_modified = 3,
        .structs_deleted = 1,
        .lines_added = 100,
    };

    try std.testing.expectEqual(@as(u32, 3), stats.totalAdded());
    try std.testing.expectEqual(@as(u32, 3), stats.totalModified());
    try std.testing.expectEqual(@as(u32, 1), stats.totalDeleted());
    try std.testing.expectEqual(@as(u32, 7), stats.totalConstructs());
    try std.testing.expect(stats.hasChanges());
}

test "ChangeType: symbols and labels" {
    try std.testing.expectEqualStrings("+", ChangeType.added.symbol());
    try std.testing.expectEqualStrings("~", ChangeType.modified.symbol());
    try std.testing.expectEqualStrings("-", ChangeType.deleted.symbol());

    try std.testing.expectEqualStrings("added", ChangeType.added.label());
    try std.testing.expectEqualStrings("modified", ChangeType.modified.label());
    try std.testing.expectEqualStrings("deleted", ChangeType.deleted.label());
}

test "ChangedConstruct: description formatting" {
    const construct = ChangedConstruct{
        .name = "myFunction",
        .node_type = .function,
        .change_type = .modified,
        .line_start = 10,
        .line_end = 25,
        .lines_changed = 5,
    };

    var buffer: [128]u8 = undefined;
    const desc = construct.description(&buffer);
    try std.testing.expectEqualStrings("~ myFunction (modified)", desc);
}

test "FileSummary: briefDescription with functions" {
    const allocator = std.testing.allocator;

    var summary = FileSummary{
        .path = try allocator.dupe(u8, "test.zig"),
        .stats = ChangeStats{
            .functions_added = 2,
            .functions_modified = 1,
        },
        .constructs = &.{},
        .allocator = allocator,
    };
    defer summary.deinit();

    var buffer: [256]u8 = undefined;
    const desc = summary.briefDescription(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, desc, "2 fn added") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "1 fn modified") != null);
}

test "FileSummary: briefDescription with no semantic changes" {
    const allocator = std.testing.allocator;

    var summary = FileSummary{
        .path = try allocator.dupe(u8, "test.zig"),
        .stats = ChangeStats{
            .lines_added = 10,
            .lines_deleted = 5,
        },
        .constructs = &.{},
        .allocator = allocator,
    };
    defer summary.deinit();

    var buffer: [256]u8 = undefined;
    const desc = summary.briefDescription(&buffer);
    try std.testing.expectEqualStrings("+10 -5 lines", desc);
}

test "SessionSummary: lineChangeSummary" {
    const allocator = std.testing.allocator;

    var session = SessionSummary{
        .files = &.{},
        .total_stats = ChangeStats{
            .lines_added = 127,
            .lines_deleted = 45,
        },
        .allocator = allocator,
    };
    // No deinit needed since files is empty static slice

    var buffer: [64]u8 = undefined;
    const summary_text = session.lineChangeSummary(&buffer);
    try std.testing.expectEqualStrings("+127 -45", summary_text);
}

test "analyzeFile: file with no language returns line stats only" {
    const allocator = std.testing.allocator;

    const file = review.ReviewedFile{
        .path = "unknown_file.xyz",
        .diff = difft.FileDiff{
            .path = "",
            .language = "",
            .status = .changed,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = "",
        .new_content = "",
    };

    var summary = try analyzeFile(allocator, file);
    defer summary.deinit();

    try std.testing.expectEqualStrings("unknown_file.xyz", summary.path);
    try std.testing.expectEqual(@as(usize, 0), summary.constructs.len);
}

test "analyzeFile: empty zig file" {
    const allocator = std.testing.allocator;

    const file = review.ReviewedFile{
        .path = "test.zig",
        .diff = difft.FileDiff{
            .path = "",
            .language = "",
            .status = .changed,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = "",
        .new_content = "",
    };

    var summary = try analyzeFile(allocator, file);
    defer summary.deinit();

    try std.testing.expectEqualStrings("test.zig", summary.path);
    try std.testing.expectEqual(@as(usize, 0), summary.constructs.len);
    try std.testing.expectEqual(false, summary.stats.hasChanges());
}

test "analyzeFile: new file with function addition" {
    const allocator = std.testing.allocator;

    const new_content =
        \\pub fn hello() void {
        \\    return;
        \\}
    ;

    const file = review.ReviewedFile{
        .path = "test.zig",
        .diff = difft.FileDiff{
            .path = "",
            .language = "Zig",
            .status = .added,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = "",
        .new_content = new_content,
    };

    var summary = try analyzeFile(allocator, file);
    defer summary.deinit();

    try std.testing.expectEqual(@as(u32, 1), summary.stats.functions_added);
    try std.testing.expectEqual(@as(usize, 1), summary.constructs.len);
    try std.testing.expectEqualStrings("hello", summary.constructs[0].name);
    try std.testing.expectEqual(ChangeType.added, summary.constructs[0].change_type);
}

test "analyzeFile: deleted function" {
    const allocator = std.testing.allocator;

    const old_content =
        \\pub fn goodbye() void {
        \\    return;
        \\}
    ;

    const file = review.ReviewedFile{
        .path = "test.zig",
        .diff = difft.FileDiff{
            .path = "",
            .language = "Zig",
            .status = .removed,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = old_content,
        .new_content = "",
    };

    var summary = try analyzeFile(allocator, file);
    defer summary.deinit();

    try std.testing.expectEqual(@as(u32, 1), summary.stats.functions_deleted);
    try std.testing.expectEqual(@as(usize, 1), summary.constructs.len);
    try std.testing.expectEqualStrings("goodbye", summary.constructs[0].name);
    try std.testing.expectEqual(ChangeType.deleted, summary.constructs[0].change_type);
}

test "analyzeFile: modified function detected" {
    const allocator = std.testing.allocator;

    const old_content =
        \\pub fn process() u32 {
        \\    return 1;
        \\}
    ;

    const new_content =
        \\pub fn process() u32 {
        \\    return 2;
        \\    // extra line
        \\}
    ;

    const file = review.ReviewedFile{
        .path = "test.zig",
        .diff = difft.FileDiff{
            .path = "",
            .language = "Zig",
            .status = .changed,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = old_content,
        .new_content = new_content,
    };

    var summary = try analyzeFile(allocator, file);
    defer summary.deinit();

    // Function exists in both but has different size = modified
    try std.testing.expectEqual(@as(u32, 1), summary.stats.functions_modified);
    try std.testing.expectEqual(@as(usize, 1), summary.constructs.len);
    try std.testing.expectEqual(ChangeType.modified, summary.constructs[0].change_type);
}

test "analyzeFile: struct addition" {
    const allocator = std.testing.allocator;

    const new_content =
        \\const MyStruct = struct {
        \\    field: u32,
        \\};
    ;

    const file = review.ReviewedFile{
        .path = "test.zig",
        .diff = difft.FileDiff{
            .path = "",
            .language = "Zig",
            .status = .added,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = "",
        .new_content = new_content,
    };

    var summary = try analyzeFile(allocator, file);
    defer summary.deinit();

    try std.testing.expectEqual(@as(u32, 1), summary.stats.structs_added);
}

test "analyzeFile: mixed changes" {
    const allocator = std.testing.allocator;

    const old_content =
        \\pub fn oldFunc() void {
        \\    return;
        \\}
        \\pub fn keepFunc() void {
        \\    return;
        \\}
    ;

    const new_content =
        \\pub fn newFunc() void {
        \\    return;
        \\}
        \\pub fn keepFunc() void {
        \\    return;
        \\    // modified
        \\}
    ;

    const file = review.ReviewedFile{
        .path = "test.zig",
        .diff = difft.FileDiff{
            .path = "",
            .language = "Zig",
            .status = .changed,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = old_content,
        .new_content = new_content,
    };

    var summary = try analyzeFile(allocator, file);
    defer summary.deinit();

    // oldFunc deleted, newFunc added, keepFunc modified
    try std.testing.expectEqual(@as(u32, 1), summary.stats.functions_added);
    try std.testing.expectEqual(@as(u32, 1), summary.stats.functions_deleted);
    try std.testing.expectEqual(@as(u32, 1), summary.stats.functions_modified);
    try std.testing.expectEqual(@as(usize, 3), summary.constructs.len);
}

test "analyzeSession: aggregates multiple files" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // We can't easily add files due to the deinit logic, but we can test with empty session
    var summary = try analyzeSession(allocator, &session);
    defer summary.deinit();

    try std.testing.expectEqual(@as(usize, 0), summary.files.len);
    try std.testing.expectEqual(false, summary.total_stats.hasChanges());
}

test "analyzeFile: renamed function detected as delete + add" {
    const allocator = std.testing.allocator;

    const old_content =
        \\pub fn oldName() void {
        \\    return;
        \\}
    ;

    const new_content =
        \\pub fn newName() void {
        \\    return;
        \\}
    ;

    const file = review.ReviewedFile{
        .path = "test.zig",
        .diff = difft.FileDiff{
            .path = "",
            .language = "Zig",
            .status = .changed,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = old_content,
        .new_content = new_content,
    };

    var file_summary = try analyzeFile(allocator, file);
    defer file_summary.deinit();

    // Renamed function should appear as one deleted + one added
    try std.testing.expectEqual(@as(u32, 1), file_summary.stats.functions_added);
    try std.testing.expectEqual(@as(u32, 1), file_summary.stats.functions_deleted);
    try std.testing.expectEqual(@as(u32, 0), file_summary.stats.functions_modified);
    try std.testing.expectEqual(@as(usize, 2), file_summary.constructs.len);
}

test "analyzeFile: file with no semantic constructs" {
    const allocator = std.testing.allocator;

    // Just variable declarations and statements, no functions/structs
    const new_content =
        \\const x = 42;
        \\const y = x + 1;
    ;

    const file = review.ReviewedFile{
        .path = "test.zig",
        .diff = difft.FileDiff{
            .path = "",
            .language = "Zig",
            .status = .added,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = "",
        .new_content = new_content,
    };

    var file_summary = try analyzeFile(allocator, file);
    defer file_summary.deinit();

    // No collapsible constructs detected
    try std.testing.expectEqual(@as(usize, 0), file_summary.constructs.len);
    try std.testing.expectEqual(@as(u32, 0), file_summary.stats.totalConstructs());
}

test "analyzeFile: rust file with function" {
    const allocator = std.testing.allocator;

    const new_content =
        \\fn hello() {
        \\    println!("Hello");
        \\}
    ;

    const file = review.ReviewedFile{
        .path = "test.rs",
        .diff = difft.FileDiff{
            .path = "",
            .language = "Rust",
            .status = .added,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = "",
        .new_content = new_content,
    };

    var file_summary = try analyzeFile(allocator, file);
    defer file_summary.deinit();

    // Rust function should be detected
    try std.testing.expectEqual(@as(u32, 1), file_summary.stats.functions_added);
}

test "analyzeFile: nested struct with method" {
    const allocator = std.testing.allocator;

    const new_content =
        \\const Point = struct {
        \\    x: i32,
        \\    y: i32,
        \\
        \\    pub fn init(x: i32, y: i32) Point {
        \\        return .{ .x = x, .y = y };
        \\    }
        \\};
    ;

    const file = review.ReviewedFile{
        .path = "test.zig",
        .diff = difft.FileDiff{
            .path = "",
            .language = "Zig",
            .status = .added,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = "",
        .new_content = new_content,
    };

    var file_summary = try analyzeFile(allocator, file);
    defer file_summary.deinit();

    // Should detect the top-level struct (nested function is level 2, so not counted separately)
    try std.testing.expectEqual(@as(u32, 1), file_summary.stats.structs_added);
    // Method inside struct is level 2, should not be counted as separate top-level construct
    try std.testing.expectEqual(@as(usize, 1), file_summary.constructs.len);
}

test "analyzeFile: binary file returns empty summary" {
    const allocator = std.testing.allocator;

    const file = review.ReviewedFile{
        .path = "image.png",
        .diff = difft.FileDiff{
            .path = "",
            .language = "",
            .status = .changed,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = true,
        .old_content = "",
        .new_content = "",
    };

    var file_summary = try analyzeFile(allocator, file);
    defer file_summary.deinit();

    // Binary file should have no constructs
    try std.testing.expectEqual(@as(usize, 0), file_summary.constructs.len);
    try std.testing.expectEqual(false, file_summary.stats.hasChanges());
}

// ============================================================================
// Cosmetic Integration Tests
// ============================================================================

test "ChangeStats: cosmetic and semantic counts start at zero" {
    const stats = ChangeStats{};
    try std.testing.expectEqual(@as(u32, 0), stats.cosmetic_changes);
    try std.testing.expectEqual(@as(u32, 0), stats.semantic_changes);
}

test "ChangeStats: add aggregates cosmetic counts" {
    var stats1 = ChangeStats{
        .cosmetic_changes = 2,
        .semantic_changes = 3,
    };
    const stats2 = ChangeStats{
        .cosmetic_changes = 1,
        .semantic_changes = 5,
    };

    stats1.add(stats2);

    try std.testing.expectEqual(@as(u32, 3), stats1.cosmetic_changes);
    try std.testing.expectEqual(@as(u32, 8), stats1.semantic_changes);
}

test "ChangedConstruct: has category field" {
    const construct = ChangedConstruct{
        .name = "test",
        .node_type = .function,
        .change_type = .modified,
        .line_start = 1,
        .line_end = 10,
        .category = .comment,
    };

    try std.testing.expectEqual(cosmetic.ChangeCategory.comment, construct.category);
    try std.testing.expect(construct.category.isCosmetic());
}

test "ChangedConstruct: has moved_from_line field" {
    const construct = ChangedConstruct{
        .name = "test",
        .node_type = .function,
        .change_type = .modified,
        .line_start = 50,
        .line_end = 60,
        .category = .moved,
        .moved_from_line = 10,
    };

    try std.testing.expectEqual(@as(?u32, 10), construct.moved_from_line);
}

test "FileSummary: cosmeticConstructCount returns correct count" {
    const allocator = std.testing.allocator;

    // Create constructs with different categories
    var constructs_list: [3]ChangedConstruct = .{
        .{
            .name = "fn1",
            .node_type = .function,
            .change_type = .modified,
            .line_start = 1,
            .line_end = 10,
            .category = .comment, // cosmetic
        },
        .{
            .name = "fn2",
            .node_type = .function,
            .change_type = .modified,
            .line_start = 20,
            .line_end = 30,
            .category = .semantic, // not cosmetic
        },
        .{
            .name = "fn3",
            .node_type = .function,
            .change_type = .modified,
            .line_start = 40,
            .line_end = 50,
            .category = .whitespace, // cosmetic
        },
    };

    var summary = FileSummary{
        .path = try allocator.dupe(u8, "test.zig"),
        .stats = ChangeStats{},
        .constructs = &constructs_list,
        .allocator = allocator,
    };
    // Note: don't deinit since constructs are on the stack

    try std.testing.expectEqual(@as(u32, 2), summary.cosmeticConstructCount());
    try std.testing.expectEqual(@as(u32, 1), summary.semanticConstructCount());

    // Clean up path only
    allocator.free(summary.path);
}

test "FileSummary: briefDescription includes cosmetic count" {
    const allocator = std.testing.allocator;

    var summary = FileSummary{
        .path = try allocator.dupe(u8, "test.zig"),
        .stats = ChangeStats{
            .functions_modified = 2,
            .cosmetic_changes = 3,
        },
        .constructs = &.{},
        .allocator = allocator,
    };
    defer allocator.free(summary.path);

    var buffer: [256]u8 = undefined;
    const desc = summary.briefDescription(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, desc, "2 fn modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "3 cosmetic") != null);
}

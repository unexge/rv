const std = @import("std");
const Allocator = std.mem.Allocator;
const difft = @import("difft.zig");

pub const CommentSide = enum {
    old,
    new,

    pub fn label(self: CommentSide) []const u8 {
        return switch (self) {
            .old => "old",
            .new => "new",
        };
    }
};

/// Review mode indicating what type of changes are being reviewed
pub const ReviewMode = enum {
    unstaged, // Working tree changes (can be staged)
    staged, // Already staged changes (cannot be staged again)
    commit, // Viewing a specific commit (cannot be staged)
};

pub const Comment = struct {
    file_path: []const u8,
    side: CommentSide,
    line_start: u32,
    line_end: u32,
    text: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *Comment) void {
        self.allocator.free(self.file_path);
        self.allocator.free(self.text);
    }
};

pub const StagedRange = struct {
    file_path: []const u8,
    line_start: u32,
    line_end: u32,
    side: CommentSide,
    allocator: Allocator,

    pub fn deinit(self: *StagedRange) void {
        self.allocator.free(self.file_path);
    }
};

pub const ReviewedFile = struct {
    path: []const u8,
    diff: difft.FileDiff,
    is_binary: bool,
    old_content: []const u8 = "",
    new_content: []const u8 = "",
};

pub const ReviewSession = struct {
    allocator: Allocator,
    files: []ReviewedFile,
    comments: std.ArrayList(Comment),
    staged_ranges: std.ArrayList(StagedRange),
    current_file_idx: usize,

    pub fn init(allocator: Allocator) ReviewSession {
        return .{
            .allocator = allocator,
            .files = &.{},
            .comments = .empty,
            .staged_ranges = .empty,
            .current_file_idx = 0,
        };
    }

    pub fn deinit(self: *ReviewSession) void {
        for (self.comments.items) |*comment| {
            comment.deinit();
        }
        self.comments.deinit(self.allocator);

        for (self.staged_ranges.items) |*range| {
            range.deinit();
        }
        self.staged_ranges.deinit(self.allocator);

        for (self.files) |*file| {
            self.allocator.free(file.path);
            if (file.old_content.len > 0) self.allocator.free(file.old_content);
            if (file.new_content.len > 0) self.allocator.free(file.new_content);
            var diff = file.diff;
            diff.deinit();
        }
        self.allocator.free(self.files);
    }

    pub fn addFile(self: *ReviewSession, file: ReviewedFile) !void {
        var new_files = try self.allocator.alloc(ReviewedFile, self.files.len + 1);
        @memcpy(new_files[0..self.files.len], self.files);
        new_files[self.files.len] = file;
        if (self.files.len > 0) {
            self.allocator.free(self.files);
        }
        self.files = new_files;
    }

    pub fn addComment(self: *ReviewSession, comment: Comment) !void {
        try self.comments.append(self.allocator, comment);
    }

    pub fn addStagedRange(self: *ReviewSession, range: StagedRange) !void {
        try self.staged_ranges.append(self.allocator, range);
    }

    pub fn isStagedLine(self: *ReviewSession, file_path: []const u8, line_num: u32, side: CommentSide) bool {
        for (self.staged_ranges.items) |range| {
            if (range.side == side and
                std.mem.eql(u8, range.file_path, file_path) and
                line_num >= range.line_start and
                line_num <= range.line_end)
            {
                return true;
            }
        }
        return false;
    }

    pub fn clearStagedRanges(self: *ReviewSession) void {
        for (self.staged_ranges.items) |*range| {
            range.deinit();
        }
        self.staged_ranges.clearRetainingCapacity();
    }

    pub fn getStagedLineCount(self: *ReviewSession) usize {
        var count: usize = 0;
        for (self.staged_ranges.items) |range| {
            count += @as(usize, range.line_end - range.line_start + 1);
        }
        return count;
    }

    pub fn removeComment(self: *ReviewSession, index: usize) void {
        if (index < self.comments.items.len) {
            var comment = self.comments.orderedRemove(index);
            comment.deinit();
        }
    }

    pub fn currentFile(self: *ReviewSession) ?*ReviewedFile {
        if (self.files.len == 0) return null;
        return &self.files[self.current_file_idx];
    }

    pub fn nextFile(self: *ReviewSession) void {
        if (self.current_file_idx + 1 < self.files.len) {
            self.current_file_idx += 1;
        }
    }

    pub fn prevFile(self: *ReviewSession) void {
        if (self.current_file_idx > 0) {
            self.current_file_idx -= 1;
        }
    }

    pub fn goToFile(self: *ReviewSession, index: usize) void {
        if (index < self.files.len) {
            self.current_file_idx = index;
        }
    }

    /// Export review to markdown format
    pub fn exportMarkdown(self: *ReviewSession, writer: anytype) !void {
        try writer.writeAll("# Code Review\n\n");

        try writer.writeAll("## Summary\n\n");
        try writer.print("- **Files reviewed:** {d}\n", .{self.files.len});
        try writer.print("- **Comments:** {d}\n", .{self.comments.items.len});
        try writer.writeAll("\n");

        if (self.comments.items.len == 0) {
            try writer.writeAll("*No comments were added during review.*\n");
            return;
        }

        try writer.writeAll("## Comments\n\n");

        // Group comments by file
        var current_file: ?[]const u8 = null;
        const sorted_comments = try self.allocator.alloc(Comment, self.comments.items.len);
        defer self.allocator.free(sorted_comments);
        @memcpy(sorted_comments, self.comments.items);

        // Sort by file path, then line number
        std.mem.sort(Comment, sorted_comments, {}, struct {
            fn lessThan(_: void, a: Comment, b: Comment) bool {
                const path_cmp = std.mem.order(u8, a.file_path, b.file_path);
                if (path_cmp != .eq) return path_cmp == .lt;
                return a.line_start < b.line_start;
            }
        }.lessThan);

        for (sorted_comments) |comment| {
            if (current_file == null or !std.mem.eql(u8, current_file.?, comment.file_path)) {
                current_file = comment.file_path;
                try writer.print("### `{s}`\n\n", .{comment.file_path});
            }

            const line_ref = if (comment.line_start == comment.line_end)
                try std.fmt.allocPrint(self.allocator, "Line {d}", .{comment.line_start})
            else
                try std.fmt.allocPrint(self.allocator, "Lines {d}-{d}", .{ comment.line_start, comment.line_end });
            defer self.allocator.free(line_ref);

            try writer.print("**{s}** ({s}):\n", .{
                line_ref,
                comment.side.label(),
            });

            var lines = std.mem.splitScalar(u8, comment.text, '\n');
            while (lines.next()) |line| {
                try writer.print("> {s}\n", .{line});
            }
            try writer.writeAll("\n");
        }

        try writer.writeAll("---\n*Generated by rv*\n");
    }
};

// Tests
test "ReviewSession basic operations" {
    const allocator = std.testing.allocator;

    var session = ReviewSession.init(allocator);
    defer session.deinit();

    const comment = Comment{
        .file_path = try allocator.dupe(u8, "src/main.zig"),
        .side = .new,
        .line_start = 10,
        .line_end = 10,
        .text = try allocator.dupe(u8, "This looks good"),
        .allocator = allocator,
    };
    try session.addComment(comment);

    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);
}

test "exportMarkdown" {
    const allocator = std.testing.allocator;

    var session = ReviewSession.init(allocator);
    defer session.deinit();

    const comment = Comment{
        .file_path = try allocator.dupe(u8, "src/main.zig"),
        .side = .new,
        .line_start = 42,
        .line_end = 42,
        .text = try allocator.dupe(u8, "Potential null pointer issue"),
        .allocator = allocator,
    };
    try session.addComment(comment);

    // Use ArrayList with simple wrapper for testing
    const TestWriter = struct {
        list: *std.ArrayList(u8),
        alloc: Allocator,

        pub const Error = Allocator.Error;

        pub fn writeAll(self: @This(), data: []const u8) Error!void {
            try self.list.appendSlice(self.alloc, data);
        }

        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) Error!void {
            var buf: [1024]u8 = undefined;
            const output = std.fmt.bufPrint(&buf, fmt, args) catch return;
            try self.writeAll(output);
        }
    };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    const writer = TestWriter{ .list = &output, .alloc = allocator };

    try session.exportMarkdown(writer);

    const result = output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "# Code Review") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "**Comments:** 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "`src/main.zig`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Line 42") != null);
}

test "removeComment" {
    const allocator = std.testing.allocator;

    var session = ReviewSession.init(allocator);
    defer session.deinit();

    // Add two comments
    try session.addComment(.{
        .file_path = try allocator.dupe(u8, "file1.zig"),
        .side = .new,
        .line_start = 1,
        .line_end = 1,
        .text = try allocator.dupe(u8, "Comment 1"),
        .allocator = allocator,
    });
    try session.addComment(.{
        .file_path = try allocator.dupe(u8, "file2.zig"),
        .side = .old,
        .line_start = 5,
        .line_end = 10,
        .text = try allocator.dupe(u8, "Comment 2"),
        .allocator = allocator,
    });

    try std.testing.expectEqual(@as(usize, 2), session.comments.items.len);

    // Remove first comment
    session.removeComment(0);
    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);
    try std.testing.expectEqualStrings("file2.zig", session.comments.items[0].file_path);

    // Remove remaining comment
    session.removeComment(0);
    try std.testing.expectEqual(@as(usize, 0), session.comments.items.len);

    // Remove from empty (should be no-op)
    session.removeComment(0);
    try std.testing.expectEqual(@as(usize, 0), session.comments.items.len);
}

test "file navigation" {
    const allocator = std.testing.allocator;

    var session = ReviewSession.init(allocator);
    defer session.deinit();

    // No files - currentFile should return null
    try std.testing.expect(session.currentFile() == null);

    // Navigation with no files should be no-op
    session.nextFile();
    session.prevFile();
    session.goToFile(5);
    try std.testing.expectEqual(@as(usize, 0), session.current_file_idx);
}

test "StagedRange addStagedRange and isStagedLine" {
    const allocator = std.testing.allocator;

    var session = ReviewSession.init(allocator);
    defer session.deinit();

    try session.addStagedRange(.{
        .file_path = try allocator.dupe(u8, "src/main.zig"),
        .line_start = 10,
        .line_end = 20,
        .side = .new,
        .allocator = allocator,
    });

    try std.testing.expectEqual(@as(usize, 1), session.staged_ranges.items.len);

    // Lines within range
    try std.testing.expect(session.isStagedLine("src/main.zig", 10, .new));
    try std.testing.expect(session.isStagedLine("src/main.zig", 15, .new));
    try std.testing.expect(session.isStagedLine("src/main.zig", 20, .new));

    // Lines outside range
    try std.testing.expect(!session.isStagedLine("src/main.zig", 9, .new));
    try std.testing.expect(!session.isStagedLine("src/main.zig", 21, .new));

    // Wrong side
    try std.testing.expect(!session.isStagedLine("src/main.zig", 15, .old));

    // Wrong file
    try std.testing.expect(!session.isStagedLine("src/other.zig", 15, .new));
}

test "StagedRange overlapping ranges" {
    const allocator = std.testing.allocator;

    var session = ReviewSession.init(allocator);
    defer session.deinit();

    try session.addStagedRange(.{
        .file_path = try allocator.dupe(u8, "file.zig"),
        .line_start = 10,
        .line_end = 20,
        .side = .new,
        .allocator = allocator,
    });

    try session.addStagedRange(.{
        .file_path = try allocator.dupe(u8, "file.zig"),
        .line_start = 15,
        .line_end = 25,
        .side = .new,
        .allocator = allocator,
    });

    // Line in first range only
    try std.testing.expect(session.isStagedLine("file.zig", 12, .new));

    // Line in overlap
    try std.testing.expect(session.isStagedLine("file.zig", 18, .new));

    // Line in second range only
    try std.testing.expect(session.isStagedLine("file.zig", 23, .new));

    // Line outside both
    try std.testing.expect(!session.isStagedLine("file.zig", 5, .new));
    try std.testing.expect(!session.isStagedLine("file.zig", 30, .new));
}

test "StagedRange clearStagedRanges" {
    const allocator = std.testing.allocator;

    var session = ReviewSession.init(allocator);
    defer session.deinit();

    try session.addStagedRange(.{
        .file_path = try allocator.dupe(u8, "file1.zig"),
        .line_start = 1,
        .line_end = 10,
        .side = .new,
        .allocator = allocator,
    });

    try session.addStagedRange(.{
        .file_path = try allocator.dupe(u8, "file2.zig"),
        .line_start = 5,
        .line_end = 15,
        .side = .old,
        .allocator = allocator,
    });

    try std.testing.expectEqual(@as(usize, 2), session.staged_ranges.items.len);

    session.clearStagedRanges();

    try std.testing.expectEqual(@as(usize, 0), session.staged_ranges.items.len);
    try std.testing.expect(!session.isStagedLine("file1.zig", 5, .new));
}

test "StagedRange getStagedLineCount" {
    const allocator = std.testing.allocator;

    var session = ReviewSession.init(allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 0), session.getStagedLineCount());

    try session.addStagedRange(.{
        .file_path = try allocator.dupe(u8, "file.zig"),
        .line_start = 10,
        .line_end = 14,
        .side = .new,
        .allocator = allocator,
    });

    try std.testing.expectEqual(@as(usize, 5), session.getStagedLineCount());

    try session.addStagedRange(.{
        .file_path = try allocator.dupe(u8, "file.zig"),
        .line_start = 20,
        .line_end = 22,
        .side = .old,
        .allocator = allocator,
    });

    try std.testing.expectEqual(@as(usize, 8), session.getStagedLineCount());
}

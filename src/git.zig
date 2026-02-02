const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const shell = @import("shell.zig");

pub const FileStatus = enum {
    modified,
    added,
    deleted,
    renamed,
    copied,
    untracked,
};

pub const ChangedFile = struct {
    path: []const u8,
    status: FileStatus,
    old_path: ?[]const u8 = null,

    pub fn deinit(self: *ChangedFile, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.old_path) |op| {
            allocator.free(op);
        }
    }
};

pub const GitError = error{
    NotARepository,
    CommandFailed,
    ParseError,
    PipeFailed,
} || Allocator.Error;

/// Run a command and capture its output (via shell)
pub fn runCommand(allocator: Allocator, io: Io, cmd: []const u8) GitError!struct { stdout: []u8, exit_code: u8 } {
    const result = shell.run(allocator, io, cmd) catch |err| switch (err) {
        error.PipeFailed => return GitError.PipeFailed,
        error.CommandFailed => return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    };
    return .{ .stdout = result.stdout, .exit_code = result.exit_code };
}

/// Run a command directly without shell (faster)
pub fn runCommandDirect(allocator: Allocator, io: Io, argv: []const []const u8) GitError!struct { stdout: []u8, exit_code: u8 } {
    const result = shell.runDirect(allocator, io, argv) catch |err| switch (err) {
        error.PipeFailed => return GitError.PipeFailed,
        error.CommandFailed => return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    };
    return .{ .stdout = result.stdout, .exit_code = result.exit_code };
}

/// Read file content from the filesystem (native, no shell)
pub fn readFileContent(allocator: Allocator, io: Io, path: []const u8) GitError![]const u8 {
    // Use cat command via direct execution (still faster than shell.run)
    const result = runCommandDirect(allocator, io, &.{ "cat", path }) catch return GitError.CommandFailed;
    return result.stdout;
}

/// Get the root directory of the git repository (direct execution)
pub fn getRepoRoot(allocator: Allocator, io: Io) GitError![]const u8 {
    const result = try runCommandDirect(allocator, io, &.{ "git", "rev-parse", "--show-toplevel" });

    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return GitError.NotARepository;
    }

    const trimmed = std.mem.trimEnd(u8, result.stdout, "\n\r");
    if (trimmed.len < result.stdout.len) {
        const new_buf = try allocator.dupe(u8, trimmed);
        allocator.free(result.stdout);
        return new_buf;
    }
    return result.stdout;
}

/// Get list of changed files (direct execution)
pub fn getChangedFiles(allocator: Allocator, io: Io, staged: bool) GitError![]ChangedFile {
    const result = if (staged)
        try runCommandDirect(allocator, io, &.{ "git", "diff", "--cached", "--name-status" })
    else
        try runCommandDirect(allocator, io, &.{ "git", "diff", "--name-status" });
    defer allocator.free(result.stdout);

    return parseNameStatus(allocator, result.stdout);
}

/// Run git diff with external diff tool (difft) to get semantic diffs
/// Returns raw JSON output from difft for all changed files
/// files: list of ChangedFile structs with path and status information
pub fn runGitDiffWithDifft(
    allocator: Allocator,
    io: Io,
    staged: bool,
    commit: ?[]const u8,
    files: []const ChangedFile,
) GitError![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (files) |file| {
        const escaped_path = try shell.escapeForDoubleQuotes(allocator, file.path);
        defer allocator.free(escaped_path);

        // For renames/copies, use old_path for the left side
        const old_path = file.old_path orelse file.path;
        const escaped_old_path = try shell.escapeForDoubleQuotes(allocator, old_path);
        defer allocator.free(escaped_old_path);

        var difft_cmd: std.ArrayList(u8) = .empty;
        defer difft_cmd.deinit(allocator);

        try difft_cmd.appendSlice(allocator, "bash -c 'DFT_UNSTABLE=yes difft --display json ");

        // Build left side (old content)
        if (file.status == .added or file.status == .untracked) {
            // New file: compare against /dev/null
            try difft_cmd.appendSlice(allocator, "/dev/null ");
        } else if (commit) |c| {
            // Commit mode: old is from parent commit
            try difft_cmd.appendSlice(allocator, "<(git show ");
            try difft_cmd.appendSlice(allocator, c);
            try difft_cmd.appendSlice(allocator, "^:\"");
            try difft_cmd.appendSlice(allocator, escaped_old_path);
            try difft_cmd.appendSlice(allocator, "\" 2>/dev/null) ");
        } else {
            // Staged or working tree: old is from HEAD
            try difft_cmd.appendSlice(allocator, "<(git show HEAD:\"");
            try difft_cmd.appendSlice(allocator, escaped_old_path);
            try difft_cmd.appendSlice(allocator, "\" 2>/dev/null) ");
        }

        // Build right side (new content)
        if (file.status == .deleted) {
            // Deleted file: compare against /dev/null
            try difft_cmd.appendSlice(allocator, "/dev/null");
        } else if (commit) |c| {
            // Commit mode: new is from the commit
            try difft_cmd.appendSlice(allocator, "<(git show ");
            try difft_cmd.appendSlice(allocator, c);
            try difft_cmd.appendSlice(allocator, ":\"");
            try difft_cmd.appendSlice(allocator, escaped_path);
            try difft_cmd.appendSlice(allocator, "\" 2>/dev/null)");
        } else if (staged) {
            // Staged mode: new is from the index
            try difft_cmd.appendSlice(allocator, "<(git show :\"");
            try difft_cmd.appendSlice(allocator, escaped_path);
            try difft_cmd.appendSlice(allocator, "\" 2>/dev/null)");
        } else {
            // Working tree mode: new is from the filesystem
            try difft_cmd.appendSlice(allocator, "\"");
            try difft_cmd.appendSlice(allocator, escaped_path);
            try difft_cmd.appendSlice(allocator, "\"");
        }

        try difft_cmd.appendSlice(allocator, " 2>/dev/null' 2>/dev/null");

        const difft_cmd_str = try difft_cmd.toOwnedSlice(allocator);
        defer allocator.free(difft_cmd_str);

        const difft_result = try runCommand(allocator, io, difft_cmd_str);
        defer allocator.free(difft_result.stdout);

        if (difft_result.stdout.len > 0) {
            // When using process substitution, difft may report the wrong path
            // (e.g., "/dev/fd/63" instead of the actual file path).
            // We need to fix the path in the JSON output.
            // The JSON starts with {"language":"...", "path":"..."}
            // We replace "path":"<anything>" with "path":"<actual_path>"
            const json_path_pattern = "\"path\":\"";
            if (std.mem.indexOf(u8, difft_result.stdout, json_path_pattern)) |pattern_start| {
                const path_value_start = pattern_start + json_path_pattern.len;
                // Find the closing quote of the path value
                if (std.mem.indexOfScalarPos(u8, difft_result.stdout, path_value_start, '"')) |path_value_end| {
                    // Build the corrected JSON: prefix + correct path + suffix
                    try output.appendSlice(allocator, difft_result.stdout[0..path_value_start]);
                    // Escape the path for JSON (handle backslashes and quotes)
                    for (file.path) |c| {
                        switch (c) {
                            '\\' => try output.appendSlice(allocator, "\\\\"),
                            '"' => try output.appendSlice(allocator, "\\\""),
                            else => try output.append(allocator, c),
                        }
                    }
                    try output.appendSlice(allocator, difft_result.stdout[path_value_end..]);
                } else {
                    // Couldn't parse path - use raw output
                    try output.appendSlice(allocator, difft_result.stdout);
                }
            } else {
                // No path field found - use raw output
                try output.appendSlice(allocator, difft_result.stdout);
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Get list of changed files introduced by a commit (direct execution)
pub fn getChangedFilesForCommit(allocator: Allocator, io: Io, commit: []const u8) GitError![]ChangedFile {
    const result = try runCommandDirect(allocator, io, &.{ "git", "diff-tree", "--no-commit-id", "--name-status", "-r", "--root", commit });
    defer allocator.free(result.stdout);

    return parseNameStatus(allocator, result.stdout);
}

fn parseNameStatus(allocator: Allocator, output: []const u8) GitError![]ChangedFile {
    var files: std.ArrayList(ChangedFile) = .empty;
    errdefer {
        for (files.items) |*f| {
            f.deinit(allocator);
        }
        files.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const status_char = line[0];
        const status: FileStatus = switch (status_char) {
            'M' => .modified,
            'A' => .added,
            'D' => .deleted,
            'R' => .renamed,
            'C' => .copied,
            '?' => .untracked,
            else => continue,
        };

        const rest = std.mem.trimStart(u8, line[1..], "\t ");

        if (status == .renamed or status == .copied) {
            var parts = std.mem.splitScalar(u8, rest, '\t');
            const old_path = parts.next() orelse continue;
            const new_path = parts.next() orelse continue;

            try files.append(allocator, .{
                .path = try allocator.dupe(u8, new_path),
                .status = status,
                .old_path = try allocator.dupe(u8, old_path),
            });
        } else {
            try files.append(allocator, .{
                .path = try allocator.dupe(u8, rest),
                .status = status,
            });
        }
    }

    return files.toOwnedSlice(allocator);
}

/// Get the contents of a file at a specific revision (direct execution)
pub fn getFileAtRevision(allocator: Allocator, io: Io, path: []const u8, rev: []const u8) GitError!?[]const u8 {
    const ref = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ rev, path });
    defer allocator.free(ref);

    const result = runCommandDirect(allocator, io, &.{ "git", "show", ref }) catch return null;
    return result.stdout;
}

/// Check if a file is binary
pub fn isBinaryFile(content: []const u8) bool {
    const check_len = @min(content.len, 8192);
    for (content[0..check_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

test "parseNameStatus" {
    const allocator = std.testing.allocator;

    const input = "M\tsrc/main.zig\nA\tsrc/new.zig\nD\tsrc/old.zig\n";

    const files = try parseNameStatus(allocator, input);
    defer {
        for (@constCast(files)) |*f| {
            f.deinit(allocator);
        }
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualStrings("src/main.zig", files[0].path);
    try std.testing.expectEqual(FileStatus.modified, files[0].status);
}

test "isBinaryFile" {
    try std.testing.expect(!isBinaryFile("hello world"));
    try std.testing.expect(isBinaryFile("hello\x00world"));
    try std.testing.expect(!isBinaryFile(""));
}

/// Represents a parsed diff hunk
const DiffHunk = struct {
    header: []const u8,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    content: []const u8,
};

/// Parse a unified diff hunk header like "@@ -1,3 +1,4 @@"
fn parseHunkHeader(header: []const u8) ?struct { old_start: u32, old_count: u32, new_start: u32, new_count: u32 } {
    if (!std.mem.startsWith(u8, header, "@@ -")) return null;

    var rest = header[4..];

    const old_start = std.fmt.parseInt(u32, parseNumber(rest), 10) catch return null;
    rest = skipNumber(rest);

    var old_count: u32 = 1;
    if (rest.len > 0 and rest[0] == ',') {
        rest = rest[1..];
        old_count = std.fmt.parseInt(u32, parseNumber(rest), 10) catch return null;
        rest = skipNumber(rest);
    }

    if (!std.mem.startsWith(u8, rest, " +")) return null;
    rest = rest[2..];

    const new_start = std.fmt.parseInt(u32, parseNumber(rest), 10) catch return null;
    rest = skipNumber(rest);

    var new_count: u32 = 1;
    if (rest.len > 0 and rest[0] == ',') {
        rest = rest[1..];
        new_count = std.fmt.parseInt(u32, parseNumber(rest), 10) catch return null;
    }

    return .{ .old_start = old_start, .old_count = old_count, .new_start = new_start, .new_count = new_count };
}

fn parseNumber(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len and (s[end] >= '0' and s[end] <= '9')) : (end += 1) {}
    return s[0..end];
}

fn skipNumber(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] >= '0' and s[i] <= '9')) : (i += 1) {}
    return s[i..];
}

/// Check if a hunk overlaps with the given line range (in new file coordinates)
fn hunkOverlapsRange(new_start: u32, new_count: u32, range_start: u32, range_end: u32) bool {
    if (new_count == 0) {
        return new_start >= range_start and new_start <= range_end;
    }
    const hunk_end = new_start + new_count - 1;
    return new_start <= range_end and hunk_end >= range_start;
}

/// Stage specific lines from a file to the git index
/// Uses unified diff to extract hunks that overlap with the specified line range
pub fn stageLineRange(
    allocator: Allocator,
    io: Io,
    file_path: []const u8,
    start_line: u32,
    end_line: u32,
) GitError!void {
    const diff_result = try runCommandDirect(allocator, io, &.{ "git", "diff", "-U0", "--", file_path });
    defer allocator.free(diff_result.stdout);

    if (diff_result.exit_code != 0) {
        return GitError.CommandFailed;
    }

    if (diff_result.stdout.len == 0) {
        return;
    }

    if (isBinaryFile(diff_result.stdout)) {
        return GitError.ParseError;
    }

    const patch = try buildPartialPatch(allocator, diff_result.stdout, start_line, end_line);
    defer allocator.free(patch);

    if (patch.len == 0) {
        return;
    }

    try applyPatchToIndex(allocator, io, patch);
}

/// Build a partial patch containing only the specified lines from hunks
/// This filters individual lines within hunks, not just whole hunks
fn buildPartialPatch(allocator: Allocator, diff: []const u8, start_line: u32, end_line: u32) GitError![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var diff_lines = std.mem.splitScalar(u8, diff, '\n');
    var header_lines: std.ArrayList([]const u8) = .empty;
    defer header_lines.deinit(allocator);

    var in_header = true;
    var header_written = false;

    // Collect all hunks first, then process them
    var hunks: std.ArrayList(HunkData) = .empty;
    defer {
        for (hunks.items) |*h| {
            h.lines.deinit(allocator);
        }
        hunks.deinit(allocator);
    }

    var current_hunk: ?HunkData = null;

    while (diff_lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            // Save previous hunk
            if (current_hunk) |h| {
                try hunks.append(allocator, h);
            }
            // Start new hunk
            const parsed = parseHunkHeader(line) orelse return GitError.ParseError;
            current_hunk = HunkData{
                .header = line,
                .old_start = parsed.old_start,
                .old_count = parsed.old_count,
                .new_start = parsed.new_start,
                .new_count = parsed.new_count,
                .lines = .empty,
            };
            in_header = false;
        } else if (in_header) {
            try header_lines.append(allocator, line);
        } else if (current_hunk != null) {
            if (line.len > 0 and (line[0] == '+' or line[0] == '-' or line[0] == ' ' or line[0] == '\\')) {
                try current_hunk.?.lines.append(allocator, line);
            }
        }
    }
    // Save last hunk
    if (current_hunk) |h| {
        try hunks.append(allocator, h);
    }

    // Process each hunk and filter lines
    for (hunks.items) |hunk| {
        const filtered = try filterHunkLines(allocator, hunk, start_line, end_line);
        defer allocator.free(filtered.lines);

        if (filtered.lines.len == 0) continue;

        // Write header once
        if (!header_written) {
            for (header_lines.items) |h| {
                try result.appendSlice(allocator, h);
                try result.append(allocator, '\n');
            }
            header_written = true;
        }

        // Write new hunk header with adjusted counts
        var hunk_header_buf: [64]u8 = undefined;
        const hunk_header = std.fmt.bufPrint(&hunk_header_buf, "@@ -{d},{d} +{d},{d} @@\n", .{
            filtered.old_start,
            filtered.old_count,
            filtered.new_start,
            filtered.new_count,
        }) catch return GitError.ParseError;
        try result.appendSlice(allocator, hunk_header);

        // Write filtered lines
        try result.appendSlice(allocator, filtered.lines);
    }

    return result.toOwnedSlice(allocator);
}

const HunkData = struct {
    header: []const u8,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: std.ArrayList([]const u8),
};

const FilteredHunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: []u8,
};

/// Filter lines within a hunk to only include those in the specified range
fn filterHunkLines(allocator: Allocator, hunk: HunkData, start_line: u32, end_line: u32) Allocator.Error!FilteredHunk {
    var filtered_lines: std.ArrayList(u8) = .empty;
    errdefer filtered_lines.deinit(allocator);

    var new_line_num = hunk.new_start;
    var old_line_num = hunk.old_start;

    var old_count: u32 = 0;
    var new_count: u32 = 0;
    var first_old_line: ?u32 = null;
    var first_new_line: ?u32 = null;

    for (hunk.lines.items) |line| {
        if (line.len == 0) continue;

        const line_type = line[0];

        // Track line numbers
        const current_new_line = new_line_num;
        const current_old_line = old_line_num;

        switch (line_type) {
            '+' => {
                // Addition: only in new file
                if (current_new_line >= start_line and current_new_line <= end_line) {
                    try filtered_lines.appendSlice(allocator, line);
                    try filtered_lines.append(allocator, '\n');
                    new_count += 1;
                    if (first_new_line == null) first_new_line = current_new_line;
                }
                new_line_num += 1;
            },
            '-' => {
                // Deletion: only in old file
                // Include deletions if they're adjacent to selected additions
                // For simplicity, include if the corresponding new line position is in range
                if (current_new_line >= start_line and current_new_line <= end_line + 1) {
                    try filtered_lines.appendSlice(allocator, line);
                    try filtered_lines.append(allocator, '\n');
                    old_count += 1;
                    if (first_old_line == null) first_old_line = current_old_line;
                }
                old_line_num += 1;
            },
            ' ' => {
                // Context line: in both files
                // Include context if it's adjacent to selected changes
                if (current_new_line >= start_line and current_new_line <= end_line) {
                    try filtered_lines.appendSlice(allocator, line);
                    try filtered_lines.append(allocator, '\n');
                    old_count += 1;
                    new_count += 1;
                    if (first_old_line == null) first_old_line = current_old_line;
                    if (first_new_line == null) first_new_line = current_new_line;
                }
                new_line_num += 1;
                old_line_num += 1;
            },
            '\\' => {
                // "No newline at end of file" - include if we have any content
                if (filtered_lines.items.len > 0) {
                    try filtered_lines.appendSlice(allocator, line);
                    try filtered_lines.append(allocator, '\n');
                }
            },
            else => {},
        }
    }

    return FilteredHunk{
        .old_start = first_old_line orelse hunk.old_start,
        .old_count = old_count,
        .new_start = first_new_line orelse hunk.new_start,
        .new_count = new_count,
        .lines = try filtered_lines.toOwnedSlice(allocator),
    };
}

/// Apply a patch to the git index using git apply --cached
fn applyPatchToIndex(allocator: Allocator, io: Io, patch: []const u8) GitError!void {
    const process = std.process;

    var child = process.spawn(io, .{
        .argv = &.{ "git", "apply", "--cached", "--unidiff-zero", "-" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return GitError.CommandFailed;

    var stdin_file = child.stdin orelse return GitError.PipeFailed;
    stdin_file.writeStreamingAll(io, patch) catch return GitError.CommandFailed;
    stdin_file.close(io);
    child.stdin = null;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024) catch return GitError.CommandFailed;

    const term = child.wait(io) catch return GitError.CommandFailed;
    const exit_code = switch (term) {
        .exited => |code| code,
        else => return GitError.CommandFailed,
    };

    if (exit_code != 0) {
        return GitError.CommandFailed;
    }
}

test "parseHunkHeader" {
    {
        const result = parseHunkHeader("@@ -1,3 +1,4 @@").?;
        try std.testing.expectEqual(@as(u32, 1), result.old_start);
        try std.testing.expectEqual(@as(u32, 3), result.old_count);
        try std.testing.expectEqual(@as(u32, 1), result.new_start);
        try std.testing.expectEqual(@as(u32, 4), result.new_count);
    }
    {
        const result = parseHunkHeader("@@ -10 +10,2 @@").?;
        try std.testing.expectEqual(@as(u32, 10), result.old_start);
        try std.testing.expectEqual(@as(u32, 1), result.old_count);
        try std.testing.expectEqual(@as(u32, 10), result.new_start);
        try std.testing.expectEqual(@as(u32, 2), result.new_count);
    }
    {
        const result = parseHunkHeader("@@ -0,0 +1,5 @@").?;
        try std.testing.expectEqual(@as(u32, 0), result.old_start);
        try std.testing.expectEqual(@as(u32, 0), result.old_count);
        try std.testing.expectEqual(@as(u32, 1), result.new_start);
        try std.testing.expectEqual(@as(u32, 5), result.new_count);
    }
    try std.testing.expect(parseHunkHeader("not a header") == null);
}

test "hunkOverlapsRange" {
    try std.testing.expect(hunkOverlapsRange(5, 3, 1, 10));
    try std.testing.expect(hunkOverlapsRange(5, 3, 6, 10));
    try std.testing.expect(hunkOverlapsRange(5, 3, 1, 5));
    try std.testing.expect(!hunkOverlapsRange(5, 3, 10, 15));
    try std.testing.expect(!hunkOverlapsRange(5, 3, 1, 4));
    try std.testing.expect(hunkOverlapsRange(5, 0, 5, 10));
    try std.testing.expect(!hunkOverlapsRange(5, 0, 6, 10));
}

test "buildPartialPatch - selects only specified lines" {
    const allocator = std.testing.allocator;

    // Diff with multiple additions in one hunk
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\index 1234567..abcdefg 100644
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1,0 +1,4 @@
        \\+line 1
        \\+line 2
        \\+line 3
        \\+line 4
    ;

    // Select only line 2
    {
        const patch = try buildPartialPatch(allocator, diff, 2, 2);
        defer allocator.free(patch);
        // Should contain only line 2
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 2") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 1") == null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 3") == null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 4") == null);
    }

    // Select lines 2-3
    {
        const patch = try buildPartialPatch(allocator, diff, 2, 3);
        defer allocator.free(patch);
        // Should contain lines 2 and 3
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 2") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 3") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 1") == null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 4") == null);
    }

    // Select all lines
    {
        const patch = try buildPartialPatch(allocator, diff, 1, 4);
        defer allocator.free(patch);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 2") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 3") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+line 4") != null);
    }

    // Select no lines (out of range)
    {
        const patch = try buildPartialPatch(allocator, diff, 100, 200);
        defer allocator.free(patch);
        try std.testing.expectEqual(@as(usize, 0), patch.len);
    }
}

test "buildPartialPatch - handles multiple hunks" {
    const allocator = std.testing.allocator;

    // Simpler test with two separate hunks, no context lines
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\index 1234567..abcdefg 100644
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -0,0 +1,1 @@
        \\+added line 1
        \\@@ -10,0 +12,1 @@
        \\+added line 12
    ;

    // Select only from first hunk (line 1)
    {
        const patch = try buildPartialPatch(allocator, diff, 1, 1);
        defer allocator.free(patch);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+added line 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+added line 12") == null);
    }

    // Select only from second hunk (line 12)
    {
        const patch = try buildPartialPatch(allocator, diff, 12, 12);
        defer allocator.free(patch);
        // Use "+added line 1\n" to avoid matching "+added line 12"
        try std.testing.expect(std.mem.indexOf(u8, patch, "+added line 1\n") == null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+added line 12") != null);
    }

    // Select both hunks
    {
        const patch = try buildPartialPatch(allocator, diff, 1, 12);
        defer allocator.free(patch);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+added line 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "+added line 12") != null);
    }
}

test "filterHunkLines - filters additions correctly" {
    const allocator = std.testing.allocator;

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    try lines.append(allocator, "+line 1");
    try lines.append(allocator, "+line 2");
    try lines.append(allocator, "+line 3");

    const hunk = HunkData{
        .header = "@@ -0,0 +1,3 @@",
        .old_start = 0,
        .old_count = 0,
        .new_start = 1,
        .new_count = 3,
        .lines = lines,
    };

    // Select only line 2
    const filtered = try filterHunkLines(allocator, hunk, 2, 2);
    defer allocator.free(filtered.lines);

    try std.testing.expect(std.mem.indexOf(u8, filtered.lines, "+line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.lines, "+line 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.lines, "+line 3") == null);
    try std.testing.expectEqual(@as(u32, 1), filtered.new_count);
    try std.testing.expectEqual(@as(u32, 0), filtered.old_count);
}

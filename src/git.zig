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

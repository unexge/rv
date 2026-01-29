const std = @import("std");
const Allocator = std.mem.Allocator;

const FILE = opaque {};
extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn pclose(stream: *FILE) c_int;
extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;

/// Escape a string for use in shell double quotes
fn escapeForShell(allocator: Allocator, input: []const u8) Allocator.Error![]const u8 {
    // Count special characters that need escaping in double quotes: $ ` \ " !
    var special_count: usize = 0;
    for (input) |c| {
        if (c == '$' or c == '`' or c == '\\' or c == '"' or c == '!') {
            special_count += 1;
        }
    }

    if (special_count == 0) return try allocator.dupe(u8, input);

    var result = try allocator.alloc(u8, input.len + special_count);
    var i: usize = 0;
    for (input) |c| {
        if (c == '$' or c == '`' or c == '\\' or c == '"' or c == '!') {
            result[i] = '\\';
            i += 1;
        }
        result[i] = c;
        i += 1;
    }
    return result;
}

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
    ForkFailed,
    PipeFailed,
    ExecFailed,
} || Allocator.Error;

/// Run a command and capture its output using popen
pub fn runCommand(allocator: Allocator, cmd: []const u8) GitError!struct { stdout: []u8, exit_code: u8 } {
    const cmd_z = allocator.dupeZ(u8, cmd) catch return GitError.CommandFailed;
    defer allocator.free(cmd_z);

    const fp = popen(cmd_z.ptr, "r") orelse return GitError.PipeFailed;
    defer _ = pclose(fp);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        try output.appendSlice(allocator, buf[0..n]);
    }

    return .{
        .stdout = try output.toOwnedSlice(allocator),
        .exit_code = 0, // popen doesn't give us exit code easily
    };
}

/// Read file content from the filesystem
pub fn readFileContent(allocator: Allocator, path: []const u8) GitError![]const u8 {
    const escaped_path = try escapeForShell(allocator, path);
    defer allocator.free(escaped_path);

    const cmd = std.fmt.allocPrint(allocator, "cat \"{s}\" 2>/dev/null", .{escaped_path}) catch return GitError.CommandFailed;
    defer allocator.free(cmd);

    const result = try runCommand(allocator, cmd);
    return result.stdout;
}

/// Get the root directory of the git repository
pub fn getRepoRoot(allocator: Allocator) GitError![]const u8 {
    const result = try runCommand(allocator, "git rev-parse --show-toplevel 2>/dev/null");

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

/// Get list of changed files
pub fn getChangedFiles(allocator: Allocator, staged: bool) GitError![]ChangedFile {
    const cmd = if (staged)
        "git diff --cached --name-status 2>/dev/null"
    else
        "git diff --name-status 2>/dev/null";

    const result = try runCommand(allocator, cmd);
    defer allocator.free(result.stdout);

    return parseNameStatus(allocator, result.stdout);
}

/// Run git diff with external diff tool (difft) to get semantic diffs
/// Returns raw JSON output from difft for all changed files
pub fn runGitDiffWithDifft(
    allocator: Allocator,
    staged: bool,
    commit: ?[]const u8,
    paths: []const []const u8,
) GitError![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const rev: []const u8 = if (commit) |c| c else if (staged) ":" else "HEAD";

    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(allocator);

    if (commit) |c| {
        try cmd.appendSlice(allocator, "git diff-tree --no-commit-id --name-only -r --root ");
        try cmd.appendSlice(allocator, c);
        try cmd.appendSlice(allocator, " 2>/dev/null");
    } else if (staged) {
        try cmd.appendSlice(allocator, "git diff --cached --name-only 2>/dev/null");
    } else {
        try cmd.appendSlice(allocator, "git diff --name-only 2>/dev/null");
    }

    const cmd_str = try cmd.toOwnedSlice(allocator);
    defer allocator.free(cmd_str);

    const result = try runCommand(allocator, cmd_str);
    defer allocator.free(result.stdout);

    var changed_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (changed_files.items) |file| {
            allocator.free(file);
        }
        changed_files.deinit(allocator);
    }

    var file_iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (file_iter.next()) |file| {
        if (file.len == 0) continue;

        if (paths.len > 0) {
            var matched = false;
            for (paths) |path| {
                if (std.mem.indexOf(u8, file, path) != null) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
        }

        try changed_files.append(allocator, try allocator.dupe(u8, file));
    }

    for (changed_files.items) |file| {
        const escaped_file = try escapeForShell(allocator, file);
        defer allocator.free(escaped_file);

        var difft_cmd: std.ArrayList(u8) = .empty;
        defer difft_cmd.deinit(allocator);

        try difft_cmd.appendSlice(allocator, "bash -c 'DFT_UNSTABLE=yes difft --display json <(git show ");
        try difft_cmd.appendSlice(allocator, rev);
        try difft_cmd.appendSlice(allocator, ":\"");
        try difft_cmd.appendSlice(allocator, escaped_file);
        try difft_cmd.appendSlice(allocator, "\") \"");
        try difft_cmd.appendSlice(allocator, escaped_file);
        try difft_cmd.appendSlice(allocator, "\" 2>/dev/null' 2>/dev/null");

        const difft_cmd_str = try difft_cmd.toOwnedSlice(allocator);
        defer allocator.free(difft_cmd_str);

        const difft_result = try runCommand(allocator, difft_cmd_str);
        defer allocator.free(difft_result.stdout);

        if (difft_result.stdout.len > 0) {
            try output.appendSlice(allocator, difft_result.stdout);
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Get list of changed files introduced by a commit
pub fn getChangedFilesForCommit(allocator: Allocator, commit: []const u8) GitError![]ChangedFile {
    const cmd = try std.fmt.allocPrint(allocator, "git diff-tree --no-commit-id --name-status -r --root {s} 2>/dev/null", .{commit});
    defer allocator.free(cmd);

    const result = try runCommand(allocator, cmd);
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

/// Get the contents of a file at a specific revision
pub fn getFileAtRevision(allocator: Allocator, path: []const u8, rev: []const u8) GitError!?[]const u8 {
    const escaped_path = try escapeForShell(allocator, path);
    defer allocator.free(escaped_path);

    const cmd = try std.fmt.allocPrint(allocator, "git show \"{s}:{s}\" 2>/dev/null", .{ rev, escaped_path });
    defer allocator.free(cmd);

    const result = runCommand(allocator, cmd) catch return null;
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

test "escapeForShell" {
    const allocator = std.testing.allocator;

    // No special characters
    {
        const result = try escapeForShell(allocator, "simple.txt");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("simple.txt", result);
    }

    // Double quotes
    {
        const result = try escapeForShell(allocator, "file\"name.txt");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("file\\\"name.txt", result);
    }

    // Dollar sign
    {
        const result = try escapeForShell(allocator, "file$name.txt");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("file\\$name.txt", result);
    }

    // Multiple special chars
    {
        const result = try escapeForShell(allocator, "a\"b$c`d\\e!f");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("a\\\"b\\$c\\`d\\\\e\\!f", result);
    }
}

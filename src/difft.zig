const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Io = std.Io;

const git = @import("git.zig");
const shell = @import("shell.zig");

/// Highlight type from difftastic's semantic analysis
/// Maps to difftastic's JSON "highlight" field values
pub const Highlight = enum {
    // Unchanged/normal content
    normal,
    // Novel/changed content (generic change marker)
    novel,
    // Semantic token types from difftastic
    delimiter, // Brackets, parens, etc.
    string, // String literals
    type_, // Type names
    comment, // Comments
    keyword, // Language keywords
    tree_sitter_error, // Parse errors

    /// Returns true if this highlight represents a novel/changed token
    /// In difftastic's JSON output, any token in the "changes" array is novel,
    /// but the highlight field tells us what *kind* of token it is for syntax coloring
    pub fn isNovel(self: Highlight) bool {
        // All highlight types in the changes array are novel tokens
        // The enum value tells us the syntax category for coloring
        return self != .normal;
    }

    /// Returns true if this is a syntax-significant highlight (for semantic coloring)
    pub fn isSemantic(self: Highlight) bool {
        return switch (self) {
            .delimiter, .string, .type_, .comment, .keyword => true,
            else => false,
        };
    }
};

pub const Change = struct {
    start: u32,
    end: u32,
    content: []const u8,
    highlight: Highlight,
};

pub const Side = struct {
    line_number: u32,
    changes: []const Change,
};

pub const DiffEntry = struct {
    lhs: ?Side,
    rhs: ?Side,
};

pub const DiffStatus = enum {
    unchanged, // No changes (difftastic may output this)
    changed, // File has modifications
    added, // File was created (difftastic: "created")
    removed, // File was deleted (difftastic: "deleted")
};

pub const FileDiff = struct {
    path: []const u8,
    language: []const u8,
    status: DiffStatus,
    chunks: []const []const DiffEntry,
    allocator: Allocator,

    pub fn deinit(self: *FileDiff) void {
        for (self.chunks) |chunk| {
            for (chunk) |entry| {
                if (entry.lhs) |lhs| {
                    for (lhs.changes) |change| {
                        self.allocator.free(change.content);
                    }
                    self.allocator.free(lhs.changes);
                }
                if (entry.rhs) |rhs| {
                    for (rhs.changes) |change| {
                        self.allocator.free(change.content);
                    }
                    self.allocator.free(rhs.changes);
                }
            }
            self.allocator.free(chunk);
        }
        self.allocator.free(self.chunks);
        self.allocator.free(self.path);
        self.allocator.free(self.language);
    }
};

pub const DifftError = error{
    NotInstalled,
    CommandFailed,
    ParseError,
    InvalidJson,
    PipeFailed,
} || Allocator.Error;

/// Run a command and return stdout, using git.runCommand internally
fn runCommand(allocator: Allocator, cmd: []const u8) DifftError![]u8 {
    const result = git.runCommand(allocator, cmd) catch return DifftError.CommandFailed;
    return result.stdout;
}

/// Check if difft is installed (uses direct execution, no shell)
pub fn checkInstalled(allocator: Allocator, io: Io) !bool {
    // Use direct execution (no shell overhead)
    const result = shell.runDirect(allocator, io, &.{ "difft", "--version" }) catch {
        return false;
    };
    defer allocator.free(result.stdout);
    return result.stdout.len > 0;
}

/// Parse multiple file diffs from git's external diff output (one or more JSON objects)
/// Git invokes the external diff multiple times, once per file, so output may be multiple JSON objects
/// Returns array of FileDiff structs parsed from the output
pub fn parseGitDiffOutput(allocator: Allocator, json_output: []const u8) DifftError![]FileDiff {
    if (json_output.len == 0) {
        return &.{};
    }

    var diffs: std.ArrayList(FileDiff) = .empty;
    errdefer {
        for (diffs.items) |*diff| {
            diff.deinit();
        }
        diffs.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < json_output.len) {
        while (pos < json_output.len and std.ascii.isWhitespace(json_output[pos])) {
            pos += 1;
        }

        if (pos >= json_output.len) break;

        const start = pos;
        var depth: i32 = 0;
        var in_string = false;
        var escaped = false;

        while (pos < json_output.len) {
            const ch = json_output[pos];

            if (escaped) {
                escaped = false;
                pos += 1;
                continue;
            }

            if (ch == '\\') {
                escaped = true;
                pos += 1;
                continue;
            }

            if (ch == '"') {
                in_string = !in_string;
                pos += 1;
                continue;
            }

            if (!in_string) {
                if (ch == '{') depth += 1;
                if (ch == '}') depth -= 1;

                if (depth == 0 and ch == '}') {
                    pos += 1;
                    break;
                }
            }

            pos += 1;
        }

        const json_str = json_output[start..pos];
        if (json_str.len == 0) continue;

        const parsed = json.parseFromSlice(json.Value, allocator, json_str, .{}) catch {
            continue; // Skip malformed JSON objects
        };
        defer parsed.deinit();

        const file_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };

        const path = if (file_obj.get("path")) |p|
            try allocator.dupe(u8, p.string)
        else
            try allocator.dupe(u8, "unknown");

        const language = if (file_obj.get("language")) |l|
            try allocator.dupe(u8, l.string)
        else
            try allocator.dupe(u8, "Text");

        const status: DiffStatus = if (file_obj.get("status")) |s| blk: {
            const status_str = s.string;
            // Map difftastic status values to our enum
            // difftastic uses: "unchanged", "changed", "created", "deleted"
            if (std.mem.eql(u8, status_str, "created")) break :blk .added;
            if (std.mem.eql(u8, status_str, "deleted")) break :blk .removed;
            if (std.mem.eql(u8, status_str, "unchanged")) break :blk .unchanged;
            // Handle legacy/alternative naming
            if (std.mem.eql(u8, status_str, "added")) break :blk .added;
            if (std.mem.eql(u8, status_str, "removed")) break :blk .removed;
            break :blk .changed;
        } else .changed;

        const chunks_json = file_obj.get("chunks");

        var chunks: std.ArrayList([]const DiffEntry) = .empty;
        errdefer {
            for (chunks.items) |chunk| {
                for (chunk) |entry| {
                    if (entry.lhs) |lhs| {
                        for (lhs.changes) |change| {
                            allocator.free(change.content);
                        }
                        allocator.free(lhs.changes);
                    }
                    if (entry.rhs) |rhs| {
                        for (rhs.changes) |change| {
                            allocator.free(change.content);
                        }
                        allocator.free(rhs.changes);
                    }
                }
                allocator.free(chunk);
            }
            chunks.deinit(allocator);
        }

        if (chunks_json) |cj| {
            for (cj.array.items) |chunk_json| {
                var entries: std.ArrayList(DiffEntry) = .empty;
                errdefer entries.deinit(allocator);

                for (chunk_json.array.items) |entry_json| {
                    const entry_obj = entry_json.object;

                    const lhs = if (entry_obj.get("lhs")) |lhs_json|
                        try parseSide(allocator, lhs_json)
                    else
                        null;

                    const rhs = if (entry_obj.get("rhs")) |rhs_json|
                        try parseSide(allocator, rhs_json)
                    else
                        null;

                    try entries.append(allocator, .{ .lhs = lhs, .rhs = rhs });
                }

                try chunks.append(allocator, try entries.toOwnedSlice(allocator));
            }
        }

        try diffs.append(allocator, FileDiff{
            .path = path,
            .language = language,
            .status = status,
            .chunks = try chunks.toOwnedSlice(allocator),
            .allocator = allocator,
        });
    }

    return diffs.toOwnedSlice(allocator);
}

fn parseSide(allocator: Allocator, side_json: json.Value) DifftError!Side {
    const side_obj = side_json.object;

    const line_number: u32 = if (side_obj.get("line_number")) |ln|
        @intCast(ln.integer)
    else
        0;

    var changes: std.ArrayList(Change) = .empty;
    errdefer {
        for (changes.items) |change| {
            allocator.free(change.content);
        }
        changes.deinit(allocator);
    }

    if (side_obj.get("changes")) |changes_json| {
        for (changes_json.array.items) |change_json| {
            const change_obj = change_json.object;

            const start: u32 = if (change_obj.get("start")) |s|
                @intCast(s.integer)
            else
                0;

            const end: u32 = if (change_obj.get("end")) |e|
                @intCast(e.integer)
            else
                0;

            const content = if (change_obj.get("content")) |con|
                try allocator.dupe(u8, con.string)
            else
                try allocator.dupe(u8, "");

            const highlight: Highlight = if (change_obj.get("highlight")) |h| blk: {
                const hs = h.string;
                // Map difftastic's highlight types to our enum
                if (std.mem.eql(u8, hs, "delimiter")) break :blk .delimiter;
                if (std.mem.eql(u8, hs, "string")) break :blk .string;
                if (std.mem.eql(u8, hs, "type")) break :blk .type_;
                if (std.mem.eql(u8, hs, "comment")) break :blk .comment;
                if (std.mem.eql(u8, hs, "keyword")) break :blk .keyword;
                if (std.mem.eql(u8, hs, "tree_sitter_error")) break :blk .tree_sitter_error;
                if (std.mem.eql(u8, hs, "normal")) break :blk .normal;
                // Default case: treat as novel (changed) - difft outputs this for actual changes
                break :blk .novel;
            } else .normal;

            try changes.append(allocator, .{
                .start = start,
                .end = end,
                .content = content,
                .highlight = highlight,
            });
        }
    }

    return Side{
        .line_number = line_number,
        .changes = try changes.toOwnedSlice(allocator),
    };
}

/// Get file extension from path
pub fn getExtension(path: []const u8) ?[]const u8 {
    const basename = std.fs.path.basename(path);
    const dot_idx = std.mem.lastIndexOf(u8, basename, ".") orelse return null;
    if (dot_idx == 0) return null;
    return basename[dot_idx + 1 ..];
}

test "getExtension" {
    try std.testing.expectEqualStrings("zig", getExtension("src/main.zig").?);
    try std.testing.expectEqualStrings("json", getExtension("package.json").?);
    try std.testing.expect(getExtension(".gitignore") == null);
    try std.testing.expect(getExtension("Makefile") == null);
}

test "parseGitDiffOutput empty" {
    const allocator = std.testing.allocator;
    const diffs = try parseGitDiffOutput(allocator, "");
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "parseGitDiffOutput simple" {
    const allocator = std.testing.allocator;
    const json_input =
        \\{
        \\  "path": "src/main.zig",
        \\  "language": "Zig",
        \\  "status": "changed",
        \\  "chunks": [[
        \\    {
        \\      "lhs": {"line_number": 1, "changes": [{"start": 0, "end": 5, "content": "hello", "highlight": "normal"}]},
        \\      "rhs": {"line_number": 1, "changes": [{"start": 0, "end": 5, "content": "world", "highlight": "novel"}]}
        \\    }
        \\  ]]
        \\}
    ;

    const diffs = try parseGitDiffOutput(allocator, json_input);
    defer {
        for (@constCast(diffs)) |*diff| {
            diff.deinit();
        }
        allocator.free(diffs);
    }

    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqualStrings("src/main.zig", diffs[0].path);
    try std.testing.expectEqualStrings("Zig", diffs[0].language);
    try std.testing.expectEqual(DiffStatus.changed, diffs[0].status);
    try std.testing.expectEqual(@as(usize, 1), diffs[0].chunks.len);
}

test "parseGitDiffOutput semantic highlights" {
    const allocator = std.testing.allocator;
    // Test JSON with semantic highlight types from difftastic
    const json_input =
        \\{
        \\  "path": "test.rs",
        \\  "language": "Rust",
        \\  "status": "changed",
        \\  "chunks": [[
        \\    {
        \\      "lhs": {"line_number": 1, "changes": [
        \\        {"start": 0, "end": 2, "content": "fn", "highlight": "keyword"},
        \\        {"start": 3, "end": 7, "content": "main", "highlight": "normal"},
        \\        {"start": 7, "end": 8, "content": "(", "highlight": "delimiter"},
        \\        {"start": 8, "end": 9, "content": ")", "highlight": "delimiter"}
        \\      ]},
        \\      "rhs": {"line_number": 1, "changes": [
        \\        {"start": 0, "end": 3, "content": "pub", "highlight": "keyword"},
        \\        {"start": 4, "end": 6, "content": "fn", "highlight": "keyword"},
        \\        {"start": 7, "end": 11, "content": "main", "highlight": "normal"}
        \\      ]}
        \\    },
        \\    {
        \\      "lhs": {"line_number": 2, "changes": [
        \\        {"start": 4, "end": 17, "content": "\"Hello World\"", "highlight": "string"}
        \\      ]},
        \\      "rhs": {"line_number": 2, "changes": [
        \\        {"start": 4, "end": 12, "content": "\"Hi Rust\"", "highlight": "string"}
        \\      ]}
        \\    },
        \\    {
        \\      "lhs": {"line_number": 3, "changes": [
        \\        {"start": 0, "end": 20, "content": "// old comment here", "highlight": "comment"}
        \\      ]},
        \\      "rhs": {"line_number": 3, "changes": [
        \\        {"start": 0, "end": 20, "content": "// new comment here", "highlight": "comment"}
        \\      ]}
        \\    },
        \\    {
        \\      "lhs": {"line_number": 4, "changes": [
        \\        {"start": 4, "end": 7, "content": "i32", "highlight": "type"}
        \\      ]},
        \\      "rhs": {"line_number": 4, "changes": [
        \\        {"start": 4, "end": 7, "content": "u64", "highlight": "type"}
        \\      ]}
        \\    }
        \\  ]]
        \\}
    ;

    const diffs = try parseGitDiffOutput(allocator, json_input);
    defer {
        for (@constCast(diffs)) |*diff| {
            diff.deinit();
        }
        allocator.free(diffs);
    }

    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(@as(usize, 1), diffs[0].chunks.len);

    const entries = diffs[0].chunks[0];
    try std.testing.expectEqual(@as(usize, 4), entries.len);

    // First entry: keyword test
    const entry1 = entries[0];
    try std.testing.expect(entry1.lhs != null);
    try std.testing.expectEqual(@as(usize, 4), entry1.lhs.?.changes.len);
    try std.testing.expectEqual(Highlight.keyword, entry1.lhs.?.changes[0].highlight);
    try std.testing.expectEqual(Highlight.normal, entry1.lhs.?.changes[1].highlight);
    try std.testing.expectEqual(Highlight.delimiter, entry1.lhs.?.changes[2].highlight);

    // Second entry: string test
    const entry2 = entries[1];
    try std.testing.expect(entry2.lhs != null);
    try std.testing.expectEqual(Highlight.string, entry2.lhs.?.changes[0].highlight);

    // Third entry: comment test
    const entry3 = entries[2];
    try std.testing.expect(entry3.lhs != null);
    try std.testing.expectEqual(Highlight.comment, entry3.lhs.?.changes[0].highlight);

    // Fourth entry: type test
    const entry4 = entries[3];
    try std.testing.expect(entry4.lhs != null);
    try std.testing.expectEqual(Highlight.type_, entry4.lhs.?.changes[0].highlight);
}

test "Highlight.isNovel" {
    try std.testing.expect(!Highlight.normal.isNovel());
    try std.testing.expect(Highlight.novel.isNovel());
    try std.testing.expect(Highlight.keyword.isNovel());
    try std.testing.expect(Highlight.string.isNovel());
    try std.testing.expect(Highlight.comment.isNovel());
    try std.testing.expect(Highlight.type_.isNovel());
    try std.testing.expect(Highlight.delimiter.isNovel());
    try std.testing.expect(Highlight.tree_sitter_error.isNovel());
}

test "Highlight.isSemantic" {
    try std.testing.expect(!Highlight.normal.isSemantic());
    try std.testing.expect(!Highlight.novel.isSemantic());
    try std.testing.expect(Highlight.keyword.isSemantic());
    try std.testing.expect(Highlight.string.isSemantic());
    try std.testing.expect(Highlight.comment.isSemantic());
    try std.testing.expect(Highlight.type_.isSemantic());
    try std.testing.expect(Highlight.delimiter.isSemantic());
    try std.testing.expect(!Highlight.tree_sitter_error.isSemantic());
}

test "parseGitDiffOutput difftastic status values" {
    const allocator = std.testing.allocator;

    // Test "created" status (difftastic's term for new files)
    {
        const json_input =
            \\{"path": "new.txt", "language": "Text", "status": "created", "chunks": []}
        ;
        const diffs = try parseGitDiffOutput(allocator, json_input);
        defer {
            for (@constCast(diffs)) |*diff| {
                diff.deinit();
            }
            allocator.free(diffs);
        }
        try std.testing.expectEqual(DiffStatus.added, diffs[0].status);
    }

    // Test "deleted" status
    {
        const json_input =
            \\{"path": "old.txt", "language": "Text", "status": "deleted", "chunks": []}
        ;
        const diffs = try parseGitDiffOutput(allocator, json_input);
        defer {
            for (@constCast(diffs)) |*diff| {
                diff.deinit();
            }
            allocator.free(diffs);
        }
        try std.testing.expectEqual(DiffStatus.removed, diffs[0].status);
    }

    // Test "unchanged" status
    {
        const json_input =
            \\{"path": "same.txt", "language": "Text", "status": "unchanged", "chunks": []}
        ;
        const diffs = try parseGitDiffOutput(allocator, json_input);
        defer {
            for (@constCast(diffs)) |*diff| {
                diff.deinit();
            }
            allocator.free(diffs);
        }
        try std.testing.expectEqual(DiffStatus.unchanged, diffs[0].status);
    }

    // Test "changed" status
    {
        const json_input =
            \\{"path": "mod.txt", "language": "Text", "status": "changed", "chunks": []}
        ;
        const diffs = try parseGitDiffOutput(allocator, json_input);
        defer {
            for (@constCast(diffs)) |*diff| {
                diff.deinit();
            }
            allocator.free(diffs);
        }
        try std.testing.expectEqual(DiffStatus.changed, diffs[0].status);
    }
}

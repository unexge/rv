const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const FILE = opaque {};
extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn pclose(stream: *FILE) c_int;
extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;

pub const Highlight = enum {
    normal,
    novel,
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
    changed,
    added,
    removed,
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

/// Run a command using popen
fn runCommand(allocator: Allocator, cmd: []const u8) DifftError![]u8 {
    const cmd_z = allocator.dupeZ(u8, cmd) catch return DifftError.CommandFailed;
    defer allocator.free(cmd_z);

    const fp = popen(cmd_z.ptr, "r") orelse return DifftError.PipeFailed;

    var output: std.ArrayList(u8) = .empty;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        output.appendSlice(allocator, buf[0..n]) catch {
            output.deinit(allocator);
            _ = pclose(fp);
            return DifftError.CommandFailed;
        };
    }

    // Check exit status - pclose returns the child's exit status shifted
    // On macOS, the actual exit code is in bits 8-15
    const raw_status = pclose(fp);
    const exit_code = @as(c_int, @intCast((raw_status >> 8) & 0xFF));

    if (raw_status < 0 or exit_code > 1) {
        output.deinit(allocator);
        return DifftError.CommandFailed;
    }

    return output.toOwnedSlice(allocator);
}

/// Check if difft is installed
pub fn checkInstalled(allocator: Allocator) !bool {
    const result = runCommand(allocator, "difft --version 2>/dev/null") catch {
        return false;
    };
    defer allocator.free(result);
    return result.len > 0;
}

/// Run difft on two files and return parsed diff
pub fn runDifft(allocator: Allocator, old_path: []const u8, new_path: []const u8) DifftError!FileDiff {
    const cmd = try std.fmt.allocPrint(allocator, "DFT_UNSTABLE=yes difft --display json '{s}' '{s}' 2>/dev/null", .{ old_path, new_path });
    defer allocator.free(cmd);

    const result = try runCommand(allocator, cmd);
    defer allocator.free(result);

    return parseJson(allocator, result, new_path);
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

/// Run difft comparing old content with new file
pub fn runDifftWithContent(
    allocator: Allocator,
    io: Io,
    old_content: []const u8,
    new_path: []const u8,
    language_hint: ?[]const u8,
) DifftError!FileDiff {
    const ext_suffix = if (language_hint) |ext| ext else "tmp";

    var tmp_name_buf: [128]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, "/tmp/rv_old_content.{s}", .{ext_suffix}) catch return DifftError.CommandFailed;

    const file = Dir.createFileAbsolute(io, tmp_name, .{}) catch return DifftError.CommandFailed;
    defer Dir.deleteFileAbsolute(io, tmp_name) catch {};

    var write_buf: [4096]u8 = undefined;
    var writer: File.Writer = .init(file, io, &write_buf);
    writer.interface.writeAll(old_content) catch {
        file.close(io);
        return DifftError.CommandFailed;
    };
    writer.flush() catch {};
    file.close(io);

    return runDifft(allocator, tmp_name, new_path);
}

/// Run difft comparing two content strings (for commit review)
pub fn runDifftWithContents(
    allocator: Allocator,
    io: Io,
    old_content: []const u8,
    new_content: []const u8,
    language_hint: ?[]const u8,
    fallback_path: []const u8,
) DifftError!FileDiff {
    const ext_suffix = if (language_hint) |ext| ext else "tmp";

    var old_tmp_buf: [128]u8 = undefined;
    const old_tmp_name = std.fmt.bufPrint(&old_tmp_buf, "/tmp/rv_old_content.{s}", .{ext_suffix}) catch return DifftError.CommandFailed;

    const old_file = Dir.createFileAbsolute(io, old_tmp_name, .{}) catch return DifftError.CommandFailed;
    defer Dir.deleteFileAbsolute(io, old_tmp_name) catch {};
    {
        var old_write_buf: [4096]u8 = undefined;
        var writer: File.Writer = .init(old_file, io, &old_write_buf);
        writer.interface.writeAll(old_content) catch {
            old_file.close(io);
            return DifftError.CommandFailed;
        };
        writer.flush() catch {};
    }
    old_file.close(io);

    var new_tmp_buf: [128]u8 = undefined;
    const new_tmp_name = std.fmt.bufPrint(&new_tmp_buf, "/tmp/rv_new_content.{s}", .{ext_suffix}) catch return DifftError.CommandFailed;

    const new_file = Dir.createFileAbsolute(io, new_tmp_name, .{}) catch return DifftError.CommandFailed;
    defer Dir.deleteFileAbsolute(io, new_tmp_name) catch {};
    {
        var new_write_buf: [4096]u8 = undefined;
        var writer: File.Writer = .init(new_file, io, &new_write_buf);
        writer.interface.writeAll(new_content) catch {
            new_file.close(io);
            return DifftError.CommandFailed;
        };
        writer.flush() catch {};
    }
    new_file.close(io);

    var diff = try runDifft(allocator, old_tmp_name, new_tmp_name);

    allocator.free(diff.path);
    diff.path = try allocator.dupe(u8, fallback_path);

    return diff;
}

fn parseJson(allocator: Allocator, json_str: []const u8, fallback_path: []const u8) DifftError!FileDiff {
    if (json_str.len == 0) {
        return FileDiff{
            .path = try allocator.dupe(u8, fallback_path),
            .language = try allocator.dupe(u8, ""),
            .status = .changed,
            .chunks = &.{},
            .allocator = allocator,
        };
    }

    const parsed = json.parseFromSlice(json.Value, allocator, json_str, .{}) catch {
        return DifftError.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;

    const file_obj = switch (root) {
        .object => |obj| obj,
        .array => |arr| blk: {
            if (arr.items.len == 0) {
                return FileDiff{
                    .path = try allocator.dupe(u8, fallback_path),
                    .language = try allocator.dupe(u8, ""),
                    .status = .changed,
                    .chunks = &.{},
                    .allocator = allocator,
                };
            }
            break :blk arr.items[0].object;
        },
        else => return DifftError.InvalidJson,
    };

    const path = if (file_obj.get("path")) |p|
        try allocator.dupe(u8, p.string)
    else
        try allocator.dupe(u8, fallback_path);

    const language = if (file_obj.get("language")) |l|
        try allocator.dupe(u8, l.string)
    else
        try allocator.dupe(u8, "Text");

    const status: DiffStatus = if (file_obj.get("status")) |s| blk: {
        const status_str = s.string;
        if (std.mem.eql(u8, status_str, "added")) break :blk .added;
        if (std.mem.eql(u8, status_str, "removed")) break :blk .removed;
        break :blk .changed;
    } else .changed;

    const chunks_json = file_obj.get("chunks") orelse {
        return FileDiff{
            .path = path,
            .language = language,
            .status = status,
            .chunks = &.{},
            .allocator = allocator,
        };
    };

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

    for (chunks_json.array.items) |chunk_json| {
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

    return FileDiff{
        .path = path,
        .language = language,
        .status = status,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };
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
                if (std.mem.eql(u8, h.string, "novel")) break :blk .novel;
                break :blk .normal;
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

test "parseJson empty" {
    const allocator = std.testing.allocator;
    var diff = try parseJson(allocator, "", "test.zig");
    defer diff.deinit();

    try std.testing.expectEqualStrings("test.zig", diff.path);
    try std.testing.expectEqual(@as(usize, 0), diff.chunks.len);
}

test "parseJson simple" {
    const allocator = std.testing.allocator;
    const json_input =
        \\[{
        \\  "path": "src/main.zig",
        \\  "language": "Zig",
        \\  "status": "changed",
        \\  "chunks": [[
        \\    {
        \\      "lhs": {"line_number": 1, "changes": [{"start": 0, "end": 5, "content": "hello", "highlight": "normal"}]},
        \\      "rhs": {"line_number": 1, "changes": [{"start": 0, "end": 5, "content": "world", "highlight": "novel"}]}
        \\    }
        \\  ]]
        \\}]
    ;

    var diff = try parseJson(allocator, json_input, "fallback.zig");
    defer diff.deinit();

    try std.testing.expectEqualStrings("src/main.zig", diff.path);
    try std.testing.expectEqualStrings("Zig", diff.language);
    try std.testing.expectEqual(DiffStatus.changed, diff.status);
    try std.testing.expectEqual(@as(usize, 1), diff.chunks.len);
}

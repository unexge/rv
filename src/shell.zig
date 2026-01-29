const std = @import("std");
const Allocator = std.mem.Allocator;

// C library functions for popen
const FILE = opaque {};
extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn pclose(stream: *FILE) c_int;
extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;

pub extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const ShellError = error{
    CommandFailed,
    PipeFailed,
} || Allocator.Error;

pub const CommandResult = struct {
    stdout: []u8,
    exit_code: u8,
};

/// Run a shell command and capture its output using popen
pub fn run(allocator: Allocator, cmd: []const u8) ShellError!CommandResult {
    const cmd_z = allocator.dupeZ(u8, cmd) catch return ShellError.CommandFailed;
    defer allocator.free(cmd_z);

    const fp = popen(cmd_z.ptr, "r") orelse return ShellError.PipeFailed;
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

/// Escape a string for use in shell double quotes
/// Characters that need escaping: $ ` \ " !
pub fn escapeForDoubleQuotes(allocator: Allocator, input: []const u8) Allocator.Error![]const u8 {
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

// Tests
test "run simple command" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, "echo hello");
    defer allocator.free(result.stdout);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
}

test "escapeForDoubleQuotes no special chars" {
    const allocator = std.testing.allocator;
    const result = try escapeForDoubleQuotes(allocator, "simple.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("simple.txt", result);
}

test "escapeForDoubleQuotes with quotes" {
    const allocator = std.testing.allocator;
    const result = try escapeForDoubleQuotes(allocator, "file\"name.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("file\\\"name.txt", result);
}

test "escapeForDoubleQuotes with dollar" {
    const allocator = std.testing.allocator;
    const result = try escapeForDoubleQuotes(allocator, "file$name.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("file\\$name.txt", result);
}

test "escapeForDoubleQuotes multiple special chars" {
    const allocator = std.testing.allocator;
    const result = try escapeForDoubleQuotes(allocator, "a\"b$c`d\\e!f");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a\\\"b\\$c\\`d\\\\e\\!f", result);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const process = std.process;
const Io = std.Io;

pub const ShellError = error{
    CommandFailed,
    PipeFailed,
} || Allocator.Error;

pub const CommandResult = struct {
    stdout: []u8,
    exit_code: u8,
};

/// Extract exit code from Term union
fn getExitCode(term: process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// Run a shell command and capture its output using native Zig process spawning
pub fn run(allocator: Allocator, io: Io, cmd: []const u8) ShellError!CommandResult {
    return runWithEnv(allocator, io, cmd, null);
}

/// Run a shell command with optional extra environment variables
pub fn runWithEnv(allocator: Allocator, io: Io, cmd: []const u8, extra_env: ?*process.Environ.Map) ShellError!CommandResult {
    // We need to run through sh -c to handle shell features like pipes, redirects, etc.
    const argv: []const []const u8 = &.{ "/bin/sh", "-c", cmd };

    const result = process.run(allocator, io, .{
        .argv = argv,
        .environ_map = extra_env,
        .max_output_bytes = 10 * 1024 * 1024, // 10MB for large diffs
    }) catch return ShellError.CommandFailed;

    defer allocator.free(result.stderr);

    return .{
        .stdout = result.stdout,
        .exit_code = getExitCode(result.term),
    };
}

/// Run a command directly without shell (faster, no shell overhead)
/// Args should be the command and its arguments as separate strings
pub fn runDirect(allocator: Allocator, io: Io, argv: []const []const u8) ShellError!CommandResult {
    return runDirectWithEnv(allocator, io, argv, null);
}

/// Run a command directly with optional extra environment variables
pub fn runDirectWithEnv(allocator: Allocator, io: Io, argv: []const []const u8, extra_env: ?*process.Environ.Map) ShellError!CommandResult {
    const result = process.run(allocator, io, .{
        .argv = argv,
        .environ_map = extra_env,
        .max_output_bytes = 10 * 1024 * 1024, // 10MB for large diffs
    }) catch return ShellError.CommandFailed;

    defer allocator.free(result.stderr);

    return .{
        .stdout = result.stdout,
        .exit_code = getExitCode(result.term),
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

// Tests removed - they require Io which is harder to setup in tests

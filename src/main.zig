const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const git = @import("git.zig");
const difft = @import("difft.zig");
const review = @import("review.zig");
const ui = @import("ui.zig");
const highlight = @import("highlight.zig");

const Args = struct {
    staged: bool = false,
    commit: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    help: bool = false,
    err: ?[]const u8 = null,
};

fn parseArgs(allocator: Allocator, args: []const []const u8) !Args {
    var result = Args{};
    var paths: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "-s")) {
            result.staged = true;
        } else if (std.mem.eql(u8, arg, "--commit") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i < args.len) {
                result.commit = args[i];
            } else {
                result.err = "--commit requires a revision argument";
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            result.err = "Unknown option";
        } else {
            try paths.append(allocator, arg);
        }
    }

    result.paths = try paths.toOwnedSlice(allocator);
    return result;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\rv - A local code review tool for the agentic world
        \\
        \\Usage: rv [options] [paths...]
        \\
        \\Options:
        \\  --staged, -s     Review staged changes (git diff --cached)
        \\  --commit, -c REV Review changes from a specific commit
        \\  --help, -h       Show this help message
        \\
        \\Examples:
        \\  rv               Review working directory changes
        \\  rv --staged      Review staged changes
        \\  rv src/main.zig  Review specific file(s)
        \\  rv -c HEAD~1     Review changes from the last commit
        \\
        \\Controls:
        \\  ↑/↓              Navigate lines
        \\  Shift+↑/↓        Select lines
        \\  ←/→              Previous/next file
        \\  c                Add comment at cursor/selection
        \\  a                Ask Pi about selected code
        \\  v                Toggle split/unified view
        \\  Tab              Toggle focus side (old/new)
        \\  l                Show file list
        \\  Esc              Clear selection
        \\  q                Quit and export markdown to stdout
        \\  ?                Show help
        \\
        \\Requirements:
        \\  - difft (difftastic) must be installed
        \\  - Must be run inside a git repository
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator: Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;

    const argv = try init.minimal.args.toSlice(allocator);

    const args = try parseArgs(allocator, argv);

    if (args.err) |err_msg| {
        try stderr.print("Error: {s}\n", .{err_msg});
        try stderr.writeAll("Run 'rv --help' for usage.\n");
        try stderr.flush();
        std.process.exit(1);
    }

    if (args.help) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    const difft_installed = try difft.checkInstalled(allocator);
    if (!difft_installed) {
        try stderr.writeAll(
            \\Error: difft (difftastic) is not installed.
            \\
            \\Please install it:
            \\  macOS:  brew install difftastic
            \\  Ubuntu: cargo install difftastic
            \\  Arch:   pacman -S difftastic
            \\
            \\See: https://difftastic.wilfred.me.uk/installation.html
            \\
        );
        try stderr.flush();
        std.process.exit(1);
    }

    _ = git.getRepoRoot(allocator) catch |err| {
        if (err == git.GitError.NotARepository) {
            try stderr.writeAll("Error: Not inside a git repository.\n");
        } else {
            try stderr.print("Error: Failed to get git root: {}\n", .{err});
        }
        try stderr.flush();
        std.process.exit(1);
    };

    // Get changed files for filtering
    const changed_files = if (args.commit) |commit|
        try git.getChangedFilesForCommit(allocator, commit)
    else
        try git.getChangedFiles(allocator, args.staged);

    // Filter paths if specified
    var filtered_paths: std.ArrayList([]const u8) = .empty;
    defer filtered_paths.deinit(allocator);

    if (args.paths.len > 0) {
        for (changed_files) |file| {
            for (args.paths) |path| {
                if (std.mem.indexOf(u8, file.path, path) != null) {
                    try filtered_paths.append(allocator, file.path);
                    break;
                }
            }
        }
    } else {
        for (changed_files) |file| {
            try filtered_paths.append(allocator, file.path);
        }
    }

    if (filtered_paths.items.len == 0) {
        try stderr.writeAll("No changes to review.\n");
        try stderr.flush();
        return;
    }

    // Run git diff with external difft tool
    const diff_json = try git.runGitDiffWithDifft(allocator, args.staged, args.commit, filtered_paths.items);
    defer allocator.free(diff_json);

    // Parse all file diffs from the output
    const file_diffs = try difft.parseGitDiffOutput(allocator, diff_json);
    defer allocator.free(file_diffs);

    if (file_diffs.len == 0) {
        try stderr.writeAll("No changes to review.\n");
        try stderr.flush();
        return;
    }

    // Get repo root once for all files
    const repo_root = try git.getRepoRoot(allocator);

    // Initialize review session
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Add each diff to the session
    for (file_diffs) |file_diff| {
        // Fetch file contents for display
        var old_content: []const u8 = "";
        var new_content: []const u8 = "";

        if (args.commit) |commit| {
            // For commit review, get contents from commit and its parent
            const parent_rev = try std.fmt.allocPrint(allocator, "{s}^", .{commit});
            defer allocator.free(parent_rev);

            old_content = (try git.getFileAtRevision(allocator, file_diff.path, parent_rev)) orelse "";

            // For deleted files, there is no new content
            if (file_diff.status == .removed) {
                new_content = "";
            } else {
                new_content = (try git.getFileAtRevision(allocator, file_diff.path, commit)) orelse "";
            }
        } else {
            // For working directory/staged changes
            if (file_diff.status == .added) {
                // For added files, there is no old content
                old_content = "";
                const full_path = try std.fs.path.join(allocator, &.{ repo_root, file_diff.path });
                new_content = git.readFileContent(allocator, full_path) catch "";
            } else if (file_diff.status == .removed) {
                // For deleted files, old comes from HEAD/index, new is empty
                const rev = if (args.staged) ":" else "HEAD";
                old_content = (try git.getFileAtRevision(allocator, file_diff.path, rev)) orelse "";
                new_content = "";
            } else {
                // For modified files, get both from git and filesystem
                const rev = if (args.staged) ":" else "HEAD";
                old_content = (try git.getFileAtRevision(allocator, file_diff.path, rev)) orelse "";
                const full_path = try std.fs.path.join(allocator, &.{ repo_root, file_diff.path });
                new_content = git.readFileContent(allocator, full_path) catch "";
            }
        }

        // Determine if file is binary
        const is_binary = git.isBinaryFile(old_content) or git.isBinaryFile(new_content);

        try session.addFile(.{
            .path = try allocator.dupe(u8, file_diff.path),
            .diff = file_diff,
            .is_binary = is_binary,
            .old_content = old_content,
            .new_content = new_content,
        });
    }

    if (session.files.len == 0) {
        try stderr.writeAll("No files could be processed.\n");
        try stderr.flush();
        return;
    }

    // Flush stderr before TUI
    try stderr.flush();

    // Run TUI using vaxis/vxfw
    var tui = ui.UI.init(allocator, &session);
    defer tui.deinit();

    // Set the project path for ask context
    tui.setProjectPath(repo_root);

    var run_error: ?anyerror = null;
    tui.run(init) catch |err| {
        run_error = err;
    };

    // Check for errors and exit after cleanup
    if (run_error) |err| {
        try stderr.print("UI error: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    }

    // Export markdown to stdout if we quit normally (not Ctrl+C)
    if (tui.should_quit) {
        try session.exportMarkdown(stdout);
        try stdout.flush();
    }
}

test "parseArgs" {
    const allocator = std.testing.allocator;

    {
        const args = try parseArgs(allocator, &.{ "rv", "--staged" });
        defer allocator.free(args.paths);
        try std.testing.expect(args.staged);
        try std.testing.expect(!args.help);
        try std.testing.expect(args.err == null);
    }

    {
        const args = try parseArgs(allocator, &.{ "rv", "-h" });
        defer allocator.free(args.paths);
        try std.testing.expect(args.help);
    }

    {
        const args = try parseArgs(allocator, &.{ "rv", "src/main.zig", "src/lib.zig" });
        defer allocator.free(args.paths);
        try std.testing.expectEqual(@as(usize, 2), args.paths.len);
    }

    // Missing commit value
    {
        const args = try parseArgs(allocator, &.{ "rv", "--commit" });
        defer allocator.free(args.paths);
        try std.testing.expect(args.err != null);
    }

    // Unknown option
    {
        const args = try parseArgs(allocator, &.{ "rv", "--unknown" });
        defer allocator.free(args.paths);
        try std.testing.expect(args.err != null);
    }
}

// Reference all module tests to include them in the test build
comptime {
    _ = git;
    _ = difft;
    _ = review;
    _ = ui;
    _ = highlight;
    _ = @import("pi.zig");
    _ = @import("shell.zig");
}

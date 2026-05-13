//! Subprocess-based git backend for the VCS module.
//!
//! Shells out to the `git` binary for every operation. No libgit2
//! dependency. All paths and returned `FileChange` slices are owned by
//! the `GitRepo`'s arena; `loadOld` / `loadNew` return caller-owned
//! buffers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const rv = @import("rv");
const vcs = @import("mod.zig");

pub const DiscoverError = error{
    NotARepository,
    GitNotFound,
    GitFailed,
    OutOfMemory,
};

pub const ListError = error{
    GitFailed,
    ParseFailed,
    OutOfMemory,
};

pub const LoadError = error{
    GitFailed,
    NotFound,
    OutOfMemory,
};

/// Repository handle. Discovered from the current working directory; used
/// for the lifetime of a repo-mode session.
pub const GitRepo = struct {
    gpa: Allocator,
    io: Io,
    /// Absolute path to the repository root. Arena-owned.
    root: []const u8,
    /// Owns path strings and `FileChange` slices returned by
    /// `listChanges`. Reset on `deinit`.
    arena: std.heap.ArenaAllocator,

    /// Resolve the enclosing git repository from the process's current
    /// directory. Runs `git rev-parse --show-toplevel`.
    pub fn discover(gpa: Allocator, io: Io) DiscoverError!GitRepo {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        const result = std.process.run(gpa, io, .{
            .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        }) catch |err| return mapDiscoverRunError(err);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) {
                if (std.mem.indexOf(u8, result.stderr, "not a git repository") != null) {
                    return error.NotARepository;
                }
                return error.GitFailed;
            },
            else => return error.GitFailed,
        }

        const trimmed = std.mem.trimEnd(u8, result.stdout, "\n");
        const root = try arena.allocator().dupe(u8, trimmed);

        return .{
            .gpa = gpa,
            .io = io,
            .root = root,
            .arena = arena,
        };
    }

    pub fn deinit(self: *GitRepo) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Enumerate all files with HEAD-vs-worktree differences, in git's
    /// natural (alphabetical) order. Returned slice is arena-owned.
    pub fn listChanges(self: *GitRepo) ListError![]vcs.FileChange {
        const name_status = self.runGitCollect(&.{ "diff", "HEAD", "--name-status", "-z" }) catch |err| return mapListRunError(err);
        defer self.gpa.free(name_status.stdout);
        defer self.gpa.free(name_status.stderr);
        if (!termOk(name_status.term)) return error.GitFailed;

        const numstat = self.runGitCollect(&.{ "diff", "HEAD", "--numstat", "-z" }) catch |err| return mapListRunError(err);
        defer self.gpa.free(numstat.stdout);
        defer self.gpa.free(numstat.stderr);
        if (!termOk(numstat.term)) return error.GitFailed;

        var numstat_map: std.StringHashMapUnmanaged(NumstatEntry) = .empty;
        defer numstat_map.deinit(self.gpa);
        try parseNumstat(self.gpa, numstat.stdout, &numstat_map);

        const arena_alloc = self.arena.allocator();

        var out: std.ArrayList(vcs.FileChange) = .empty;
        defer out.deinit(self.gpa);

        var it: NameStatusIter = .{ .data = name_status.stdout, .pos = 0 };
        while (try it.next()) |entry| {
            const initial_kind: vcs.ChangeKind = switch (entry.status[0]) {
                'M' => .modified,
                'A' => .added,
                'D' => .deleted,
                'R' => .renamed,
                else => return error.ParseFailed,
            };

            const old_raw: ?[]const u8 = if (initial_kind == .added) null else entry.p1;
            const new_raw: ?[]const u8 = switch (initial_kind) {
                .deleted => null,
                .renamed => entry.p2,
                else => entry.p1,
            };

            // numstat is keyed by the new path for all non-deletion entries
            // and by the old path for deletions.
            const lookup_key = new_raw orelse old_raw.?;

            var kind = initial_kind;
            var stat = vcs.LineStat{ .added = 0, .removed = 0 };
            if (numstat_map.get(lookup_key)) |ne| {
                if (ne.is_binary) {
                    kind = .binary;
                } else {
                    stat = .{ .added = ne.added, .removed = ne.removed };
                }
            }

            if (kind != .binary) {
                const probe_path = new_raw orelse old_raw.?;
                if (rv.languageFromPath(probe_path) == null) {
                    kind = .unsupported;
                    stat = .{ .added = 0, .removed = 0 };
                }
            }

            const old_path = if (old_raw) |p| try arena_alloc.dupe(u8, p) else null;
            const new_path = if (new_raw) |p| try arena_alloc.dupe(u8, p) else null;

            try out.append(self.gpa, .{
                .kind = kind,
                .old_path = old_path,
                .new_path = new_path,
                .line_stat = stat,
            });
        }

        return try arena_alloc.dupe(vcs.FileChange, out.items);
    }

    /// Read the pre-change bytes of `change` from `HEAD`
    /// (`git show HEAD:<old_path>`). Caller owns the returned buffer.
    pub fn loadOld(self: *GitRepo, gpa: Allocator, change: vcs.FileChange) LoadError![]u8 {
        const old = change.old_path orelse return error.NotFound;

        const spec = try std.fmt.allocPrint(self.gpa, "HEAD:{s}", .{old});
        defer self.gpa.free(spec);

        const result = self.runGit(gpa, &.{ "show", spec }) catch |err| return mapLoadRunError(err);
        defer gpa.free(result.stderr);
        errdefer gpa.free(result.stdout);

        if (!termOk(result.term)) return error.GitFailed;
        return result.stdout;
    }

    /// Read the post-change bytes of `change` from the worktree. Caller
    /// owns the returned buffer.
    pub fn loadNew(self: *GitRepo, gpa: Allocator, change: vcs.FileChange) LoadError![]u8 {
        const new = change.new_path orelse return error.NotFound;

        var root_dir = Io.Dir.openDirAbsolute(self.io, self.root, .{}) catch {
            return error.GitFailed;
        };
        defer root_dir.close(self.io);

        return root_dir.readFileAlloc(self.io, new, gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound => error.NotFound,
            else => error.GitFailed,
        };
    }

    // ── internal helpers ───────────────────────────────────────────────

    /// Convenience: `runGit` with `self.gpa` as the result allocator and
    /// any spawn/IO failure mapped to a broader `anyerror`.
    fn runGitCollect(self: *GitRepo, argv: []const []const u8) !std.process.RunResult {
        return self.runGit(self.gpa, argv);
    }

    fn runGit(self: *GitRepo, gpa: Allocator, argv: []const []const u8) !std.process.RunResult {
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(self.gpa);
        try full.ensureTotalCapacity(self.gpa, argv.len + 1);
        full.appendAssumeCapacity("git");
        for (argv) |a| full.appendAssumeCapacity(a);

        return std.process.run(gpa, self.io, .{
            .argv = full.items,
            .cwd = .{ .path = self.root },
        });
    }
};

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn mapDiscoverRunError(err: anyerror) DiscoverError {
    return switch (err) {
        error.FileNotFound => error.GitNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.GitFailed,
    };
}

fn mapListRunError(err: anyerror) ListError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.GitFailed,
    };
}

fn mapLoadRunError(err: anyerror) LoadError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.GitFailed,
    };
}

// ── `--name-status -z` parser ──────────────────────────────────────────

const NameStatusEntry = struct {
    status: []const u8,
    p1: []const u8,
    /// Set for renames (`R`) and copies (`C`); null otherwise.
    p2: ?[]const u8,
};

const NameStatusIter = struct {
    data: []const u8,
    pos: usize,

    fn next(self: *NameStatusIter) ListError!?NameStatusEntry {
        if (self.pos >= self.data.len) return null;

        const status = try self.readField();
        if (status.len == 0) return error.ParseFailed;

        const p1 = try self.readField();

        if (status[0] == 'R' or status[0] == 'C') {
            const p2 = try self.readField();
            return .{ .status = status, .p1 = p1, .p2 = p2 };
        }

        return .{ .status = status, .p1 = p1, .p2 = null };
    }

    fn readField(self: *NameStatusIter) ListError![]const u8 {
        if (self.pos >= self.data.len) return error.ParseFailed;
        const end = std.mem.indexOfScalarPos(u8, self.data, self.pos, 0) orelse
            return error.ParseFailed;
        const out = self.data[self.pos..end];
        self.pos = end + 1;
        return out;
    }
};

// ── `--numstat -z` parser ──────────────────────────────────────────────

const NumstatEntry = struct {
    added: u32,
    removed: u32,
    is_binary: bool,
};

/// `--numstat -z` format:
///   "<added>\t<removed>\t<path>\0"                       for non-renames
///   "<added>\t<removed>\t\0<old-path>\0<new-path>\0"     for renames
/// Keyed by the new path (or the sole path for non-renames).
fn parseNumstat(
    gpa: Allocator,
    data: []const u8,
    out: *std.StringHashMapUnmanaged(NumstatEntry),
) ListError!void {
    var pos: usize = 0;
    while (pos < data.len) {
        const added_end = std.mem.indexOfScalarPos(u8, data, pos, '\t') orelse
            return error.ParseFailed;
        const added_str = data[pos..added_end];
        pos = added_end + 1;

        const removed_end = std.mem.indexOfScalarPos(u8, data, pos, '\t') orelse
            return error.ParseFailed;
        const removed_str = data[pos..removed_end];
        pos = removed_end + 1;

        const first_end = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse
            return error.ParseFailed;
        var path = data[pos..first_end];
        pos = first_end + 1;

        if (path.len == 0) {
            // rename: skip old path, take new path.
            const old_end = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse
                return error.ParseFailed;
            pos = old_end + 1;

            const new_end = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse
                return error.ParseFailed;
            path = data[pos..new_end];
            pos = new_end + 1;
        }

        const is_binary = std.mem.eql(u8, added_str, "-") and std.mem.eql(u8, removed_str, "-");
        const added: u32 = if (is_binary) 0 else std.fmt.parseInt(u32, added_str, 10) catch
            return error.ParseFailed;
        const removed: u32 = if (is_binary) 0 else std.fmt.parseInt(u32, removed_str, 10) catch
            return error.ParseFailed;

        try out.put(gpa, path, .{
            .added = added,
            .removed = removed,
            .is_binary = is_binary,
        });
    }
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Helper: a git repo inside a throwaway temp dir, with one committed
/// baseline. Call `writeFile` / `deleteFile` / `runGit` to mutate the
/// worktree, then run `GitRepo.discover` + `listChanges`.
const TestRepo = struct {
    tmp: testing.TmpDir,
    root: []u8,

    fn init(gpa: Allocator) !TestRepo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try gpa.dupe(u8, buf[0..n]);
        errdefer gpa.free(root);

        var self: TestRepo = .{ .tmp = tmp, .root = root };
        try self.runGit(gpa, &.{ "init", "-q", "-b", "main" });
        try self.runGit(gpa, &.{ "config", "user.email", "rv@example.com" });
        try self.runGit(gpa, &.{ "config", "user.name", "rv" });
        return self;
    }

    fn deinit(self: *TestRepo, gpa: Allocator) void {
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn runGit(self: *TestRepo, gpa: Allocator, argv: []const []const u8) !void {
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(gpa);
        try full.ensureTotalCapacity(gpa, argv.len + 1);
        full.appendAssumeCapacity("git");
        for (argv) |a| full.appendAssumeCapacity(a);

        const result = try std.process.run(gpa, testing.io, .{
            .argv = full.items,
            .cwd = .{ .path = self.root },
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (!termOk(result.term)) {
            std.debug.print("git {s} failed: {s}\n", .{ argv[0], result.stderr });
            return error.TestGitFailed;
        }
    }

    fn writeFile(self: *TestRepo, path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn deleteFile(self: *TestRepo, path: []const u8) !void {
        try self.tmp.dir.deleteFile(testing.io, path);
    }

    fn commitAll(self: *TestRepo, gpa: Allocator, msg: []const u8) !void {
        try self.runGit(gpa, &.{ "add", "-A" });
        try self.runGit(gpa, &.{ "commit", "-q", "-m", msg });
    }

    fn discover(self: *TestRepo, gpa: Allocator) !GitRepo {
        // GitRepo.discover runs from cwd, but our tests need to pin the
        // repo root regardless of where the test binary was launched. We
        // build one directly instead of changing process cwd.
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const root = try arena.allocator().dupe(u8, self.root);
        return .{
            .gpa = gpa,
            .io = testing.io,
            .root = root,
            .arena = arena,
        };
    }
};

test "parseNumstat: non-rename" {
    var map: std.StringHashMapUnmanaged(NumstatEntry) = .empty;
    defer map.deinit(testing.allocator);
    try parseNumstat(testing.allocator, "3\t1\tfoo.zig\x00", &map);
    const e = map.get("foo.zig").?;
    try testing.expectEqual(@as(u32, 3), e.added);
    try testing.expectEqual(@as(u32, 1), e.removed);
    try testing.expect(!e.is_binary);
}

test "parseNumstat: binary" {
    var map: std.StringHashMapUnmanaged(NumstatEntry) = .empty;
    defer map.deinit(testing.allocator);
    try parseNumstat(testing.allocator, "-\t-\timg.png\x00", &map);
    const e = map.get("img.png").?;
    try testing.expect(e.is_binary);
    try testing.expectEqual(@as(u32, 0), e.added);
    try testing.expectEqual(@as(u32, 0), e.removed);
}

test "parseNumstat: rename" {
    var map: std.StringHashMapUnmanaged(NumstatEntry) = .empty;
    defer map.deinit(testing.allocator);
    try parseNumstat(testing.allocator, "4\t2\t\x00old.zig\x00new.zig\x00", &map);
    const e = map.get("new.zig").?;
    try testing.expectEqual(@as(u32, 4), e.added);
    try testing.expectEqual(@as(u32, 2), e.removed);
}

test "listChanges: modified file" {
    const gpa = testing.allocator;
    var tr = try TestRepo.init(gpa);
    defer tr.deinit(gpa);

    try tr.writeFile("a.zig", "pub fn a() void {}\n");
    try tr.commitAll(gpa, "init");
    try tr.writeFile("a.zig", "pub fn a() void { return; }\n");

    var repo = try tr.discover(gpa);
    defer repo.deinit();

    const changes = try repo.listChanges();
    try testing.expectEqual(@as(usize, 1), changes.len);
    const c = changes[0];
    try testing.expectEqual(vcs.ChangeKind.modified, c.kind);
    try testing.expectEqualStrings("a.zig", c.old_path.?);
    try testing.expectEqualStrings("a.zig", c.new_path.?);
    try testing.expectEqual(@as(u32, 1), c.line_stat.added);
    try testing.expectEqual(@as(u32, 1), c.line_stat.removed);

    const old_bytes = try repo.loadOld(gpa, c);
    defer gpa.free(old_bytes);
    try testing.expectEqualStrings("pub fn a() void {}\n", old_bytes);

    const new_bytes = try repo.loadNew(gpa, c);
    defer gpa.free(new_bytes);
    try testing.expectEqualStrings("pub fn a() void { return; }\n", new_bytes);
}

test "listChanges: deleted file" {
    const gpa = testing.allocator;
    var tr = try TestRepo.init(gpa);
    defer tr.deinit(gpa);

    try tr.writeFile("gone.zig", "const x = 1;\n");
    try tr.commitAll(gpa, "init");
    try tr.deleteFile("gone.zig");

    var repo = try tr.discover(gpa);
    defer repo.deinit();

    const changes = try repo.listChanges();
    try testing.expectEqual(@as(usize, 1), changes.len);
    const c = changes[0];
    try testing.expectEqual(vcs.ChangeKind.deleted, c.kind);
    try testing.expectEqualStrings("gone.zig", c.old_path.?);
    try testing.expect(c.new_path == null);

    const old_bytes = try repo.loadOld(gpa, c);
    defer gpa.free(old_bytes);
    try testing.expectEqualStrings("const x = 1;\n", old_bytes);

    try testing.expectError(error.NotFound, repo.loadNew(gpa, c));
}

test "listChanges: renamed file" {
    const gpa = testing.allocator;
    var tr = try TestRepo.init(gpa);
    defer tr.deinit(gpa);

    try tr.writeFile("old.zig", "pub fn f() void {}\n");
    try tr.commitAll(gpa, "init");
    try tr.runGit(gpa, &.{ "mv", "old.zig", "new.zig" });

    var repo = try tr.discover(gpa);
    defer repo.deinit();

    const changes = try repo.listChanges();
    try testing.expectEqual(@as(usize, 1), changes.len);
    const c = changes[0];
    try testing.expectEqual(vcs.ChangeKind.renamed, c.kind);
    try testing.expectEqualStrings("old.zig", c.old_path.?);
    try testing.expectEqualStrings("new.zig", c.new_path.?);

    const old_bytes = try repo.loadOld(gpa, c);
    defer gpa.free(old_bytes);
    try testing.expectEqualStrings("pub fn f() void {}\n", old_bytes);

    const new_bytes = try repo.loadNew(gpa, c);
    defer gpa.free(new_bytes);
    try testing.expectEqualStrings("pub fn f() void {}\n", new_bytes);
}

test "listChanges: binary file" {
    const gpa = testing.allocator;
    var tr = try TestRepo.init(gpa);
    defer tr.deinit(gpa);

    // A byte sequence with NUL and 0xFF to force git's binary detection.
    const before_png = "\x89PNG\r\n\x1a\n" ++ [_]u8{0} ** 16 ++ "\xFF\xFE\xFD\xFC";
    const after_png = "\x89PNG\r\n\x1a\n" ++ [_]u8{1} ** 16 ++ "\xFF\x00\xFF\x00";

    try tr.writeFile("img.png", before_png);
    try tr.commitAll(gpa, "init");
    try tr.writeFile("img.png", after_png);

    var repo = try tr.discover(gpa);
    defer repo.deinit();

    const changes = try repo.listChanges();
    try testing.expectEqual(@as(usize, 1), changes.len);
    const c = changes[0];
    try testing.expectEqual(vcs.ChangeKind.binary, c.kind);
    try testing.expectEqual(@as(u32, 0), c.line_stat.added);
    try testing.expectEqual(@as(u32, 0), c.line_stat.removed);

    const new_bytes = try repo.loadNew(gpa, c);
    defer gpa.free(new_bytes);
    try testing.expectEqualSlices(u8, after_png, new_bytes);
}

test "listChanges: unsupported extension" {
    const gpa = testing.allocator;
    var tr = try TestRepo.init(gpa);
    defer tr.deinit(gpa);

    try tr.writeFile("notes.xyz", "hello\n");
    try tr.commitAll(gpa, "init");
    try tr.writeFile("notes.xyz", "world\n");

    var repo = try tr.discover(gpa);
    defer repo.deinit();

    const changes = try repo.listChanges();
    try testing.expectEqual(@as(usize, 1), changes.len);
    const c = changes[0];
    try testing.expectEqual(vcs.ChangeKind.unsupported, c.kind);
    try testing.expectEqual(@as(u32, 0), c.line_stat.added);
    try testing.expectEqual(@as(u32, 0), c.line_stat.removed);
}

test "listChanges: git iteration order preserved" {
    const gpa = testing.allocator;
    var tr = try TestRepo.init(gpa);
    defer tr.deinit(gpa);

    try tr.writeFile("a.zig", "const x = 1;\n");
    try tr.writeFile("b.zig", "const y = 1;\n");
    try tr.writeFile("c.zig", "const z = 1;\n");
    try tr.commitAll(gpa, "init");

    try tr.writeFile("a.zig", "const x = 2;\n");
    try tr.writeFile("b.zig", "const y = 2;\n");
    try tr.writeFile("c.zig", "const z = 2;\n");

    var repo = try tr.discover(gpa);
    defer repo.deinit();

    const changes = try repo.listChanges();
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expectEqualStrings("a.zig", changes[0].new_path.?);
    try testing.expectEqualStrings("b.zig", changes[1].new_path.?);
    try testing.expectEqualStrings("c.zig", changes[2].new_path.?);
}

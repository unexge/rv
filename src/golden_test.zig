//! Golden fixture harness.
//!
//! Discovers fixtures under `tests/fixtures/<lang>/<scenario>/` at runtime.
//! For each fixture, reads `before.<ext>` and `after.<ext>`, calls
//! `rv.diffSources`, serialises the result to JSON, then compares it to
//! `expected.json` (or writes over it when `RV_REGEN` is set).
//!
//! Language is inferred from the parent directory name (zig/rust/go/python/
//! typescript), not from file extensions.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Writer = std.Io.Writer;

const rv = @import("root.zig");
const node = @import("sst/node.zig");
const build_options = @import("build_options");

pub const fixtures_path: []const u8 = build_options.fixtures_path;

/// Errors surfaced by the harness directly. Other IO/engine errors pass
/// through transparently.
pub const HarnessError = error{
    /// `expected.json` is missing and `RV_REGEN` is not set.
    MissingExpected,
    /// The harness found a before/after pair but `expected.json` text did not
    /// match the freshly serialised output.
    DiffMismatch,
};

const LangSpec = struct {
    id: rv.LanguageId,
    /// File extension with leading dot, e.g. ".zig".
    ext: []const u8,
};

fn langFromDirName(name: []const u8) ?LangSpec {
    if (std.mem.eql(u8, name, "zig")) return .{ .id = .zig, .ext = ".zig" };
    if (std.mem.eql(u8, name, "rust")) return .{ .id = .rust, .ext = ".rs" };
    if (std.mem.eql(u8, name, "go")) return .{ .id = .go, .ext = ".go" };
    if (std.mem.eql(u8, name, "python")) return .{ .id = .python, .ext = ".py" };
    if (std.mem.eql(u8, name, "typescript")) return .{ .id = .typescript, .ext = ".ts" };
    return null;
}

fn regenRequested() bool {
    // RV_REGEN: just a presence check. Using libc's getenv keeps this
    // allocator-free; the test binary already links libc through tree-sitter.
    return std.c.getenv("RV_REGEN") != null;
}

// ── serialisation ──────────────────────────────────────────────────────────

/// Emit the diff in the project's golden format (see epic testing strategy):
/// entries with kind/name/ts_kind/moved; leaf bodies = { edits_len,
/// comment_only }; container bodies recurse.
pub fn serializeFileDiff(writer: *Writer, file_diff: rv.FileDiff) Writer.Error!void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try writeFileDiff(&stringify, file_diff);
    try writer.writeByte('\n');
}

fn writeFileDiff(ws: *std.json.Stringify, file_diff: rv.FileDiff) Writer.Error!void {
    try ws.beginObject();
    try ws.objectField("entries");
    try writeEntries(ws, file_diff.entries);
    try ws.objectField("parse_errors");
    try writeParseErrors(ws, file_diff.parse_errors);
    try ws.endObject();
}

fn writeParseErrors(ws: *std.json.Stringify, errors: []const rv.ParseError) Writer.Error!void {
    try ws.beginArray();
    for (errors) |pe| {
        try ws.beginObject();
        try ws.objectField("side");
        try ws.write(@tagName(pe.side));
        try ws.objectField("kind");
        try ws.write(@tagName(pe.kind));
        try ws.endObject();
    }
    try ws.endArray();
}

fn writeEntries(ws: *std.json.Stringify, entries: []const rv.DeclDiff) Writer.Error!void {
    try ws.beginArray();
    for (entries) |entry| try writeEntry(ws, entry);
    try ws.endArray();
}

fn writeEntry(ws: *std.json.Stringify, entry: rv.DeclDiff) Writer.Error!void {
    try ws.beginObject();
    switch (entry) {
        .unchanged => |u| {
            try ws.objectField("kind");
            try ws.write("unchanged");
            try writeDeclFields(ws, u.decl);
            try writeMoved(ws, u.moved);
        },
        .added => |a| {
            try ws.objectField("kind");
            try ws.write("added");
            try writeDeclFields(ws, a.decl);
        },
        .removed => |r| {
            try ws.objectField("kind");
            try ws.write("removed");
            try writeDeclFields(ws, r.decl);
        },
        .changed => |c| {
            try ws.objectField("kind");
            try ws.write("changed");
            try writeDeclFields(ws, c.new);
            try writeMoved(ws, c.moved);
            try ws.objectField("body");
            try writeBody(ws, c.body);
        },
    }
    try ws.endObject();
}

fn writeDeclFields(ws: *std.json.Stringify, decl: rv.Decl) Writer.Error!void {
    try ws.objectField("name");
    if (decl.name) |n| try ws.write(n) else try ws.write(null);
    try ws.objectField("ts_kind");
    try ws.write(decl.ts_kind);
}

fn writeMoved(ws: *std.json.Stringify, moved: ?rv.MoveInfo) Writer.Error!void {
    try ws.objectField("moved");
    if (moved) |m| {
        try ws.beginObject();
        try ws.objectField("from_idx");
        try ws.write(m.from_idx);
        try ws.objectField("to_idx");
        try ws.write(m.to_idx);
        try ws.endObject();
    } else {
        try ws.write(null);
    }
}

fn writeBody(ws: *std.json.Stringify, body: rv.DeclBody) Writer.Error!void {
    try ws.beginObject();
    switch (body) {
        .leaf => |script| {
            try ws.objectField("type");
            try ws.write("leaf");
            try ws.objectField("edits_len");
            try ws.write(script.edits.len);
            try ws.objectField("comment_only");
            try ws.write(editScriptIsCommentOnly(script));
        },
        .container => |children| {
            try ws.objectField("type");
            try ws.write("container");
            try ws.objectField("children");
            try writeEntries(ws, children);
        },
        .import_group => |g| {
            try ws.objectField("type");
            try ws.write("import_group");
            try ws.objectField("prefix");
            try ws.write(g.prefix);
            try ws.objectField("entries_len");
            try ws.write(g.entries.len);
        },
    }
    try ws.endObject();
}

/// True iff every `novel` edit is on an atom whose kind is `.comment`, and
/// there is at least one such edit. Mirrors `EditScript.isCommentOnly` (which
/// the scaffold leaves stubbed); the harness inlines it so serialisation does
/// not depend on engine completeness.
fn editScriptIsCommentOnly(script: rv.EditScript) bool {
    var saw_any = false;
    for (script.edits) |e| switch (e) {
        .match => {},
        .novel => |n| switch (n.node_ref.*) {
            .atom => |a| {
                if (a.kind != .comment) return false;
                saw_any = true;
            },
            // A novel non-atom subtree cannot be comment-only.
            .list => return false,
        },
    };
    return saw_any;
}

// ── fixture discovery + execution ─────────────────────────────────────────

/// Discover and run every fixture under `root_path`. Called from the
/// top-level `test "golden fixtures"`; the build passes the absolute path
/// via `build_options.fixtures_path`.
pub fn runAll(gpa: std.mem.Allocator, io: Io, root_path: []const u8) !void {
    const regen = regenRequested();

    var root_dir = Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingFixtures,
        else => return err,
    };
    defer root_dir.close(io);

    var fixture_count: usize = 0;
    var lang_iter = root_dir.iterate();
    while (try lang_iter.next(io)) |lang_entry| {
        if (lang_entry.kind != .directory) continue;
        const lang = langFromDirName(lang_entry.name) orelse {
            std.log.warn("golden: unknown language dir: {s}", .{lang_entry.name});
            continue;
        };

        var lang_dir = try root_dir.openDir(io, lang_entry.name, .{ .iterate = true });
        defer lang_dir.close(io);

        var scen_iter = lang_dir.iterate();
        while (try scen_iter.next(io)) |scen_entry| {
            if (scen_entry.kind != .directory) continue;
            fixture_count += 1;
            try runFixture(gpa, io, lang_dir, lang_entry.name, scen_entry.name, lang, regen);
        }
    }
    if (fixture_count == 0) return error.MissingFixtures;
}

fn runFixture(
    gpa: std.mem.Allocator,
    io: Io,
    lang_dir: Io.Dir,
    lang_name: []const u8,
    scenario: []const u8,
    lang: LangSpec,
    regen: bool,
) !void {
    var fx_dir = try lang_dir.openDir(io, scenario, .{});
    defer fx_dir.close(io);

    const before_name = try std.fmt.allocPrint(gpa, "before{s}", .{lang.ext});
    defer gpa.free(before_name);
    const after_name = try std.fmt.allocPrint(gpa, "after{s}", .{lang.ext});
    defer gpa.free(after_name);

    const before = fx_dir.readFileAlloc(io, before_name, gpa, .limited(rv.max_source_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingFixtureInput,
        else => return err,
    };
    defer gpa.free(before);
    const after = fx_dir.readFileAlloc(io, after_name, gpa, .limited(rv.max_source_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingFixtureInput,
        else => return err,
    };
    defer gpa.free(after);

    var file_diff = try rv.diffSources(gpa, lang.id, before, after);
    defer file_diff.deinit();

    // Serialise into an in-memory buffer.
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try serializeFileDiff(&out.writer, file_diff);
    const serialised = out.written();

    compareOrRegen(io, fx_dir, serialised, regen) catch |err| switch (err) {
        error.MissingExpected => {
            std.debug.print(
                "golden: {s}/{s}: expected.json is missing. Run with RV_REGEN=1 to create it.\n",
                .{ lang_name, scenario },
            );
            return err;
        },
        error.DiffMismatch => {
            std.debug.print(
                "golden: {s}/{s}: diff output does not match expected.json. Run with RV_REGEN=1 to update.\n",
                .{ lang_name, scenario },
            );
            return err;
        },
        else => return err,
    };
}

/// Compares `actual_json` against `<fx_dir>/expected.json`, or overwrites
/// the file when `regen` is true. Separated from `runFixture` so the inline
/// tests can exercise it directly without building a synthetic FileDiff.
/// On error, returns a typed error without logging; callers are expected to
/// surface a human-readable message.
fn compareOrRegen(
    io: Io,
    fx_dir: Io.Dir,
    actual_json: []const u8,
    regen: bool,
) !void {
    if (regen) {
        try fx_dir.writeFile(io, .{ .sub_path = "expected.json", .data = actual_json });
        return;
    }

    const expected = fx_dir.readFileAlloc(io, "expected.json", std.testing.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.MissingExpected,
        else => return err,
    };
    defer std.testing.allocator.free(expected);

    if (!std.mem.eql(u8, expected, actual_json)) return error.DiffMismatch;
}

// ── tests ──────────────────────────────────────────────────────────────────

test "golden fixtures" {
    try runAll(testing.allocator, testing.io, fixtures_path);
}

test "langFromDirName covers all five supported languages" {
    try testing.expectEqual(rv.LanguageId.zig, langFromDirName("zig").?.id);
    try testing.expectEqualStrings(".zig", langFromDirName("zig").?.ext);
    try testing.expectEqual(rv.LanguageId.rust, langFromDirName("rust").?.id);
    try testing.expectEqualStrings(".rs", langFromDirName("rust").?.ext);
    try testing.expectEqual(rv.LanguageId.go, langFromDirName("go").?.id);
    try testing.expectEqualStrings(".go", langFromDirName("go").?.ext);
    try testing.expectEqual(rv.LanguageId.python, langFromDirName("python").?.id);
    try testing.expectEqualStrings(".py", langFromDirName("python").?.ext);
    try testing.expectEqual(rv.LanguageId.typescript, langFromDirName("typescript").?.id);
    try testing.expectEqualStrings(".ts", langFromDirName("typescript").?.ext);
    try testing.expect(langFromDirName("ruby") == null);
}

// Build synthetic entries for serialisation tests. Decl.list is a pointer;
// callers set it to &stub_list (the list is never deref'd during JSON emit).
const stub_list = node.List{
    .ts_kind = "function_item",
    .open_delim = "",
    .close_delim = "",
    .children = &.{},
    .leading_trivia = &.{},
    .trailing_trivia = &.{},
    .byte_range = .{ .start = 0, .end = 0 },
    .hash = 0,
};

fn stubDecl(kind: rv.DeclKind, ts_kind: []const u8, name: ?[]const u8) rv.Decl {
    return .{ .kind = kind, .ts_kind = ts_kind, .name = name, .list = &stub_list };
}

fn serialiseEntriesToString(gpa: std.mem.Allocator, entries: []const rv.DeclDiff) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var ws: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try ws.beginObject();
    try ws.objectField("entries");
    try writeEntries(&ws, entries);
    try ws.endObject();
    try out.writer.writeByte('\n');
    return try out.toOwnedSlice();
}

test "serialize: unchanged entry shape" {
    const entry = rv.DeclDiff{ .unchanged = .{
        .decl = stubDecl(.function, "function_item", "main"),
        .moved = null,
    } };
    const got = try serialiseEntriesToString(testing.allocator, &.{entry});
    defer testing.allocator.free(got);

    const want =
        \\{
        \\  "entries": [
        \\    {
        \\      "kind": "unchanged",
        \\      "name": "main",
        \\      "ts_kind": "function_item",
        \\      "moved": null
        \\    }
        \\  ]
        \\}
        \\
    ;
    try testing.expectEqualStrings(want, got);
}

test "serialize: added + removed with null name" {
    const entries = [_]rv.DeclDiff{
        .{ .added = .{ .decl = stubDecl(.function, "function_item", "new_fn") } },
        .{ .removed = .{ .decl = stubDecl(.other, "expression_statement", null) } },
    };
    const got = try serialiseEntriesToString(testing.allocator, &entries);
    defer testing.allocator.free(got);

    const want =
        \\{
        \\  "entries": [
        \\    {
        \\      "kind": "added",
        \\      "name": "new_fn",
        \\      "ts_kind": "function_item"
        \\    },
        \\    {
        \\      "kind": "removed",
        \\      "name": null,
        \\      "ts_kind": "expression_statement"
        \\    }
        \\  ]
        \\}
        \\
    ;
    try testing.expectEqualStrings(want, got);
}

test "serialize: changed leaf body records edits_len and comment_only" {
    const comment_atom = node.Node{ .atom = .{
        .kind = .comment,
        .bytes = "// hi",
        .byte_range = .{ .start = 0, .end = 5 },
        .hash = 0,
    } };
    const edits = [_]rv.Edit{.{ .novel = .{ .side = .right, .node_ref = &comment_atom } }};
    const script = rv.EditScript{ .edits = &edits, .total_cost = 1 };

    const entry = rv.DeclDiff{ .changed = .{
        .old = stubDecl(.function, "function_item", "foo"),
        .new = stubDecl(.function, "function_item", "foo"),
        .body = .{ .leaf = script },
        .moved = .{ .from_idx = 0, .to_idx = 2 },
    } };
    const got = try serialiseEntriesToString(testing.allocator, &.{entry});
    defer testing.allocator.free(got);

    const want =
        \\{
        \\  "entries": [
        \\    {
        \\      "kind": "changed",
        \\      "name": "foo",
        \\      "ts_kind": "function_item",
        \\      "moved": {
        \\        "from_idx": 0,
        \\        "to_idx": 2
        \\      },
        \\      "body": {
        \\        "type": "leaf",
        \\        "edits_len": 1,
        \\        "comment_only": true
        \\      }
        \\    }
        \\  ]
        \\}
        \\
    ;
    try testing.expectEqualStrings(want, got);
}

test "serialize: changed container body recurses" {
    const child = rv.DeclDiff{ .added = .{
        .decl = stubDecl(.function, "method_declaration", "bar"),
    } };
    const children = [_]rv.DeclDiff{child};

    const entry = rv.DeclDiff{ .changed = .{
        .old = stubDecl(.container, "struct_item", "Foo"),
        .new = stubDecl(.container, "struct_item", "Foo"),
        .body = .{ .container = &children },
        .moved = null,
    } };
    const got = try serialiseEntriesToString(testing.allocator, &.{entry});
    defer testing.allocator.free(got);

    const want =
        \\{
        \\  "entries": [
        \\    {
        \\      "kind": "changed",
        \\      "name": "Foo",
        \\      "ts_kind": "struct_item",
        \\      "moved": null,
        \\      "body": {
        \\        "type": "container",
        \\        "children": [
        \\          {
        \\            "kind": "added",
        \\            "name": "bar",
        \\            "ts_kind": "method_declaration"
        \\          }
        \\        ]
        \\      }
        \\    }
        \\  ]
        \\}
        \\
    ;
    try testing.expectEqualStrings(want, got);
}

test "discovery: iterate mock fixtures root" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "zig/alpha");
    try tmp.dir.createDirPath(testing.io, "zig/beta");
    try tmp.dir.createDirPath(testing.io, "rust/gamma");

    var found_langs: usize = 0;
    var found_scenarios: usize = 0;

    var root_iter = tmp.dir.iterate();
    while (try root_iter.next(testing.io)) |lang_entry| {
        if (lang_entry.kind != .directory) continue;
        if (langFromDirName(lang_entry.name) == null) continue;
        found_langs += 1;

        var lang_dir = try tmp.dir.openDir(testing.io, lang_entry.name, .{ .iterate = true });
        defer lang_dir.close(testing.io);
        var scen_iter = lang_dir.iterate();
        while (try scen_iter.next(testing.io)) |scen_entry| {
            if (scen_entry.kind == .directory) found_scenarios += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), found_langs);
    try testing.expectEqual(@as(usize, 3), found_scenarios);
}

test "runAll: empty fixture root fails instead of silently passing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);

    try testing.expectError(
        error.MissingFixtures,
        runAll(testing.allocator, testing.io, path_buf[0..path_len]),
    );
}

test "runAll: fixture with missing source input fails" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "zig/missing-input");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);

    try testing.expectError(
        error.MissingFixtureInput,
        runAll(testing.allocator, testing.io, path_buf[0..path_len]),
    );
}

test "compareOrRegen: missing expected.json yields MissingExpected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(
        error.MissingExpected,
        compareOrRegen(testing.io, tmp.dir, "{}\n", false),
    );
}

test "compareOrRegen: RV_REGEN-style branch writes expected.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "{\n  \"entries\": []\n}\n";
    try compareOrRegen(testing.io, tmp.dir, payload, true);

    const read_back = try tmp.dir.readFileAlloc(testing.io, "expected.json", testing.allocator, .unlimited);
    defer testing.allocator.free(read_back);
    try testing.expectEqualStrings(payload, read_back);
}

test "compareOrRegen: matching expected.json passes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "{\n  \"entries\": []\n}\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "expected.json", .data = payload });

    try compareOrRegen(testing.io, tmp.dir, payload, false);
}

test "compareOrRegen: mismatch yields DiffMismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "expected.json", .data = "{\"a\":1}\n" });

    try testing.expectError(
        error.DiffMismatch,
        compareOrRegen(testing.io, tmp.dir, "{\"a\":2}\n", false),
    );
}

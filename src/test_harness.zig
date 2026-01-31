const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const ui = @import("ui.zig");
const review = @import("review.zig");
const difft = @import("difft.zig");

/// Test harness for TUI testing with snapshot support.
/// Allows rendering the UI to a buffer and comparing against snapshots.
pub const TestRunner = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    ui_instance: ui.UI,
    width: u16,
    height: u16,
    last_surface: ?vxfw.Surface = null,

    pub fn init(allocator: Allocator, session: *review.ReviewSession, width: u16, height: u16) TestRunner {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .ui_instance = ui.UI.initForTest(allocator, session),
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *TestRunner) void {
        self.ui_instance.deinit();
        self.arena.deinit();
    }

    /// Get mutable access to the UI for setup
    pub fn getUI(self: *TestRunner) *ui.UI {
        return &self.ui_instance;
    }

    /// Render the UI to a surface and store it for inspection
    pub fn render(self: *TestRunner) !vxfw.Surface {
        // Reset arena for each render
        _ = self.arena.reset(.retain_capacity);

        const ctx = vxfw.DrawContext{
            .arena = self.arena.allocator(),
            .min = .{ .width = self.width, .height = self.height },
            .max = .{ .width = self.width, .height = self.height },
            .cell_size = .{ .width = 8, .height = 16 }, // Typical cell size
        };

        const surface = try self.ui_instance.widget().draw(ctx);
        self.last_surface = surface;
        return surface;
    }

    /// Send a key press event to the UI
    pub fn sendKey(self: *TestRunner, key: vaxis.Key) !void {
        // Create a minimal event context for key handling
        var ctx = vxfw.EventContext{
            .phase = .at_target,
            .alloc = self.allocator,
            .cmds = .empty,
            .io = undefined, // Not used for key handling
        };
        defer ctx.cmds.deinit(self.allocator);

        // Call handleKeyPress directly to bypass widget layer
        try self.ui_instance.handleKeyPress(&ctx, key);
    }

    /// Send a character key press (convenience method)
    pub fn sendChar(self: *TestRunner, char: u21) !void {
        try self.sendKey(.{ .codepoint = char });
    }

    /// Send special keys
    pub fn sendUp(self: *TestRunner) !void {
        try self.sendKey(.{ .codepoint = vaxis.Key.up });
    }

    pub fn sendDown(self: *TestRunner) !void {
        try self.sendKey(.{ .codepoint = vaxis.Key.down });
    }

    pub fn sendEnter(self: *TestRunner) !void {
        try self.sendKey(.{ .codepoint = vaxis.Key.enter });
    }

    pub fn sendEscape(self: *TestRunner) !void {
        try self.sendKey(.{ .codepoint = vaxis.Key.escape });
    }

    pub fn sendSpace(self: *TestRunner) !void {
        try self.sendKey(.{ .codepoint = ' ' });
    }

    /// Send keys with modifiers
    pub fn sendShiftUp(self: *TestRunner) !void {
        try self.sendKey(.{ .codepoint = vaxis.Key.up, .mods = .{ .shift = true } });
    }

    pub fn sendShiftDown(self: *TestRunner) !void {
        try self.sendKey(.{ .codepoint = vaxis.Key.down, .mods = .{ .shift = true } });
    }

    /// Capture the current render as a Snapshot
    pub fn captureSnapshot(self: *TestRunner) !Snapshot {
        const surface = try self.render();
        return Snapshot.fromSurface(self.allocator, surface, &self.ui_instance);
    }

    /// Extract just the text content from the current render (for simple assertions)
    pub fn getText(self: *TestRunner) ![][]const u8 {
        const surface = try self.render();
        return extractText(self.allocator, surface);
    }

    /// Get text at a specific row
    pub fn getRowText(self: *TestRunner, row: u16) ![]const u8 {
        const surface = try self.render();
        return extractRowText(self.allocator, surface, row);
    }

    /// Assert current render matches a serialized snapshot.
    pub fn assertMatchesSnapshot(self: *TestRunner, expected_data: []const u8) !void {
        var snapshot = try self.captureSnapshot();
        defer snapshot.deinit();
        try snapshot.assertMatches(expected_data);
    }

    /// Get the current render as a serialized snapshot string.
    /// Caller owns the returned memory.
    pub fn serializeSnapshot(self: *TestRunner) ![]const u8 {
        var snapshot = try self.captureSnapshot();
        defer snapshot.deinit();
        return try snapshot.serialize(self.allocator);
    }
};

/// A captured snapshot of the UI state for comparison
pub const Snapshot = struct {
    allocator: Allocator,
    width: u16,
    height: u16,
    /// Text content, one string per row
    text_rows: [][]const u8,
    /// Style information for each cell (optional, for detailed comparison)
    styles: ?[][]CellStyle = null,
    /// UI state at time of capture
    state: UIState,

    pub const UIState = struct {
        mode: []const u8,
        cursor_line: usize,
        scroll_offset: usize,
        current_file: ?[]const u8,
        view_mode: []const u8,
        summary_mode: bool,
    };

    pub const CellStyle = struct {
        fg: ?Color = null,
        bg: ?Color = null,
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        reverse: bool = false,
    };

    pub const Color = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub fn fromSurface(allocator: Allocator, surface: vxfw.Surface, ui_instance: *const ui.UI) !Snapshot {
        const text_rows = try extractText(allocator, surface);
        const styles = try extractStyles(allocator, surface);

        // Capture UI state
        const mode_str = switch (ui_instance.mode) {
            .normal => "normal",
            .comment_input => "comment_input",
            .ask_input => "ask_input",
            .ask_response => "ask_response",
            .ask_response_comment => "ask_response_comment",
            .help => "help",
            .file_list => "file_list",
        };

        const view_mode_str = switch (ui_instance.view_mode) {
            .unified => "unified",
            .split => "split",
        };

        const current_file = if (ui_instance.session.currentFile()) |f|
            try allocator.dupe(u8, f.path)
        else
            null;

        return .{
            .allocator = allocator,
            .width = surface.size.width,
            .height = surface.size.height,
            .text_rows = text_rows,
            .styles = styles,
            .state = .{
                .mode = mode_str,
                .cursor_line = ui_instance.cursor_line,
                .scroll_offset = ui_instance.scroll_offset,
                .current_file = current_file,
                .view_mode = view_mode_str,
                .summary_mode = ui_instance.summary_mode,
            },
        };
    }

    pub fn deinit(self: *Snapshot) void {
        for (self.text_rows) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.text_rows);

        if (self.styles) |styles| {
            for (styles) |row_styles| {
                self.allocator.free(row_styles);
            }
            self.allocator.free(styles);
        }

        if (self.state.current_file) |f| {
            self.allocator.free(f);
        }
    }

    /// Compare this snapshot with another, returning differences
    pub fn compare(self: *const Snapshot, other: *const Snapshot) !CompareResult {
        var diffs: std.ArrayList(Diff) = .empty;

        // Compare dimensions
        if (self.width != other.width or self.height != other.height) {
            try diffs.append(self.allocator, .{
                .kind = .dimension_mismatch,
                .expected = try std.fmt.allocPrint(self.allocator, "{}x{}", .{ self.width, self.height }),
                .actual = try std.fmt.allocPrint(self.allocator, "{}x{}", .{ other.width, other.height }),
                .row = null,
            });
        }

        // Compare text content row by row
        const min_rows = @min(self.text_rows.len, other.text_rows.len);
        for (0..min_rows) |i| {
            if (!std.mem.eql(u8, self.text_rows[i], other.text_rows[i])) {
                try diffs.append(self.allocator, .{
                    .kind = .text_mismatch,
                    .expected = try self.allocator.dupe(u8, self.text_rows[i]),
                    .actual = try self.allocator.dupe(u8, other.text_rows[i]),
                    .row = i,
                });
            }
        }

        // Compare UI state
        if (!std.mem.eql(u8, self.state.mode, other.state.mode)) {
            try diffs.append(self.allocator, .{
                .kind = .state_mismatch,
                .expected = try std.fmt.allocPrint(self.allocator, "mode={s}", .{self.state.mode}),
                .actual = try std.fmt.allocPrint(self.allocator, "mode={s}", .{other.state.mode}),
                .row = null,
            });
        }

        if (self.state.cursor_line != other.state.cursor_line) {
            try diffs.append(self.allocator, .{
                .kind = .state_mismatch,
                .expected = try std.fmt.allocPrint(self.allocator, "cursor_line={}", .{self.state.cursor_line}),
                .actual = try std.fmt.allocPrint(self.allocator, "cursor_line={}", .{other.state.cursor_line}),
                .row = null,
            });
        }

        const items_len = diffs.items.len;
        return .{
            .allocator = self.allocator,
            .diffs = try diffs.toOwnedSlice(self.allocator),
            .match = items_len == 0,
        };
    }

    /// Serialize snapshot to a string for file storage
    pub fn serialize(self: *const Snapshot, allocator: Allocator) ![]const u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        // Helper function to append a formatted string and free it
        const appendFmt = struct {
            fn call(buf: *std.ArrayList(u8), alloc: Allocator, comptime fmt: []const u8, args: anytype) !void {
                const str = try std.fmt.allocPrint(alloc, fmt, args);
                defer alloc.free(str);
                try buf.appendSlice(alloc, str);
            }
        }.call;

        // Header with metadata
        try appendFmt(&buffer, allocator, "# Snapshot: {s}\n", .{self.state.current_file orelse "(no file)"});
        try appendFmt(&buffer, allocator, "# Dimensions: {}x{}\n", .{ self.width, self.height });
        try appendFmt(&buffer, allocator, "# Mode: {s}\n", .{self.state.mode});
        try appendFmt(&buffer, allocator, "# View: {s}\n", .{self.state.view_mode});
        try appendFmt(&buffer, allocator, "# Cursor: {}\n", .{self.state.cursor_line});
        try appendFmt(&buffer, allocator, "# Scroll: {}\n", .{self.state.scroll_offset});
        try appendFmt(&buffer, allocator, "# Summary: {}\n", .{self.state.summary_mode});
        try buffer.appendSlice(allocator, "---\n");

        // Content
        for (self.text_rows) |row| {
            try buffer.appendSlice(allocator, row);
            try buffer.append(allocator, '\n');
        }

        return try buffer.toOwnedSlice(allocator);
    }

    /// Deserialize snapshot from string
    pub fn deserialize(allocator: Allocator, data: []const u8) !Snapshot {
        var lines = std.mem.splitSequence(u8, data, "\n");
        var text_rows: std.ArrayList([]const u8) = .empty;
        defer text_rows.deinit(allocator);

        var in_content = false;
        var width: u16 = 0;
        var height: u16 = 0;
        var mode: []const u8 = "normal";
        var view_mode: []const u8 = "split";
        var cursor_line: usize = 0;
        var scroll_offset: usize = 0;
        var summary_mode: bool = true;
        var current_file: ?[]const u8 = null;

        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "---")) {
                in_content = true;
                continue;
            }

            if (in_content) {
                try text_rows.append(allocator, try allocator.dupe(u8, line));
            } else {
                // Parse header
                if (std.mem.startsWith(u8, line, "# Dimensions: ")) {
                    const dims = line["# Dimensions: ".len..];
                    var it = std.mem.splitScalar(u8, dims, 'x');
                    if (it.next()) |w| width = std.fmt.parseInt(u16, w, 10) catch 0;
                    if (it.next()) |h| height = std.fmt.parseInt(u16, h, 10) catch 0;
                } else if (std.mem.startsWith(u8, line, "# Mode: ")) {
                    mode = line["# Mode: ".len..];
                } else if (std.mem.startsWith(u8, line, "# View: ")) {
                    view_mode = line["# View: ".len..];
                } else if (std.mem.startsWith(u8, line, "# Cursor: ")) {
                    cursor_line = std.fmt.parseInt(usize, line["# Cursor: ".len..], 10) catch 0;
                } else if (std.mem.startsWith(u8, line, "# Scroll: ")) {
                    scroll_offset = std.fmt.parseInt(usize, line["# Scroll: ".len..], 10) catch 0;
                } else if (std.mem.startsWith(u8, line, "# Summary: ")) {
                    summary_mode = std.mem.eql(u8, line["# Summary: ".len..], "true");
                } else if (std.mem.startsWith(u8, line, "# Snapshot: ")) {
                    const file = line["# Snapshot: ".len..];
                    if (!std.mem.eql(u8, file, "(no file)")) {
                        current_file = try allocator.dupe(u8, file);
                    }
                }
            }
        }

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .text_rows = try text_rows.toOwnedSlice(allocator),
            .styles = null,
            .state = .{
                .mode = mode,
                .cursor_line = cursor_line,
                .scroll_offset = scroll_offset,
                .current_file = current_file,
                .view_mode = view_mode,
                .summary_mode = summary_mode,
            },
        };
    }

    /// Compare against a serialized snapshot string. Returns error if snapshots don't match.
    pub fn assertMatches(self: *const Snapshot, expected_data: []const u8) !void {
        var expected = try Snapshot.deserialize(self.allocator, expected_data);
        defer expected.deinit();

        var result = try self.compare(&expected);
        defer result.deinit();

        if (!result.match) {
            return error.SnapshotMismatch;
        }
    }
};

pub const CompareResult = struct {
    allocator: Allocator,
    diffs: []Diff,
    match: bool,

    pub fn deinit(self: *CompareResult) void {
        for (self.diffs) |diff| {
            self.allocator.free(diff.expected);
            self.allocator.free(diff.actual);
        }
        self.allocator.free(self.diffs);
    }

    /// Format differences for display
    pub fn format(self: *const CompareResult, allocator: Allocator) ![]const u8 {
        if (self.match) {
            return try allocator.dupe(u8, "Snapshots match");
        }

        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        // Helper function to append a formatted string and free it
        const appendFmt = struct {
            fn call(buf: *std.ArrayList(u8), alloc: Allocator, comptime fmt: []const u8, args: anytype) !void {
                const str = try std.fmt.allocPrint(alloc, fmt, args);
                defer alloc.free(str);
                try buf.appendSlice(alloc, str);
            }
        }.call;

        try appendFmt(&buffer, allocator, "Found {} difference(s):\n", .{self.diffs.len});
        for (self.diffs) |diff| {
            try appendFmt(&buffer, allocator, "\n[{s}]", .{@tagName(diff.kind)});
            if (diff.row) |row| {
                try appendFmt(&buffer, allocator, " at row {}", .{row});
            }
            try appendFmt(&buffer, allocator, "\n  Expected: {s}\n  Actual:   {s}\n", .{ diff.expected, diff.actual });
        }

        return try buffer.toOwnedSlice(allocator);
    }
};

pub const Diff = struct {
    kind: DiffKind,
    expected: []const u8,
    actual: []const u8,
    row: ?usize,
};

pub const DiffKind = enum {
    text_mismatch,
    style_mismatch,
    dimension_mismatch,
    state_mismatch,
};

/// Extract text content from a surface
fn extractText(allocator: Allocator, surface: vxfw.Surface) ![][]const u8 {
    var rows = try allocator.alloc([]const u8, surface.size.height);

    for (0..surface.size.height) |row| {
        rows[row] = try extractRowText(allocator, surface, @intCast(row));
    }

    return rows;
}

/// Extract text from a single row
fn extractRowText(allocator: Allocator, surface: vxfw.Surface, row: u16) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    for (0..surface.size.width) |col| {
        const cell = surface.readCell(col, row);
        if (cell.default) {
            try buffer.append(allocator, ' ');
        } else {
            // Handle multi-byte graphemes
            for (cell.char.grapheme) |byte| {
                try buffer.append(allocator, byte);
            }
        }
    }

    // Trim trailing spaces
    var end = buffer.items.len;
    while (end > 0 and buffer.items[end - 1] == ' ') {
        end -= 1;
    }

    return try allocator.dupe(u8, buffer.items[0..end]);
}

/// Extract style information from a surface
fn extractStyles(allocator: Allocator, surface: vxfw.Surface) ![][]Snapshot.CellStyle {
    var rows = try allocator.alloc([]Snapshot.CellStyle, surface.size.height);

    for (0..surface.size.height) |row| {
        var row_styles = try allocator.alloc(Snapshot.CellStyle, surface.size.width);
        for (0..surface.size.width) |col| {
            const cell = surface.readCell(col, row);
            row_styles[col] = .{
                .fg = colorFromVaxis(cell.style.fg),
                .bg = colorFromVaxis(cell.style.bg),
                .bold = cell.style.bold,
                .dim = cell.style.dim,
                .italic = cell.style.italic,
                .reverse = cell.style.reverse,
            };
        }
        rows[row] = row_styles;
    }

    return rows;
}

fn colorFromVaxis(color: vaxis.Cell.Color) ?Snapshot.Color {
    return switch (color) {
        .rgb => |rgb| .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] },
        else => null,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "TestRunner basic rendering" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    // Should render without crashing
    const surface = try runner.render();
    try std.testing.expect(surface.size.width == 80);
    try std.testing.expect(surface.size.height == 24);
}

test "TestRunner capture snapshot" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    var snapshot = try runner.captureSnapshot();
    defer snapshot.deinit();

    try std.testing.expectEqualStrings("normal", snapshot.state.mode);
    try std.testing.expectEqualStrings("split", snapshot.state.view_mode);
}

test "Snapshot serialize and deserialize" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    var snapshot1 = try runner.captureSnapshot();
    defer snapshot1.deinit();

    const serialized = try snapshot1.serialize(allocator);
    defer allocator.free(serialized);

    var snapshot2 = try Snapshot.deserialize(allocator, serialized);
    defer snapshot2.deinit();

    // Basic state should match
    try std.testing.expectEqualStrings(snapshot1.state.mode, snapshot2.state.mode);
    try std.testing.expectEqual(snapshot1.state.cursor_line, snapshot2.state.cursor_line);
}

test "Snapshot comparison detects differences" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    var snapshot1 = try runner.captureSnapshot();
    defer snapshot1.deinit();

    // Modify UI state
    runner.getUI().cursor_line = 5;

    var snapshot2 = try runner.captureSnapshot();
    defer snapshot2.deinit();

    var result = try snapshot1.compare(&snapshot2);
    defer result.deinit();

    // Should detect cursor line difference
    try std.testing.expect(!result.match);
    try std.testing.expect(result.diffs.len > 0);
}

test "TestRunner with diff file shows file path in header" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Add a file to the session
    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "src/example.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = &.{},
        .allocator = allocator,
    };

    try session.addFile(.{
        .path = try allocator.dupe(u8, "src/example.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, "const x = 1;"),
        .new_content = try allocator.dupe(u8, "const x = 2;"),
    });

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    // Build diff lines so UI has content
    try runner.getUI().buildDiffLines();

    var snapshot = try runner.captureSnapshot();
    defer snapshot.deinit();

    // Verify file is tracked in state
    try std.testing.expect(snapshot.state.current_file != null);
    try std.testing.expectEqualStrings("src/example.zig", snapshot.state.current_file.?);

    // Check header row contains the file path
    try std.testing.expect(snapshot.text_rows.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.text_rows[0], "src/example.zig") != null);
}

test "TestRunner verifies style information captured" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    var snapshot = try runner.captureSnapshot();
    defer snapshot.deinit();

    // Styles should be captured
    try std.testing.expect(snapshot.styles != null);
    try std.testing.expect(snapshot.styles.?.len == 24); // height rows

    // Each row should have width columns of styles
    for (snapshot.styles.?) |row_styles| {
        try std.testing.expect(row_styles.len == 80);
    }
}

test "Snapshot text extraction trims trailing spaces" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    var snapshot = try runner.captureSnapshot();
    defer snapshot.deinit();

    // All rows should have trailing whitespace trimmed
    for (snapshot.text_rows) |row| {
        if (row.len > 0) {
            try std.testing.expect(row[row.len - 1] != ' ');
        }
    }
}

test "Snapshot assertMatches with serialized data" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    // Capture and serialize
    var snapshot1 = try runner.captureSnapshot();
    defer snapshot1.deinit();

    const serialized = try snapshot1.serialize(allocator);
    defer allocator.free(serialized);

    // Create another snapshot and compare against serialized data
    var snapshot2 = try runner.captureSnapshot();
    defer snapshot2.deinit();

    // Should match since UI hasn't changed
    try snapshot2.assertMatches(serialized);
}

test "Snapshot assertMatches detects mismatch" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    // Capture initial state
    var snapshot1 = try runner.captureSnapshot();
    defer snapshot1.deinit();

    const serialized = try snapshot1.serialize(allocator);
    defer allocator.free(serialized);

    // Change UI state
    runner.getUI().cursor_line = 10;

    // Capture new snapshot
    var snapshot2 = try runner.captureSnapshot();
    defer snapshot2.deinit();

    // Should fail to match
    const match_result = snapshot2.assertMatches(serialized);
    try std.testing.expectError(error.SnapshotMismatch, match_result);
}

test "TestRunner serializeSnapshot returns valid data" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    const serialized = try runner.serializeSnapshot();
    defer allocator.free(serialized);

    // Should contain expected headers
    try std.testing.expect(std.mem.indexOf(u8, serialized, "# Snapshot:") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "# Mode: normal") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "---") != null);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}

// =============================================================================
// Test Helpers for creating diff data
// =============================================================================

/// Helper to create a simple file with specified number of lines (all additions)
fn createTestFileWithLines(allocator: Allocator, session: *review.ReviewSession, num_lines: usize) !void {
    var content_builder: std.ArrayList(u8) = .empty;
    defer content_builder.deinit(allocator);

    for (0..num_lines) |i| {
        if (i > 0) try content_builder.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "line {}", .{i + 1});
        defer allocator.free(line);
        try content_builder.appendSlice(allocator, line);
    }

    const new_content = try content_builder.toOwnedSlice(allocator);

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .added,
        .chunks = &.{},
        .allocator = allocator,
    };

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, ""),
        .new_content = new_content,
    });
}

/// Helper to create a file with context lines and separators (multi-chunk diff)
fn createTestFileWithSeparators(allocator: Allocator, session: *review.ReviewSession) !void {
    // Create a file with 30 lines where lines 5-7 and 25-27 are changed
    // This produces a separator ("...") between the two change regions
    var chunk_entries1: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries1.deinit(allocator);

    // First chunk: change at line 5-7 (0-based: 4-6)
    for (4..7) |line_num| {
        try chunk_entries1.append(allocator, .{
            .lhs = .{ .line_number = @intCast(line_num), .changes = &.{} },
            .rhs = .{ .line_number = @intCast(line_num), .changes = &.{} },
        });
    }

    var chunk_entries2: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries2.deinit(allocator);

    // Second chunk: change at line 25-27 (0-based: 24-26)
    for (24..27) |line_num| {
        try chunk_entries2.append(allocator, .{
            .lhs = .{ .line_number = @intCast(line_num), .changes = &.{} },
            .rhs = .{ .line_number = @intCast(line_num), .changes = &.{} },
        });
    }

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries1.toOwnedSlice(allocator));
    try chunks.append(allocator, try chunk_entries2.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    // Build 30-line old and new content
    var old_content_builder: std.ArrayList(u8) = .empty;
    defer old_content_builder.deinit(allocator);
    var new_content_builder: std.ArrayList(u8) = .empty;
    defer new_content_builder.deinit(allocator);

    for (0..30) |i| {
        if (i > 0) {
            try old_content_builder.append(allocator, '\n');
            try new_content_builder.append(allocator, '\n');
        }
        const old_line = try std.fmt.allocPrint(allocator, "old line {}", .{i + 1});
        defer allocator.free(old_line);
        try old_content_builder.appendSlice(allocator, old_line);

        const new_line = try std.fmt.allocPrint(allocator, "new line {}", .{i + 1});
        defer allocator.free(new_line);
        try new_content_builder.appendSlice(allocator, new_line);
    }

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try old_content_builder.toOwnedSlice(allocator),
        .new_content = try new_content_builder.toOwnedSlice(allocator),
    });
}

// =============================================================================
// Cursor Movement Tests
// =============================================================================

test "cursor: arrow keys move cursor down/up" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Verify we have lines to navigate
    try std.testing.expect(runner.getUI().diff_lines.items.len > 0);

    // Initial cursor position should be 0
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    // Press down arrow to move down
    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 1), runner.getUI().cursor_line);

    // Press down arrow again
    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 2), runner.getUI().cursor_line);

    // Press up arrow to move up
    try runner.sendUp();
    try std.testing.expectEqual(@as(usize, 1), runner.getUI().cursor_line);

    // Press up arrow again
    try runner.sendUp();
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);
}


test "cursor: stays within upper bound (can't go below 0)" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 5);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Cursor starts at 0
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    // Press up arrow multiple times - should stay at 0
    try runner.sendUp();
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    try runner.sendUp();
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    try runner.sendUp();
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);
}

test "cursor: stays within lower bound (can't exceed row_count - 1)" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 5);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const row_count = runner.getUI().diff_lines.items.len;
    try std.testing.expect(row_count == 5);

    // Move to the last line using down arrows
    for (0..10) |_| {
        try runner.sendDown();
    }

    // Should be at the last line (row_count - 1)
    try std.testing.expectEqual(row_count - 1, runner.getUI().cursor_line);

    // Try to move past - should stay at last line
    try runner.sendDown();
    try std.testing.expectEqual(row_count - 1, runner.getUI().cursor_line);

    try runner.sendDown();
    try std.testing.expectEqual(row_count - 1, runner.getUI().cursor_line);
}

test "cursor: 'g' goes to first line" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Move to middle of file using down arrows
    for (0..5) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 5), runner.getUI().cursor_line);

    // Press 'g' to go to first line
    try runner.sendChar('g');
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);
}

test "cursor: 'G' goes to last line" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const row_count = runner.getUI().diff_lines.items.len;

    // Cursor starts at 0
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    // Press 'G' to go to last line
    try runner.sendChar('G');
    try std.testing.expectEqual(row_count - 1, runner.getUI().cursor_line);
}

test "cursor: skips non-selectable separator rows" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithSeparators(allocator, &session);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Find a separator line (non-selectable)
    var has_separator = false;
    var separator_idx: usize = 0;
    for (runner.getUI().diff_lines.items, 0..) |line, idx| {
        if (!line.selectable) {
            has_separator = true;
            separator_idx = idx;
            break;
        }
    }

    // If there's a separator, verify cursor skips it
    if (has_separator) {
        // Move cursor to just before separator
        runner.getUI().cursor_line = if (separator_idx > 0) separator_idx - 1 else 0;

        // Move down - should skip separator
        try runner.sendDown();
        try std.testing.expect(runner.getUI().cursor_line != separator_idx);

        // If we landed after separator, verify
        if (runner.getUI().cursor_line > separator_idx) {
            // Moving back up should also skip separator
            try runner.sendUp();
            try std.testing.expect(runner.getUI().cursor_line != separator_idx);
        }
    }
}

test "cursor: page down ('f') moves by 20 lines" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Create file with enough lines for page movement
    try createTestFileWithLines(allocator, &session, 50);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Cursor starts at 0
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    // Press 'f' for page down
    try runner.sendChar('f');

    // Should move by approximately 20 lines (may be adjusted for selectability)
    try std.testing.expect(runner.getUI().cursor_line >= 15);
    try std.testing.expect(runner.getUI().cursor_line <= 25);
}

test "cursor: page up ('p') moves by 20 lines" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 50);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // First go to line 30
    runner.getUI().cursor_line = 30;

    // Press 'p' for page up
    try runner.sendChar('p');

    // Should move back by approximately 20 lines
    try std.testing.expect(runner.getUI().cursor_line >= 5);
    try std.testing.expect(runner.getUI().cursor_line <= 15);
}

test "cursor: page up at top stays at 0" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 50);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start at line 5
    runner.getUI().cursor_line = 5;

    // Press 'p' for page up - should go to 0 since 5 < 20
    try runner.sendChar('p');
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);
}

test "cursor: page down at bottom stays at last line" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 30);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const row_count = runner.getUI().diff_lines.items.len;

    // Move to near the end
    runner.getUI().cursor_line = row_count - 5;

    // Press 'f' for page down - should go to last line
    try runner.sendChar('f');
    try std.testing.expectEqual(row_count - 1, runner.getUI().cursor_line);
}

test "cursor: movement works with empty file" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // No files added - empty session

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    // Don't call buildDiffLines - no file

    // Cursor should be at 0
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    // Movement commands should not crash with empty content
    try runner.sendDown();
    try runner.sendUp();
    try runner.sendChar('g');
    try runner.sendChar('G');
    try runner.sendChar('f');
    try runner.sendChar('p');

    // Cursor should still be at 0
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);
}

test "cursor: movement works with single line file" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 1);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    try std.testing.expectEqual(@as(usize, 1), runner.getUI().diff_lines.items.len);

    // All movements should keep cursor at 0
    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    try runner.sendUp();
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    try runner.sendChar('g');
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    try runner.sendChar('G');
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);
}

test "cursor: unified view mode navigation" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    // Switch to unified view mode
    runner.getUI().view_mode = .unified;
    try runner.getUI().buildDiffLines();

    // Navigate in unified mode
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 1), runner.getUI().cursor_line);

    try runner.sendChar('G');
    const row_count = runner.getUI().diff_lines.items.len;
    try std.testing.expectEqual(row_count - 1, runner.getUI().cursor_line);
}

test "cursor: split view mode navigation" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    // Ensure split view mode (default)
    runner.getUI().view_mode = .split;
    try runner.getUI().buildDiffLines();

    // Navigate in split mode
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 1), runner.getUI().cursor_line);

    try runner.sendChar('G');
    const row_count = runner.getUI().split_rows.items.len;
    try std.testing.expectEqual(row_count - 1, runner.getUI().cursor_line);
}

// =============================================================================
// Selection System Tests
// =============================================================================

test "selection: space bar toggles selection_start" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Initially no selection
    try std.testing.expect(runner.getUI().selection_start == null);

    // Press space to start selection at current position
    try runner.sendSpace();
    try std.testing.expect(runner.getUI().selection_start != null);
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().selection_start.?);

    // Press space again to toggle off
    try runner.sendSpace();
    try std.testing.expect(runner.getUI().selection_start == null);
}

test "selection: shift+down extends selection" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Initially no selection
    try std.testing.expect(runner.getUI().selection_start == null);
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().cursor_line);

    // Shift+Down should start selection and move cursor
    try runner.sendShiftDown();
    try std.testing.expect(runner.getUI().selection_start != null);
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().selection_start.?);
    try std.testing.expectEqual(@as(usize, 1), runner.getUI().cursor_line);

    // Another Shift+Down extends selection
    try runner.sendShiftDown();
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().selection_start.?); // start unchanged
    try std.testing.expectEqual(@as(usize, 2), runner.getUI().cursor_line);
}

test "selection: shift+up extends selection" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Move to middle first
    for (0..5) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 5), runner.getUI().cursor_line);
    try std.testing.expect(runner.getUI().selection_start == null);

    // Shift+Up should start selection and move cursor
    try runner.sendShiftUp();
    try std.testing.expect(runner.getUI().selection_start != null);
    try std.testing.expectEqual(@as(usize, 5), runner.getUI().selection_start.?);
    try std.testing.expectEqual(@as(usize, 4), runner.getUI().cursor_line);

    // Another Shift+Up extends selection
    try runner.sendShiftUp();
    try std.testing.expectEqual(@as(usize, 5), runner.getUI().selection_start.?); // start unchanged
    try std.testing.expectEqual(@as(usize, 3), runner.getUI().cursor_line);
}

test "selection: plain arrow movement clears selection" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start a selection
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try std.testing.expect(runner.getUI().selection_start != null);
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().selection_start.?);
    try std.testing.expectEqual(@as(usize, 2), runner.getUI().cursor_line);

    // Plain down (no shift) clears selection
    try runner.sendDown();
    try std.testing.expect(runner.getUI().selection_start == null);
    try std.testing.expectEqual(@as(usize, 3), runner.getUI().cursor_line);

    // Start another selection
    try runner.sendShiftUp();
    try std.testing.expect(runner.getUI().selection_start != null);

    // Plain up clears selection
    try runner.sendUp();
    try std.testing.expect(runner.getUI().selection_start == null);
}

test "selection: escape clears selection" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start a selection
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try std.testing.expect(runner.getUI().selection_start != null);

    // Escape clears selection
    try runner.sendEscape();
    try std.testing.expect(runner.getUI().selection_start == null);
}

test "selection: selection range computes min/max correctly" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Move to middle, then select upward (selection_start > cursor_line)
    for (0..5) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 5), runner.getUI().cursor_line);

    // Select upward
    try runner.sendShiftUp();
    try runner.sendShiftUp();
    try std.testing.expectEqual(@as(usize, 5), runner.getUI().selection_start.?);
    try std.testing.expectEqual(@as(usize, 3), runner.getUI().cursor_line);

    // The selection range should be [3, 5] (min cursor, max selection_start)
    const start = runner.getUI().selection_start.?;
    const cursor = runner.getUI().cursor_line;
    const min_line = @min(start, cursor);
    const max_line = @max(start, cursor);
    try std.testing.expectEqual(@as(usize, 3), min_line);
    try std.testing.expectEqual(@as(usize, 5), max_line);
}

test "selection: selection with shift+pagedown" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 50);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Initially no selection
    try std.testing.expect(runner.getUI().selection_start == null);

    // Shift+f (page down with shift) should start selection
    try runner.sendKey(.{ .codepoint = 'f', .mods = .{ .shift = true } });
    try std.testing.expect(runner.getUI().selection_start != null);
    try std.testing.expectEqual(@as(usize, 0), runner.getUI().selection_start.?);
    try std.testing.expect(runner.getUI().cursor_line > 10); // Should have moved significantly
}

test "selection: selection with shift+pageup" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 50);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Move to middle
    runner.getUI().cursor_line = 30;

    // Shift+p (page up with shift) should start selection
    try runner.sendKey(.{ .codepoint = 'p', .mods = .{ .shift = true } });
    try std.testing.expect(runner.getUI().selection_start != null);
    try std.testing.expectEqual(@as(usize, 30), runner.getUI().selection_start.?);
    try std.testing.expect(runner.getUI().cursor_line < 20); // Should have moved up
}

test "selection: selection persists while extending with shift" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start selection with shift+down
    try runner.sendShiftDown();
    const initial_start = runner.getUI().selection_start;
    try std.testing.expect(initial_start != null);

    // Multiple shift+down should not change selection_start
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try runner.sendShiftDown();

    try std.testing.expectEqual(initial_start, runner.getUI().selection_start);
    try std.testing.expectEqual(@as(usize, 4), runner.getUI().cursor_line);
}

test "selection: space at different cursor positions" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Move to line 3
    for (0..3) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 3), runner.getUI().cursor_line);

    // Toggle selection at line 3
    try runner.sendSpace();
    try std.testing.expect(runner.getUI().selection_start != null);
    try std.testing.expectEqual(@as(usize, 3), runner.getUI().selection_start.?);

    // Toggle off
    try runner.sendSpace();
    try std.testing.expect(runner.getUI().selection_start == null);

    // Move to line 7 and toggle again
    for (0..4) |_| {
        try runner.sendDown();
    }
    try runner.sendSpace();
    try std.testing.expectEqual(@as(usize, 7), runner.getUI().selection_start.?);
}

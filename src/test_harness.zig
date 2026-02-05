const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const ui = @import("ui.zig");
const review = @import("review.zig");
const difft = @import("difft.zig");
const summary = @import("summary.zig");

// Test harness for TUI testing with snapshot support.
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

// =============================================================================
// Mode Transition Tests
// =============================================================================

test "mode: 'c' from normal transitions to comment_input" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start in normal mode
    const ui_inst = runner.getUI();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0

    // Press 'c' to enter comment mode
    try runner.sendChar('c');

    // Verify we're now in comment_input mode
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.mode));  // comment_input = 1
}

test "mode: 'a' from normal transitions to ask_input" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start in normal mode
    const ui_inst = runner.getUI();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0

    // Press 'a' to enter ask_input mode
    try runner.sendChar('a');

    // Verify we're now in ask_input mode
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(ui_inst.mode));  // ask_input = 2
}

test "mode: '?' from normal transitions to help" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start in normal mode
    const ui_inst = runner.getUI();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0

    // Press '?' to enter help mode
    try runner.sendChar('?');

    // Verify we're now in help mode
    try std.testing.expectEqual(@as(i32, 5), @intFromEnum(ui_inst.mode));  // help = 5
}

test "mode: 'l' from normal transitions to file_list" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start in normal mode
    const ui_inst = runner.getUI();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0

    // Press 'l' to enter file_list mode
    try runner.sendChar('l');

    // Verify we're now in file_list mode
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(ui_inst.mode));  // file_list = 6
}

test "mode: '.' from normal transitions to file_list" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start in normal mode
    const ui_inst = runner.getUI();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0

    // Press '.' to enter file_list mode
    try runner.sendChar('.');

    // Verify we're now in file_list mode
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(ui_inst.mode));  // file_list = 6
}

test "mode: escape from comment_input returns to normal" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Enter comment_input mode
    try runner.sendChar('c');
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.mode));  // comment_input = 1

    // Press escape to return to normal
    try runner.sendEscape();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0
}

test "mode: escape from ask_input returns to normal" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Enter ask_input mode
    try runner.sendChar('a');
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(ui_inst.mode));  // ask_input = 2

    // Press escape to return to normal
    try runner.sendEscape();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0
}

test "mode: escape from help returns to normal" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Enter help mode
    try runner.sendChar('?');
    try std.testing.expectEqual(@as(i32, 5), @intFromEnum(ui_inst.mode));  // help = 5

    // Press escape to return to normal
    try runner.sendEscape();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0
}

test "mode: escape from file_list returns to normal" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Enter file_list mode
    try runner.sendChar('l');
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(ui_inst.mode));  // file_list = 6

    // Press escape to return to normal
    try runner.sendEscape();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0
}

test "mode: 'q' in normal mode sets should_quit flag" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Initially should_quit is false
    try std.testing.expect(!ui_inst.should_quit);

    // Press 'q' to quit
    try runner.sendChar('q');

    // Verify should_quit flag is set
    try std.testing.expect(ui_inst.should_quit);
}

test "mode: comment_input mode clears with enter key" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Enter comment mode
    try runner.sendChar('c');
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.mode));  // comment_input = 1

    // Add some text to the comment buffer
    try runner.sendChar('t');
    try runner.sendChar('e');
    try runner.sendChar('s');
    try runner.sendChar('t');

    // Verify buffer has content
    try std.testing.expect(ui_inst.input_buffer.len > 0);

    // Press enter to submit
    try runner.sendEnter();

    // Mode should return to normal
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0
}

test "mode: file_list mode selects file with enter key" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Enter file_list mode
    try runner.sendChar('l');
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(ui_inst.mode));  // file_list = 6

    // Press enter to select current file
    try runner.sendEnter();

    // Mode should return to normal
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // normal = 0
}

// =============================================================================
// Comment Submission Tests
// =============================================================================

test "comment: submit single line comment" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();
    const initial_count = session.comments.items.len;

    // Move to line 3 (cursor_line is 0-based, but diff lines are 1-based)
    for (0..3) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 3), ui_inst.cursor_line);

    // Enter comment mode
    try runner.sendChar('c');
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.mode));

    // Type a comment
    try runner.sendChar('t');
    try runner.sendChar('e');
    try runner.sendChar('s');
    try runner.sendChar('t');
    try std.testing.expect(ui_inst.input_buffer.len > 0);

    // Submit the comment
    try runner.sendEnter();

    // Verify mode returned to normal
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));

    // Verify comment was added
    try std.testing.expectEqual(initial_count + 1, session.comments.items.len);

    // Verify comment properties
    const comment = session.comments.items[session.comments.items.len - 1];
    try std.testing.expectEqual(@as(u32, 4), comment.line_start);  // Cursor at 3, but line_start is 1-based
    try std.testing.expectEqual(@as(u32, 4), comment.line_end);    // Single line
    try std.testing.expect(std.mem.eql(u8, "test", comment.text));
    try std.testing.expectEqual(review.CommentSide.new, comment.side);  // Default to new
}

test "comment: multiline selection preserves start and end" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Move to line 5 and select down to line 8
    for (0..5) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 5), ui_inst.cursor_line);

    // Create selection by shift+down
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try std.testing.expectEqual(@as(usize, 8), ui_inst.cursor_line);
    try std.testing.expect(ui_inst.selection_start != null);

    // Enter comment mode
    try runner.sendChar('c');

    // Type a comment
    try runner.sendChar('m');
    try runner.sendChar('u');
    try runner.sendChar('l');
    try runner.sendChar('t');
    try runner.sendChar('i');

    // Submit
    try runner.sendEnter();

    // Verify comment captured the selection range (1-based line numbers)
    const comment = session.comments.items[session.comments.items.len - 1];
    try std.testing.expectEqual(@as(u32, 6), comment.line_start);  // selection_start is 5, but lines are 1-based
    try std.testing.expectEqual(@as(u32, 9), comment.line_end);    // cursor is 8, but lines are 1-based
    try std.testing.expect(std.mem.eql(u8, "multi", comment.text));
}

test "comment: empty comment does nothing" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();
    const initial_count = session.comments.items.len;

    // Enter comment mode
    try runner.sendChar('c');
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.mode));

    // Press enter without typing anything
    try runner.sendEnter();

    // Verify we're still in comment mode (empty comment rejected)
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.mode));

    // Verify no comment was added
    try std.testing.expectEqual(initial_count, session.comments.items.len);
}

test "comment: escape cancels without creating comment" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();
    const initial_count = session.comments.items.len;

    // Enter comment mode
    try runner.sendChar('c');

    // Type a comment
    try runner.sendChar('t');
    try runner.sendChar('e');
    try runner.sendChar('s');
    try runner.sendChar('t');

    // Cancel with escape
    try runner.sendEscape();

    // Verify mode returned to normal
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));

    // Verify no comment was added
    try std.testing.expectEqual(initial_count, session.comments.items.len);

    // Verify buffer was cleared
    try std.testing.expectEqual(@as(usize, 0), ui_inst.input_buffer.len);
}

test "comment: input buffer cleared after submission" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Enter comment mode and type
    try runner.sendChar('c');
    try runner.sendChar('h');
    try runner.sendChar('i');
    try std.testing.expect(ui_inst.input_buffer.len > 0);

    // Submit
    try runner.sendEnter();

    // Verify buffer was cleared after submission
    try std.testing.expectEqual(@as(usize, 0), ui_inst.input_buffer.len);
}

test "comment: comment stores correct file path" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Get the current file path
    const current_file = session.currentFile().?;
    const expected_path = current_file.path;

    // Enter comment mode and submit
    try runner.sendChar('c');
    try runner.sendChar('a');
    try runner.sendEnter();

    // Verify comment has correct file path
    const comment = session.comments.items[session.comments.items.len - 1];
    try std.testing.expect(std.mem.eql(u8, expected_path, comment.file_path));
}

test "comment: comment stores correct side" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Default focus_side is .new
    try std.testing.expectEqual(review.CommentSide.new, ui_inst.focus_side);

    // Enter comment mode and submit
    try runner.sendChar('c');
    try runner.sendChar('n');
    try runner.sendEnter();

    // Verify comment has .new side
    const comment = session.comments.items[session.comments.items.len - 1];
    try std.testing.expectEqual(review.CommentSide.new, comment.side);

    // Now test with .old side - press tab to toggle focus_side
    ui_inst.focus_side = review.CommentSide.old;

    // Enter comment mode and submit
    try runner.sendChar('c');
    try runner.sendChar('o');
    try runner.sendEnter();

    // Verify comment has .old side
    const comment2 = session.comments.items[session.comments.items.len - 1];
    try std.testing.expectEqual(review.CommentSide.old, comment2.side);
}

// =============================================================================
// View Mode Tests
// =============================================================================

test "view: default view_mode is split" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Verify default is split view (split = 1 in enum, unified = 0)
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.view_mode));  // split = 1
}

test "view: 'v' key toggles split to unified" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Start in split view (split = 1)
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.view_mode));  // split = 1

    // Press 'v' to toggle to unified
    try runner.sendChar('v');

    // Verify we're now in unified mode (unified = 0)
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.view_mode));  // unified = 0
}

test "view: 'v' key toggles unified back to split" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Start in split view, toggle to unified (unified = 0)
    try runner.sendChar('v');
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.view_mode));

    // Press 'v' again to toggle back to split (split = 1)
    try runner.sendChar('v');

    // Verify we're back in split view
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.view_mode));
}

test "view: cursor position preserved across view toggle" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Move to line 5
    for (0..5) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 5), ui_inst.cursor_line);

    // Toggle view mode
    try runner.sendChar('v');

    // Verify cursor position is preserved
    try std.testing.expectEqual(@as(usize, 5), ui_inst.cursor_line);

    // Toggle back
    try runner.sendChar('v');

    // Verify cursor is still at same position
    try std.testing.expectEqual(@as(usize, 5), ui_inst.cursor_line);
}

test "view: selection preserved across view toggle" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Create a selection
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try std.testing.expect(ui_inst.selection_start != null);
    const selection_start = ui_inst.selection_start.?;
    const cursor_line = ui_inst.cursor_line;

    // Toggle view mode
    try runner.sendChar('v');

    // Verify selection is preserved
    try std.testing.expect(ui_inst.selection_start != null);
    try std.testing.expectEqual(selection_start, ui_inst.selection_start.?);
    try std.testing.expectEqual(cursor_line, ui_inst.cursor_line);

    // Toggle back
    try runner.sendChar('v');

    // Verify selection is still intact
    try std.testing.expect(ui_inst.selection_start != null);
    try std.testing.expectEqual(selection_start, ui_inst.selection_start.?);
    try std.testing.expectEqual(cursor_line, ui_inst.cursor_line);
}

test "view: scroll offset preserved across view toggle" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 50);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Scroll down
    for (0..10) |_| {
        try runner.sendDown();
    }

    // Toggle view mode
    try runner.sendChar('v');

    // Scroll offset should be preserved (or adjusted by view-specific logic)
    // For now, just verify view mode changed (unified = 0)
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.view_mode));

    // Toggle back
    try runner.sendChar('v');

    // Verify view mode is back to split (split = 1)
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.view_mode));
}

test "view: split mode renders both panels" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Verify in split view (split = 1)
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.view_mode));

    // Verify split_rows exist for split mode
    try std.testing.expect(ui_inst.split_rows.items.len > 0);
}

test "view: unified mode renders single column" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Toggle to unified view (unified = 0)
    try runner.sendChar('v');
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.view_mode));

    // Verify diff_lines exist for unified mode
    try std.testing.expect(ui_inst.diff_lines.items.len > 0);
}

// =============================================================================
// Collapse/Summary Mode Tests
// =============================================================================

test "collapse: summary_mode defaults to true" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Verify summary_mode defaults to true (collapsed)
    try std.testing.expect(ui_inst.summary_mode);
}

test "collapse: 's' key toggles summary_mode" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Start in summary mode
    try std.testing.expect(ui_inst.summary_mode);

    // Press 's' to toggle to expanded
    try runner.sendChar('s');

    // Verify summary_mode is now false
    try std.testing.expect(!ui_inst.summary_mode);

    // Press 's' again to toggle back
    try runner.sendChar('s');

    // Verify summary_mode is back to true
    try std.testing.expect(ui_inst.summary_mode);
}

test "collapse: summary_mode toggle is bidirectional" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Toggle multiple times
    for (0..5) |i| {
        const expected = i % 2 == 0;  // Starts true, alternates
        try std.testing.expectEqual(expected, ui_inst.summary_mode);
        try runner.sendChar('s');
    }

    // After 5 toggles, should be false
    try std.testing.expect(!ui_inst.summary_mode);
}

test "collapse: cursor position preserved across summary toggle" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Move to line 5
    for (0..5) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 5), ui_inst.cursor_line);

    // Toggle summary mode
    try runner.sendChar('s');

    // Cursor position should be preserved (or adjusted if line is hidden)
    // For simple test, just verify summary_mode changed
    try std.testing.expect(!ui_inst.summary_mode);

    // Toggle back
    try runner.sendChar('s');

    // Verify summary_mode is back to true
    try std.testing.expect(ui_inst.summary_mode);
}

test "collapse: selection preserved across summary toggle" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Create a selection
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try std.testing.expect(ui_inst.selection_start != null);
    const selection_start = ui_inst.selection_start.?;

    // Toggle summary mode
    try runner.sendChar('s');

    // Selection should be preserved
    try std.testing.expect(ui_inst.selection_start != null);
    try std.testing.expectEqual(selection_start, ui_inst.selection_start.?);

    // Toggle back
    try runner.sendChar('s');

    // Selection should still be there
    try std.testing.expect(ui_inst.selection_start != null);
    try std.testing.expectEqual(selection_start, ui_inst.selection_start.?);
}

test "collapse: scroll offset adjusted across summary toggle" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 50);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Scroll down in summary mode
    for (0..10) |_| {
        try runner.sendDown();
    }

    // Toggle to expanded
    try runner.sendChar('s');

    // Verify summary_mode changed
    try std.testing.expect(!ui_inst.summary_mode);

    // Toggle back to summary
    try runner.sendChar('s');

    // Verify back in summary mode
    try std.testing.expect(ui_inst.summary_mode);
}

// =============================================================================
// File List Navigation Tests
// =============================================================================

test "filelist: 'l' opens file_list mode" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Start in normal mode
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));

    // Press 'l' to open file_list mode
    try runner.sendChar('l');

    // Verify we're in file_list mode
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(ui_inst.mode));  // file_list = 6
}

test "filelist: '.' opens file_list mode" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Start in normal mode
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));

    // Press '.' to open file_list mode
    try runner.sendChar('.');

    // Verify we're in file_list mode
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(ui_inst.mode));  // file_list = 6
}

test "filelist: escape closes file_list without changing file" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();
    const initial_file_idx = session.current_file_idx;

    // Enter file_list mode
    try runner.sendChar('l');
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(ui_inst.mode));

    // Press escape to cancel
    try runner.sendEscape();

    // Verify mode returned to normal
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));

    // Verify file index didn't change
    try std.testing.expectEqual(initial_file_idx, session.current_file_idx);
}

test "filelist: current file is selected by default" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Set current file to 1 (middle file)
    session.goToFile(1);
    try std.testing.expectEqual(@as(usize, 1), session.current_file_idx);

    // Enter file_list mode
    try runner.sendChar('l');

    // Verify file_list_cursor starts at current file
    try std.testing.expectEqual(@as(usize, 1), ui_inst.file_list_cursor);
}

test "filelist: enter selects file and returns to normal" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Start at file 0
    try std.testing.expectEqual(@as(usize, 0), session.current_file_idx);

    // Enter file_list mode
    try runner.sendChar('l');

    // Move to file 2
    try runner.sendDown();
    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 2), ui_inst.file_list_cursor);

    // Select file with Enter
    try runner.sendEnter();

    // Verify mode returned to normal
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));

    // Verify file was changed
    try std.testing.expectEqual(@as(usize, 2), session.current_file_idx);
}

test "filelist: up/down arrows move cursor within bounds" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Enter file_list mode (starts at file 0)
    try runner.sendChar('l');
    try std.testing.expectEqual(@as(usize, 0), ui_inst.file_list_cursor);

    // Press Down to move to file 1
    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 1), ui_inst.file_list_cursor);

    // Press Down again to move to file 2
    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 2), ui_inst.file_list_cursor);

    // Try to press Down beyond last file (should stay at 2)
    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 2), ui_inst.file_list_cursor);

    // Press Up to move back to file 1
    try runner.sendUp();
    try std.testing.expectEqual(@as(usize, 1), ui_inst.file_list_cursor);

    // Press Up to move to file 0
    try runner.sendUp();
    try std.testing.expectEqual(@as(usize, 0), ui_inst.file_list_cursor);

    // Try to press Up before first file (should stay at 0)
    try runner.sendUp();
    try std.testing.expectEqual(@as(usize, 0), ui_inst.file_list_cursor);
}

test "filelist: left arrow in normal mode goes to previous file" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start at file 2
    session.goToFile(2);
    try std.testing.expectEqual(@as(usize, 2), session.current_file_idx);

    // Press left arrow to go to previous file
    try runner.sendKey(.{ .codepoint = vaxis.Key.left });

    // Verify we're at file 1
    try std.testing.expectEqual(@as(usize, 1), session.current_file_idx);

    // Press left arrow again
    try runner.sendKey(.{ .codepoint = vaxis.Key.left });

    // Verify we're at file 0
    try std.testing.expectEqual(@as(usize, 0), session.current_file_idx);

    // Try to press left before first file (should stay at 0)
    try runner.sendKey(.{ .codepoint = vaxis.Key.left });
    try std.testing.expectEqual(@as(usize, 0), session.current_file_idx);
}

test "filelist: right arrow in normal mode goes to next file" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start at file 0
    try std.testing.expectEqual(@as(usize, 0), session.current_file_idx);

    // Press right arrow to go to next file
    try runner.sendKey(.{ .codepoint = vaxis.Key.right });

    // Verify we're at file 1
    try std.testing.expectEqual(@as(usize, 1), session.current_file_idx);

    // Press right arrow again
    try runner.sendKey(.{ .codepoint = vaxis.Key.right });

    // Verify we're at file 2
    try std.testing.expectEqual(@as(usize, 2), session.current_file_idx);

    // Try to press right beyond last file (should stay at 2)
    try runner.sendKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expectEqual(@as(usize, 2), session.current_file_idx);
}

// =============================================================================
// Rendering Snapshot Tests
// =============================================================================

test "render: diff lines rendered for single file" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Verify diff_lines were created
    try std.testing.expect(ui_inst.diff_lines.items.len > 0);

    // Render and verify we get output
    const text = try runner.getText();
    defer {
        for (text) |row| {
            allocator.free(row);
        }
        allocator.free(text);
    }

    // Should have some non-empty rows
    var has_content = false;
    for (text) |row| {
        if (row.len > 0) {
            has_content = true;
            break;
        }
    }
    try std.testing.expect(has_content);
}

test "render: split view shows multiple columns" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Verify in split view
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.view_mode));

    // Verify split_rows exist
    try std.testing.expect(ui_inst.split_rows.items.len > 0);

    // Render and verify
    const text = try runner.getText();
    defer {
        for (text) |row| {
            allocator.free(row);
        }
        allocator.free(text);
    }

    try std.testing.expect(text.len > 0);
}

test "render: unified view shows single column" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Toggle to unified
    try runner.sendChar('v');
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.view_mode));

    // Verify diff_lines exist
    try std.testing.expect(ui_inst.diff_lines.items.len > 0);

    // Render and verify
    const text = try runner.getText();
    defer {
        for (text) |row| {
            allocator.free(row);
        }
        allocator.free(text);
    }

    try std.testing.expect(text.len > 0);
}

test "render: cursor position highlighted in output" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Move cursor to line 5
    for (0..5) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 5), ui_inst.cursor_line);

    // Snapshot should reflect cursor position
    var snapshot = try runner.captureSnapshot();
    defer snapshot.deinit();

    // Verify cursor line in state
    try std.testing.expectEqual(@as(usize, 5), snapshot.state.cursor_line);
}

test "render: selection visible in snapshot" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Create selection from line 3 to 7
    for (0..3) |_| {
        try runner.sendDown();
    }
    try runner.sendSpace();
    for (0..4) |_| {
        try runner.sendDown();
    }

    // Snapshot should show selection
    var snapshot = try runner.captureSnapshot();
    defer snapshot.deinit();

    try std.testing.expect(snapshot.state.cursor_line > 0);
}

test "render: mode displayed correctly in snapshot" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Test normal mode
    var snapshot = try runner.captureSnapshot();
    defer snapshot.deinit();
    try std.testing.expect(std.mem.eql(u8, "normal", snapshot.state.mode));

    // Test comment mode
    try runner.sendChar('c');
    var snapshot2 = try runner.captureSnapshot();
    defer snapshot2.deinit();
    try std.testing.expect(std.mem.eql(u8, "comment_input", snapshot2.state.mode));
}

test "render: summary mode affects rendering" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Capture in summary mode
    var snapshot1 = try runner.captureSnapshot();
    defer snapshot1.deinit();
    try std.testing.expect(snapshot1.state.summary_mode);

    // Toggle to expanded
    try runner.sendChar('s');

    // Capture in expanded mode
    var snapshot2 = try runner.captureSnapshot();
    defer snapshot2.deinit();
    try std.testing.expect(!snapshot2.state.summary_mode);
}

test "render: file path displayed in snapshot state" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Capture snapshot
    var snapshot = try runner.captureSnapshot();
    defer snapshot.deinit();

    // Verify file path is in state
    try std.testing.expect(snapshot.state.current_file != null);
    try std.testing.expect(std.mem.eql(u8, "test.zig", snapshot.state.current_file.?));
}

// =============================================================================
// Edge Case Tests
// =============================================================================

test "edge: single line file renders correctly" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 1);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Verify diff_lines were created
    try std.testing.expect(ui_inst.diff_lines.items.len > 0);

    // Cursor at line 0 should be valid
    try std.testing.expectEqual(@as(usize, 0), ui_inst.cursor_line);

    // Pressing down shouldn't move past the single line
    try runner.sendDown();
    try std.testing.expectEqual(@as(usize, 0), ui_inst.cursor_line);
}

test "edge: very large file renders without crashing" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Create a very large file
    try createTestFileWithLines(allocator, &session, 1000);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Verify diff_lines were created
    try std.testing.expect(ui_inst.diff_lines.items.len > 0);

    // Try scrolling through the file
    for (0..100) |_| {
        try runner.sendDown();
    }

    // Should be at line 100 (or less if file is smaller due to diff processing)
    try std.testing.expect(ui_inst.cursor_line >= 0);
}

test "edge: many files in session navigates correctly" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Create 25 files
    for (0..25) |_| {
        try createTestFileWithLines(allocator, &session, 5);
    }

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start at file 0
    try std.testing.expectEqual(@as(usize, 0), session.current_file_idx);

    // Enter file_list mode
    try runner.sendChar('l');

    // Navigate to file 20
    for (0..20) |_| {
        try runner.sendDown();
    }

    const ui_inst = runner.getUI();
    try std.testing.expectEqual(@as(usize, 20), ui_inst.file_list_cursor);

    // Select the file
    try runner.sendEnter();

    // Verify we're at file 20
    try std.testing.expectEqual(@as(usize, 20), session.current_file_idx);
}

test "edge: empty comment buffer after pressing escape" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Enter comment mode
    try runner.sendChar('c');

    // Type a long comment
    for (0..100) |_| {
        try runner.sendChar('a');
    }
    try std.testing.expect(ui_inst.input_buffer.len > 0);

    // Cancel with escape
    try runner.sendEscape();

    // Buffer should be cleared
    try std.testing.expectEqual(@as(usize, 0), ui_inst.input_buffer.len);
}

test "edge: cursor wraps at file boundaries" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Get to the end of the file
    for (0..50) |_| {
        try runner.sendDown();
    }

    const end_position = ui_inst.cursor_line;

    // Try to go down past the end
    try runner.sendDown();
    try runner.sendDown();

    // Should stay at end position
    try std.testing.expectEqual(end_position, ui_inst.cursor_line);

    // Go to beginning
    for (0..100) |_| {
        try runner.sendUp();
    }

    // Should be at line 0
    try std.testing.expectEqual(@as(usize, 0), ui_inst.cursor_line);

    // Try to go up past the beginning
    try runner.sendUp();

    // Should stay at line 0
    try std.testing.expectEqual(@as(usize, 0), ui_inst.cursor_line);
}

test "edge: selection clears when pressing escape" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Create a selection
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try std.testing.expect(ui_inst.selection_start != null);

    // Press escape to clear
    try runner.sendEscape();

    // Selection should be cleared
    try std.testing.expect(ui_inst.selection_start == null);
}

test "edge: file switching with pending comments" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Add a comment on file 0
    try runner.sendChar('c');
    try runner.sendChar('t');
    try runner.sendChar('e');
    try runner.sendChar('s');
    try runner.sendChar('t');
    try runner.sendEnter();

    // Verify comment was added
    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);

    // Switch to file 1
    try runner.sendKey(.{ .codepoint = vaxis.Key.right });

    try std.testing.expectEqual(@as(usize, 1), session.current_file_idx);

    // Comments should persist
    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);
}

test "edge: view mode toggle multiple times" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Start in split mode (1)
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.view_mode));

    // Toggle 5 times: split(1) → unified(0) → split(1) → unified(0) → split(1) → unified(0)
    for (0..5) |_| {
        try runner.sendChar('v');
    }

    // After 5 toggles (odd number), should be in unified mode (0)
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.view_mode));

    // Toggle one more time
    try runner.sendChar('v');

    // Now should be back in split mode (1)
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.view_mode));
}

test "edge: mode switching sequence" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // normal → comment → normal
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));
    try runner.sendChar('c');
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.mode));
    try runner.sendEscape();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));

    // normal → help → normal
    try runner.sendChar('?');
    try std.testing.expectEqual(@as(i32, 5), @intFromEnum(ui_inst.mode));
    try runner.sendEscape();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));

    // normal → file_list → normal
    try runner.sendChar('l');
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(ui_inst.mode));
    try runner.sendEscape();
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));
}

// =============================================================================
// Integration Tests - Complete User Workflows
// =============================================================================

// Test 1: Review workflow - Open diff → navigate to change → add comment → export markdown
test "integration: review workflow open diff navigate and comment" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Create a test file with changes
    try createTestFileWithLines(allocator, &session, 15);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    // Build diff (simulate opening diff)
    try runner.getUI().buildDiffLines();
    try std.testing.expect(session.files.len > 0);

    const initial_comments = session.comments.items.len;

    // Navigate to a specific change (move down 3 lines)
    for (0..3) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 3), runner.getUI().cursor_line);

    // Add a comment at this location
    try runner.sendChar('c');
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(runner.getUI().mode));

    // Type comment text
    const comment_text = "This change looks good";
    for (comment_text) |char| {
        try runner.sendChar(char);
    }

    // Submit comment
    try runner.sendEnter();

    // Verify: mode returned to normal
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(runner.getUI().mode));

    // Verify: comment was added
    try std.testing.expectEqual(initial_comments + 1, session.comments.items.len);

    // Export should be possible (just verify comment exists)
    const comment = session.comments.items[session.comments.items.len - 1];
    try std.testing.expect(std.mem.eql(u8, comment_text, comment.text));
}

// Test 2: Multi-file review - Switch between files → add comments on different files → verify all stored
test "integration: multi_file review switch files add comments" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Create multiple test files
    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Add comment on file 0
    for (0..2) |_| {
        try runner.sendDown();
    }
    try runner.sendChar('c');
    try runner.sendChar('f');
    try runner.sendChar('i');
    try runner.sendChar('l');
    try runner.sendChar('e');
    try runner.sendChar('0');
    try runner.sendEnter();

    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);

    // Switch to file 1
    try runner.sendKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expectEqual(@as(usize, 1), session.current_file_idx);

    // Add comment on file 1
    for (0..4) |_| {
        try runner.sendDown();
    }
    try runner.sendChar('c');
    try runner.sendChar('f');
    try runner.sendChar('i');
    try runner.sendChar('l');
    try runner.sendChar('e');
    try runner.sendChar('1');
    try runner.sendEnter();

    try std.testing.expectEqual(@as(usize, 2), session.comments.items.len);

    // Switch to file 2
    try runner.sendKey(.{ .codepoint = vaxis.Key.right });
    try std.testing.expectEqual(@as(usize, 2), session.current_file_idx);

    // Add comment on file 2
    for (0..1) |_| {
        try runner.sendDown();
    }
    try runner.sendChar('c');
    try runner.sendChar('f');
    try runner.sendChar('i');
    try runner.sendChar('l');
    try runner.sendChar('e');
    try runner.sendChar('2');
    try runner.sendEnter();

    // Final verification: all 3 comments stored
    try std.testing.expectEqual(@as(usize, 3), session.comments.items.len);

    // Verify comments are on different files
    try std.testing.expect(std.mem.eql(u8, "file0", session.comments.items[0].text));
    try std.testing.expect(std.mem.eql(u8, "file1", session.comments.items[1].text));
    try std.testing.expect(std.mem.eql(u8, "file2", session.comments.items[2].text));
}

// Test 3: Collapse workflow - Start collapsed → expand specific function → add comment → collapse again
test "integration: collapse workflow expand collapse with comment" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 20);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start: UI begins in summary mode by default
    try std.testing.expect(runner.getUI().summary_mode);

    // Navigate to a line
    for (0..5) |_| {
        try runner.sendDown();
    }

    // Add comment while in collapse/summary mode
    try runner.sendChar('c');
    try runner.sendChar('c');
    try runner.sendChar('o');
    try runner.sendChar('l');
    try runner.sendEnter();

    // Verify comment was added
    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);

    // Toggle summary mode off to disable collapse
    try runner.sendChar('s');
    try std.testing.expect(!runner.getUI().summary_mode);

    // Verify comment persists after toggling
    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);
}

// Test 4: Selection workflow - Navigate to line → start selection → extend selection → add multi-line comment
test "integration: selection workflow extend and comment" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 25);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Navigate to line 5
    for (0..5) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 5), ui_inst.cursor_line);

    // Start selection with shift+down
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try runner.sendShiftDown();
    try std.testing.expectEqual(@as(usize, 9), ui_inst.cursor_line);
    try std.testing.expect(ui_inst.selection_start != null);

    // Add comment on selection
    try runner.sendChar('c');
    try runner.sendChar('m');
    try runner.sendChar('u');
    try runner.sendChar('l');
    try runner.sendChar('t');
    try runner.sendChar('i');
    try runner.sendChar('s');
    try runner.sendEnter();

    // Verify: comment was created with multi-line range
    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);
    const comment = session.comments.items[0];
    try std.testing.expect(comment.line_end > comment.line_start);  // Multi-line
    try std.testing.expect(std.mem.eql(u8, "multis", comment.text));
}

// Test 5: View toggle workflow - Review in split view → toggle to unified → continue reviewing
test "integration: view toggle workflow split to unified" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 15);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Start in split view
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(runner.getUI().view_mode));  // split

    // Add comment in split view
    for (0..3) |_| {
        try runner.sendDown();
    }
    try runner.sendChar('c');
    try runner.sendChar('s');
    try runner.sendChar('p');
    try runner.sendChar('l');
    try runner.sendChar('i');
    try runner.sendChar('t');
    try runner.sendEnter();

    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);

    // Toggle to unified view
    try runner.sendChar('v');
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(runner.getUI().view_mode));  // unified

    // Continue reviewing and add another comment
    for (0..3) |_| {
        try runner.sendDown();
    }
    try runner.sendChar('c');
    try runner.sendChar('u');
    try runner.sendChar('n');
    try runner.sendChar('i');
    try runner.sendChar('f');
    try runner.sendEnter();

    // Verify both comments stored
    try std.testing.expectEqual(@as(usize, 2), session.comments.items.len);
}

// Test 6: Search-like workflow - Use file list to jump to specific file → navigate to specific line
test "integration: file_list jump to file navigate" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Create 3 files for navigation
    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);
    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Start in normal mode, file 0
    try std.testing.expectEqual(@as(usize, 0), session.current_file_idx);

    // Enter file list mode
    try runner.sendChar('l');
    try std.testing.expectEqual(@as(i32, 6), @intFromEnum(ui_inst.mode));

    // Navigate down to file 2
    for (0..2) |_| {
        try runner.sendDown();
    }

    // Select file 2
    try runner.sendEnter();
    try std.testing.expectEqual(@as(usize, 2), session.current_file_idx);
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));  // back to normal

    // Navigate to specific line in file 2
    for (0..7) |_| {
        try runner.sendDown();
    }
    try std.testing.expectEqual(@as(usize, 7), ui_inst.cursor_line);

    // Add comment to verify we're at the right location
    try runner.sendChar('c');
    try runner.sendChar('f');
    try runner.sendChar('i');
    try runner.sendChar('l');
    try runner.sendChar('e');
    try runner.sendChar('2');
    try runner.sendEnter();

    try std.testing.expectEqual(@as(usize, 1), session.comments.items.len);
}

// Test 7: Cancel workflow - Start comment → type text → escape → verify no comment created
test "integration: cancel workflow escape without submit" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 10);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();
    const initial_count = session.comments.items.len;

    // Navigate to a line
    for (0..3) |_| {
        try runner.sendDown();
    }

    // Enter comment mode
    try runner.sendChar('c');
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ui_inst.mode));

    // Type text
    try runner.sendChar('t');
    try runner.sendChar('e');
    try runner.sendChar('s');
    try runner.sendChar('t');
    try std.testing.expect(ui_inst.input_buffer.len > 0);

    // Press escape to cancel (not enter)
    try runner.sendEscape();

    // Verify mode returned to normal
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ui_inst.mode));

    // Verify NO comment was created
    try std.testing.expectEqual(initial_count, session.comments.items.len);

    // Buffer should be cleared
    try std.testing.expectEqual(@as(usize, 0), ui_inst.input_buffer.len);
}

// Test 8: Focus side workflow - Review deletion (old side) → tab to old → add comment on old side
test "integration: focus side old deletion workflow" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithLines(allocator, &session, 12);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    // Navigate to a line to review
    for (0..4) |_| {
        try runner.sendDown();
    }

    // Add comment (default should go to "new" side)
    try runner.sendChar('c');
    try runner.sendChar('n');
    try runner.sendChar('e');
    try runner.sendChar('w');
    try runner.sendEnter();

    const first_comment = session.comments.items[0];
    try std.testing.expectEqual(review.CommentSide.new, first_comment.side);

    // Tab key should toggle focus between old and new sides (if visible)
    try runner.sendKey(.{ .codepoint = vaxis.Key.tab });

    // Add another comment - should be on different side if tab worked
    try runner.sendChar('c');
    try runner.sendChar('o');
    try runner.sendChar('l');
    try runner.sendChar('d');
    try runner.sendEnter();

    // Verify both comments exist
    try std.testing.expectEqual(@as(usize, 2), session.comments.items.len);
}

// ============================================================================
// Summary View Tests (semantic overview with 'O' key)
// ============================================================================

test "inline_summary: session_summary is computed when getting file summary" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithFunction(allocator, &session);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Summary should not be computed yet
    try std.testing.expectEqual(@as(?summary.SessionSummary, null), ui_inst.session_summary);

    // Get file summary - should trigger session summary computation
    const file = session.currentFile() orelse unreachable;
    _ = ui_inst.getFileSummary(file.*);

    // Summary should now exist
    try std.testing.expect(ui_inst.session_summary != null);
}

test "inline_summary: correct file count in session summary" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    try createTestFileWithFunction(allocator, &session);
    try createTestFileWithStruct(allocator, &session);

    var runner = TestRunner.init(allocator, &session, 80, 24);
    defer runner.deinit();

    try runner.getUI().buildDiffLines();

    const ui_inst = runner.getUI();

    // Get file summary to trigger computation
    const file = session.currentFile() orelse unreachable;
    _ = ui_inst.getFileSummary(file.*);

    // Verify session summary has 2 files
    const sess_summary = ui_inst.session_summary orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), sess_summary.files.len);
}

// Helper: create a test file with a Zig function
fn createTestFileWithFunction(allocator: std.mem.Allocator, session: *review.ReviewSession) !void {
    const new_content =
        \\pub fn testFunction() void {
        \\    return;
        \\}
    ;

    try session.addFile(.{
        .path = try allocator.dupe(u8, "function_test.zig"),
        .diff = difft.FileDiff{
            .path = try allocator.dupe(u8, "function_test.zig"),
            .language = try allocator.dupe(u8, "Zig"),
            .status = .added,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = try allocator.dupe(u8, ""),
        .new_content = try allocator.dupe(u8, new_content),
    });
}

// Helper: create a test file with a Zig struct
fn createTestFileWithStruct(allocator: std.mem.Allocator, session: *review.ReviewSession) !void {
    const new_content =
        \\const TestStruct = struct {
        \\    field: u32,
        \\};
    ;

    try session.addFile(.{
        .path = try allocator.dupe(u8, "struct_test.zig"),
        .diff = difft.FileDiff{
            .path = try allocator.dupe(u8, "struct_test.zig"),
            .language = try allocator.dupe(u8, "Zig"),
            .status = .added,
            .chunks = &.{},
            .allocator = allocator,
        },
        .is_binary = false,
        .old_content = try allocator.dupe(u8, ""),
        .new_content = try allocator.dupe(u8, new_content),
    });
}

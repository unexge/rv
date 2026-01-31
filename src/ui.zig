const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const review = @import("review.zig");
const difft = @import("difft.zig");
const highlight = @import("highlight.zig");
const collapse = @import("collapse.zig");
const pi = @import("pi.zig");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub const UIError = error{
    InitFailed,
    RenderFailed,
    TtyError,
} || Allocator.Error;

const Mode = enum {
    normal,
    comment_input,
    ask_input,
    ask_response,
    ask_response_comment, // Comment input from response view
    help,
    file_list,
};

const ViewMode = enum {
    unified,
    split,
};

/// Represents a single line in the unified diff view
const DiffLine = struct {
    old_line_num: ?u32 = null, // Line number in old file (LHS)
    new_line_num: ?u32 = null, // Line number in new file (RHS)
    content: []const u8,
    old_content: ?[]const u8 = null, // For modifications: the old content (shown struck through or dimmed)
    changes: []const difft.Change = &.{},
    old_changes: []const difft.Change = &.{}, // Changes highlighting for old content
    line_type: LineType,
    selectable: bool = true,
    is_partial_change: bool = false, // True if only part of line changed (unchanged parts shown in white)
    content_byte_offset: u32 = 0, // Byte offset of this line in the new file content (for syntax highlighting)
    old_content_byte_offset: u32 = 0, // Byte offset of this line in the old file content (for syntax highlighting)

    const LineType = enum {
        context, // Unchanged line (shown with space prefix)
        addition, // Added line (shown with + prefix)
        deletion, // Deleted line (shown with - prefix)
        modification, // Modified line (shown with ~ prefix, both old and new)
    };
};

/// Represents a row in split view (left and right panels)
const SplitRow = struct {
    left: ?SplitCell = null, // Old file side (null for additions)
    right: ?SplitCell = null, // New file side (null for deletions)
    selectable: bool = true,
    is_separator: bool = false, // True for "..." separator rows

    const SplitCell = struct {
        line_num: u32,
        content: []const u8,
        changes: []const difft.Change = &.{},
        line_type: DiffLine.LineType,
        content_byte_offset: u32 = 0,
    };
};

/// Main application model for the code review TUI
pub const UI = struct {
    allocator: Allocator,
    io: Io,
    session: *review.ReviewSession,
    mode: Mode = .normal,
    view_mode: ViewMode = .split, // Default to split view
    scroll_offset: usize = 0,
    cursor_line: usize = 0,
    selection_start: ?usize = null,
    input_buffer: InputBuffer = .{},
    message: ?[]const u8 = null,
    message_is_error: bool = false,
    diff_lines: std.ArrayList(DiffLine),
    split_rows: std.ArrayList(SplitRow),
    should_quit: bool = false,
    focus_side: review.CommentSide = .new,
    file_list_cursor: usize = 0,
    // Syntax highlighting
    highlighter: ?highlight.Highlighter = null,
    old_highlighter: ?highlight.Highlighter = null, // For old file in split view
    syntax_spans: []const highlight.HighlightSpan = &.{},
    old_syntax_spans: []const highlight.HighlightSpan = &.{}, // For old file in split view
    // Ask mode state
    ask_response: ?[]const u8 = null,
    ask_scroll_offset: usize = 0,
    ask_context_file: ?[]const u8 = null,
    ask_context_lines: ?struct { start: u32, end: u32 } = null,
    project_path: ?[]const u8 = null,
    pi_bin: ?[]const u8 = null, // Path to pi binary (from RV_PI_BIN env)
    // Async ask state
    ask_thread: ?std.Thread = null,
    ask_thread_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ask_thread_result: ?[]const u8 = null,
    ask_thread_error: ?[]const u8 = null,
    ask_pending_prompt: ?[]const u8 = null,
    ask_in_progress: bool = false, // True while waiting for Pi response (non-blocking)
    ask_original_question: ?[]const u8 = null, // Store original question for response view
    ask_original_code: ?[]const u8 = null, // Store selected code for response view
    ask_original_diff_lines: std.ArrayList(DiffLine) = .empty, // Store selected diff lines
    ask_original_split_rows: std.ArrayList(SplitRow) = .empty, // Store selected split rows
    ask_original_file: ?[]const u8 = null, // Store file path at time of ask
    spinner_frame: usize = 0,
    // Collapse/summary mode state
    summary_mode: bool = true, // Start in summary mode (collapsed)
    collapse_regions: []collapse.CollapsibleRegion = &.{}, // Collapsible regions for current file
    old_collapse_regions: []collapse.CollapsibleRegion = &.{}, // Regions for old file content

    const InputBuffer = struct {
        buffer: [4096]u8 = undefined,
        len: usize = 0,

        pub fn clear(self: *InputBuffer) void {
            self.len = 0;
        }

        pub fn append(self: *InputBuffer, char: u8) void {
            if (self.len < self.buffer.len) {
                self.buffer[self.len] = char;
                self.len += 1;
            }
        }

        pub fn backspace(self: *InputBuffer) void {
            if (self.len > 0) {
                self.len -= 1;
            }
        }

        pub fn slice(self: *const InputBuffer) []const u8 {
            return self.buffer[0..self.len];
        }
    };

    pub fn init(allocator: Allocator, io: Io, session: *review.ReviewSession) UI {
        return UI{
            .allocator = allocator,
            .io = io,
            .session = session,
            .diff_lines = .empty,
            .split_rows = .empty,
        };
    }

    /// Initialize UI for testing (without Io - askPi won't work)
    pub fn initForTest(allocator: Allocator, session: *review.ReviewSession) UI {
        return UI{
            .allocator = allocator,
            .io = undefined, // Not used in tests
            .session = session,
            .diff_lines = .empty,
            .split_rows = .empty,
        };
    }

    pub fn setProjectPath(self: *UI, path: []const u8) void {
        self.project_path = path;
    }

    pub fn setPiBin(self: *UI, path: ?[]const u8) void {
        self.pi_bin = path;
    }

    pub fn deinit(self: *UI) void {
        // Wait for any pending ask thread to complete
        if (self.ask_thread) |thread| {
            thread.join();
        }
        for (self.diff_lines.items) |line| {
            if (line.content.len > 0) self.allocator.free(line.content);
            if (line.old_content) |oc| {
                if (oc.len > 0) self.allocator.free(oc);
            }
            if (line.changes.len > 0) {
                for (line.changes) |change| {
                    if (change.content.len > 0) self.allocator.free(change.content);
                }
                self.allocator.free(line.changes);
            }
            if (line.old_changes.len > 0) {
                for (line.old_changes) |change| {
                    if (change.content.len > 0) self.allocator.free(change.content);
                }
                self.allocator.free(line.old_changes);
            }
        }
        self.diff_lines.deinit(self.allocator);
        // Clean up split rows
        self.freeSplitRows();
        self.split_rows.deinit(self.allocator);
        if (self.ask_response) |resp| {
            self.allocator.free(resp);
        }
        if (self.ask_thread_result) |resp| {
            self.allocator.free(resp);
        }
        if (self.ask_thread_error) |err| {
            self.allocator.free(err);
        }
        if (self.ask_pending_prompt) |prompt| {
            self.allocator.free(prompt);
        }
        if (self.ask_original_question) |q| {
            self.allocator.free(q);
        }
        if (self.ask_original_code) |c| {
            self.allocator.free(c);
        }
        if (self.ask_original_file) |f| {
            self.allocator.free(f);
        }
        self.freeAskOriginalLines();
        // Clean up syntax highlighting
        if (self.syntax_spans.len > 0) {
            self.allocator.free(self.syntax_spans);
        }
        if (self.highlighter) |*hl| {
            hl.deinit();
        }
        if (self.old_syntax_spans.len > 0) {
            self.allocator.free(self.old_syntax_spans);
        }
        if (self.old_highlighter) |*hl| {
            hl.deinit();
        }
        // Clean up collapse regions
        self.freeCollapseRegions();
    }

    fn freeCollapseRegions(self: *UI) void {
        if (self.collapse_regions.len > 0) {
            collapse.freeRegions(self.allocator, @constCast(self.collapse_regions));
            self.collapse_regions = &.{};
        }
        if (self.old_collapse_regions.len > 0) {
            collapse.freeRegions(self.allocator, @constCast(self.old_collapse_regions));
            self.old_collapse_regions = &.{};
        }
    }

    fn freeSplitRows(self: *UI) void {
        for (self.split_rows.items) |row| {
            if (row.left) |left| {
                if (left.content.len > 0) self.allocator.free(left.content);
                if (left.changes.len > 0) {
                    for (left.changes) |change| {
                        if (change.content.len > 0) self.allocator.free(change.content);
                    }
                    self.allocator.free(left.changes);
                }
            }
            if (row.right) |right| {
                if (right.content.len > 0) self.allocator.free(right.content);
                if (right.changes.len > 0) {
                    for (right.changes) |change| {
                        if (change.content.len > 0) self.allocator.free(change.content);
                    }
                    self.allocator.free(right.changes);
                }
            }
        }
    }

    fn freeAskOriginalLines(self: *UI) void {
        // Free diff lines
        for (self.ask_original_diff_lines.items) |line| {
            if (line.content.len > 0) self.allocator.free(line.content);
            if (line.old_content) |oc| {
                if (oc.len > 0) self.allocator.free(oc);
            }
            if (line.changes.len > 0) {
                for (line.changes) |change| {
                    if (change.content.len > 0) self.allocator.free(change.content);
                }
                self.allocator.free(line.changes);
            }
            if (line.old_changes.len > 0) {
                for (line.old_changes) |change| {
                    if (change.content.len > 0) self.allocator.free(change.content);
                }
                self.allocator.free(line.old_changes);
            }
        }
        self.ask_original_diff_lines.clearRetainingCapacity();

        // Free split rows
        for (self.ask_original_split_rows.items) |row| {
            if (row.left) |left| {
                if (left.content.len > 0) self.allocator.free(left.content);
                if (left.changes.len > 0) {
                    for (left.changes) |change| {
                        if (change.content.len > 0) self.allocator.free(change.content);
                    }
                    self.allocator.free(left.changes);
                }
            }
            if (row.right) |right| {
                if (right.content.len > 0) self.allocator.free(right.content);
                if (right.changes.len > 0) {
                    for (right.changes) |change| {
                        if (change.content.len > 0) self.allocator.free(change.content);
                    }
                    self.allocator.free(right.changes);
                }
            }
        }
        self.ask_original_split_rows.clearRetainingCapacity();
    }

    /// Duplicate a changes array, allocating new memory for the array and content strings
    fn dupeChanges(self: *UI, changes: []const difft.Change) ![]const difft.Change {
        if (changes.len == 0) return &.{};

        const new_changes = try self.allocator.alloc(difft.Change, changes.len);
        for (changes, 0..) |change, i| {
            new_changes[i] = .{
                .start = change.start,
                .end = change.end,
                .content = try self.allocator.dupe(u8, change.content),
                .highlight = change.highlight,
            };
        }
        return new_changes;
    }

    pub fn buildDiffLines(self: *UI) !void {
        for (self.diff_lines.items) |line| {
            if (line.content.len > 0) self.allocator.free(line.content);
            if (line.old_content) |oc| {
                if (oc.len > 0) self.allocator.free(oc);
            }
            if (line.changes.len > 0) {
                for (line.changes) |change| {
                    if (change.content.len > 0) self.allocator.free(change.content);
                }
                self.allocator.free(line.changes);
            }
            if (line.old_changes.len > 0) {
                for (line.old_changes) |change| {
                    if (change.content.len > 0) self.allocator.free(change.content);
                }
                self.allocator.free(line.old_changes);
            }
        }
        self.diff_lines.clearRetainingCapacity();

        // Clean up split rows
        self.freeSplitRows();
        self.split_rows.clearRetainingCapacity();

        // Clean up old syntax highlighting
        if (self.syntax_spans.len > 0) {
            self.allocator.free(self.syntax_spans);
            self.syntax_spans = &.{};
        }
        if (self.highlighter) |*hl| {
            hl.deinit();
            self.highlighter = null;
        }
        if (self.old_syntax_spans.len > 0) {
            self.allocator.free(self.old_syntax_spans);
            self.old_syntax_spans = &.{};
        }
        if (self.old_highlighter) |*hl| {
            hl.deinit();
            self.old_highlighter = null;
        }

        const file = self.session.currentFile() orelse return;
        if (file.is_binary) return;

        // Initialize syntax highlighter for this file (new content)
        if (highlight.Language.fromPath(file.path)) |lang| {
            // Only highlight if new_content is not empty
            if (file.new_content.len > 0) {
                if (highlight.Highlighter.init(self.allocator, lang)) |hl| {
                    self.highlighter = hl;
                    // Highlight the new content (what we display for context lines)
                    if (self.highlighter.?.highlight(file.new_content)) |spans| {
                        self.syntax_spans = spans;
                    } else |_| {
                        // Highlighting failed, continue without it
                    }
                } else |_| {
                    // Language not supported or init failed
                }
            }

            // Also highlight old content for split view
            // Only highlight if old_content is not empty
            if (file.old_content.len > 0) {
                if (highlight.Highlighter.init(self.allocator, lang)) |hl| {
                    self.old_highlighter = hl;
                    if (self.old_highlighter.?.highlight(file.old_content)) |spans| {
                        self.old_syntax_spans = spans;
                    } else |_| {
                        // Highlighting failed, continue without it
                    }
                } else |_| {
                    // Language not supported or init failed
                }
            }

            // Detect collapsible regions for summary mode
            self.freeCollapseRegions();
            // Only detect regions if content is not empty
            if (file.new_content.len > 0) {
                if (collapse.CollapseDetector.init(self.allocator, lang)) |detector_val| {
                    var detector = detector_val;
                    defer detector.deinit();
                    if (detector.findRegions(file.new_content)) |regions| {
                        self.collapse_regions = regions;
                    } else |_| {
                        // Detection failed, continue without collapse
                    }
                } else |_| {
                    // Language not supported
                }
            }
            // Also detect for old content
            if (file.old_content.len > 0) {
                if (collapse.CollapseDetector.init(self.allocator, lang)) |old_detector_val| {
                    var old_detector = old_detector_val;
                    defer old_detector.deinit();
                    if (old_detector.findRegions(file.old_content)) |old_regions| {
                        self.old_collapse_regions = old_regions;
                    } else |_| {}
                } else |_| {}
            }
        }

        var old_lines: std.ArrayList([]const u8) = .empty;
        defer old_lines.deinit(self.allocator);
        var new_lines: std.ArrayList([]const u8) = .empty;
        defer new_lines.deinit(self.allocator);
        var new_line_offsets: std.ArrayList(u32) = .empty;
        defer new_line_offsets.deinit(self.allocator);
        var old_line_offsets: std.ArrayList(u32) = .empty;
        defer old_line_offsets.deinit(self.allocator);

        // Track byte offsets for each line in old content
        var old_byte_offset: u32 = 0;
        var old_iter = std.mem.splitScalar(u8, file.old_content, '\n');
        while (old_iter.next()) |line| {
            try old_lines.append(self.allocator, line);
            try old_line_offsets.append(self.allocator, old_byte_offset);
            old_byte_offset += @intCast(line.len + 1);
        }

        // Track byte offsets for each line in new content
        var byte_offset: u32 = 0;
        var new_iter = std.mem.splitScalar(u8, file.new_content, '\n');
        while (new_iter.next()) |line| {
            try new_lines.append(self.allocator, line);
            try new_line_offsets.append(self.allocator, byte_offset);
            byte_offset += @intCast(line.len + 1); // +1 for newline
        }

        if (file.diff.chunks.len == 0 and (file.diff.status == .removed or file.diff.status == .added or file.diff.status == .unchanged)) {
            if (file.diff.status == .removed) {
                for (old_lines.items, 0..) |line, idx| {
                    const line_num: u32 = @intCast(idx + 1);
                    const offset = if (idx < old_line_offsets.items.len) old_line_offsets.items[idx] else 0;
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = line_num,
                        .new_line_num = null,
                        .content = try self.allocator.dupe(u8, line),
                        .changes = &.{},
                        .line_type = .deletion,
                        .old_content_byte_offset = offset,
                    });
                    // Split view: deletion on left, empty on right
                    try self.split_rows.append(self.allocator, .{
                        .left = .{
                            .line_num = line_num,
                            .content = try self.allocator.dupe(u8, line),
                            .line_type = .deletion,
                            .content_byte_offset = offset,
                        },
                        .right = null,
                    });
                }
            } else if (file.diff.status == .added) {
                for (new_lines.items, 0..) |line, idx| {
                    const line_num: u32 = @intCast(idx + 1);
                    const offset = if (idx < new_line_offsets.items.len) new_line_offsets.items[idx] else 0;
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = null,
                        .new_line_num = line_num,
                        .content = try self.allocator.dupe(u8, line),
                        .changes = &.{},
                        .line_type = .addition,
                        .content_byte_offset = offset,
                    });
                    // Split view: empty on left, addition on right
                    try self.split_rows.append(self.allocator, .{
                        .left = null,
                        .right = .{
                            .line_num = line_num,
                            .content = try self.allocator.dupe(u8, line),
                            .line_type = .addition,
                            .content_byte_offset = offset,
                        },
                    });
                }
            } else if (file.diff.status == .unchanged) {
                // For unchanged files, show all lines as context
                for (new_lines.items, 0..) |line, idx| {
                    const line_num: u32 = @intCast(idx + 1);
                    const offset = if (idx < new_line_offsets.items.len) new_line_offsets.items[idx] else 0;
                    const old_offset = if (idx < old_line_offsets.items.len) old_line_offsets.items[idx] else 0;
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = line_num,
                        .new_line_num = line_num,
                        .content = try self.allocator.dupe(u8, line),
                        .changes = &.{},
                        .line_type = .context,
                        .content_byte_offset = offset,
                    });
                    // Split view: same content on both sides
                    try self.split_rows.append(self.allocator, .{
                        .left = .{
                            .line_num = line_num,
                            .content = try self.allocator.dupe(u8, line),
                            .line_type = .context,
                            .content_byte_offset = old_offset,
                        },
                        .right = .{
                            .line_num = line_num,
                            .content = try self.allocator.dupe(u8, line),
                            .line_type = .context,
                            .content_byte_offset = offset,
                        },
                    });
                }
            }
        }

        const CONTEXT_LINES: u32 = 3;
        var last_shown_old_line: u32 = 0;
        var last_shown_new_line: u32 = 0;
        // Track the offset between old and new line numbers
        // offset = new_line - old_line for corresponding lines
        // Positive offset means lines were added, negative means deleted
        var line_offset: i32 = 0;

        for (file.diff.chunks) |chunk| {
            // difft uses 0-based line numbers, we need 1-based for display
            // Track boundaries for both LHS (old) and RHS (new) separately
            var first_old_line_0based: u32 = std.math.maxInt(u32);
            var last_old_line_0based: u32 = 0;
            var first_new_line_0based: u32 = std.math.maxInt(u32);
            var last_new_line_0based: u32 = 0;
            var has_old_lines = false;
            var has_new_lines = false;

            for (chunk) |entry| {
                if (entry.lhs) |lhs| {
                    first_old_line_0based = @min(first_old_line_0based, lhs.line_number);
                    last_old_line_0based = @max(last_old_line_0based, lhs.line_number);
                    has_old_lines = true;
                }
                if (entry.rhs) |rhs| {
                    first_new_line_0based = @min(first_new_line_0based, rhs.line_number);
                    last_new_line_0based = @max(last_new_line_0based, rhs.line_number);
                    has_new_lines = true;
                }
            }

            // Convert to 1-based display line numbers
            const first_old_line = if (has_old_lines) first_old_line_0based + 1 else 0;
            const first_new_line = if (has_new_lines) first_new_line_0based + 1 else 0;
            const last_new_line = if (has_new_lines) last_new_line_0based + 1 else 0;

            // Calculate context boundaries based on new file (for unified view)
            const context_start_new = if (first_new_line > CONTEXT_LINES) first_new_line - CONTEXT_LINES else 1;
            const context_start_old = if (first_old_line > CONTEXT_LINES) first_old_line - CONTEXT_LINES else 1;

            // Show separator if there's a gap from the last shown content
            const effective_context_start = if (has_new_lines) context_start_new else context_start_old;
            const effective_last_shown = if (has_new_lines) last_shown_new_line else last_shown_old_line;
            if (effective_last_shown > 0 and effective_context_start > effective_last_shown + 1) {
                try self.diff_lines.append(self.allocator, .{
                    .old_line_num = null,
                    .new_line_num = null,
                    .content = try self.allocator.dupe(u8, "..."),
                    .changes = &.{},
                    .line_type = .context,
                    .selectable = false,
                });
            }

            // Show context lines before the chunk
            // For context lines, we need to compute the corresponding old line number
            // using the current offset between old and new line numbers
            if (has_new_lines and context_start_new < first_new_line) {
                for (context_start_new..first_new_line) |line_num_usize| {
                    const new_line_num: u32 = @intCast(line_num_usize);
                    if (new_line_num <= last_shown_new_line) continue; // Skip if already shown

                    // Compute old line number based on current offset
                    const old_line_num: u32 = if (line_offset >= 0)
                        new_line_num -| @as(u32, @intCast(line_offset))
                    else
                        new_line_num + @as(u32, @intCast(-line_offset));

                    const idx = new_line_num - 1;
                    const content = if (idx < new_lines.items.len) new_lines.items[idx] else "";
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = old_line_num,
                        .new_line_num = new_line_num,
                        .content = try self.allocator.dupe(u8, content),
                        .changes = &.{},
                        .line_type = .context,
                    });
                    last_shown_new_line = new_line_num;
                    last_shown_old_line = old_line_num;
                }
            }
            // Sort entries by line number to display in order
            // Use max of LHS and RHS line numbers to handle interleaving properly
            var sorted_entries: std.ArrayList(struct {
                const Self = @This();
                idx: usize,
                sort_key: u32,
                lhs_line: ?u32,
                rhs_line: ?u32,
            }) = .empty;
            defer sorted_entries.deinit(self.allocator);
            for (chunk, 0..) |entry, idx| {
                const lhs_line = if (entry.lhs) |lhs| lhs.line_number else null;
                const rhs_line = if (entry.rhs) |rhs| rhs.line_number else null;
                // Sort by the line number that exists, preferring RHS for unified view
                const sort_key = rhs_line orelse lhs_line orelse 0;
                try sorted_entries.append(self.allocator, .{
                    .idx = idx,
                    .sort_key = sort_key,
                    .lhs_line = lhs_line,
                    .rhs_line = rhs_line,
                });
            }
            std.mem.sort(@TypeOf(sorted_entries.items[0]), sorted_entries.items, {}, struct {
                fn lessThan(_: void, a: @TypeOf(sorted_entries.items[0]), b: @TypeOf(sorted_entries.items[0])) bool {
                    return a.sort_key < b.sort_key;
                }
            }.lessThan);

            // Track the last displayed lines for both old and new to fill in gaps
            var last_displayed_old_line: u32 = if (context_start_old > 1) context_start_old - 1 else 0;
            var last_displayed_new_line: u32 = if (context_start_new > 1) context_start_new - 1 else 0;

            for (sorted_entries.items) |entry_info| {
                const entry = chunk[entry_info.idx];
                const has_lhs = entry.lhs != null;
                const has_rhs = entry.rhs != null;

                // Get the current entry's new line number (1-based for display)
                const current_new_line: u32 = if (entry.rhs) |rhs| rhs.line_number + 1 else 0;

                // Fill in context lines between entries (using new file for unified view)
                // Only fill gaps in the new file lines since that's our primary view
                if (has_rhs and current_new_line > last_displayed_new_line + 1) {
                    const gap_start = last_displayed_new_line + 1;
                    const gap_end = current_new_line;
                    for (gap_start..gap_end) |line_num_usize| {
                        const new_line_num: u32 = @intCast(line_num_usize);
                        if (new_line_num <= last_shown_new_line) continue;

                        // Compute old line number based on current offset
                        const old_line_num: u32 = if (line_offset >= 0)
                            new_line_num -| @as(u32, @intCast(line_offset))
                        else
                            new_line_num + @as(u32, @intCast(-line_offset));

                        const idx = new_line_num - 1;
                        const content = if (idx < new_lines.items.len) new_lines.items[idx] else "";
                        try self.diff_lines.append(self.allocator, .{
                            .old_line_num = old_line_num,
                            .new_line_num = new_line_num,
                            .content = try self.allocator.dupe(u8, content),
                            .changes = &.{},
                            .line_type = .context,
                        });
                        last_shown_new_line = new_line_num;
                        last_shown_old_line = old_line_num;
                    }
                }

                if (has_lhs and has_rhs) {
                    // Both sides present - modified line
                    // Show deletion (old content) and addition (new content)
                    // Note: difft uses 0-based line numbering
                    const old_line_idx = entry.lhs.?.line_number;
                    const new_line_idx = entry.rhs.?.line_number;
                    const old_display_line_num = old_line_idx + 1;
                    const new_display_line_num = new_line_idx + 1;

                    const old_content = if (old_line_idx < old_lines.items.len) old_lines.items[old_line_idx] else "";
                    const new_content = if (new_line_idx < new_lines.items.len) new_lines.items[new_line_idx] else "";

                    // Skip if there's no actual change
                    if (std.mem.eql(u8, old_content, new_content)) {
                        last_shown_old_line = @max(last_shown_old_line, old_line_idx + 1);
                        last_shown_new_line = @max(last_shown_new_line, new_line_idx + 1);
                        last_displayed_old_line = old_display_line_num;
                        last_displayed_new_line = new_display_line_num;
                        continue;
                    }

                    // Use difftastic's semantic changes if available, otherwise compute our own
                    var deleted_changes: []const difft.Change = &.{};
                    var added_changes: []const difft.Change = &.{};
                    var is_partial_deletion = false;
                    var is_partial_addition = false;

                    if (entry.lhs.?.changes.len > 0) {
                        // Use difftastic's semantic highlighting - copy the changes array
                        deleted_changes = try self.dupeChanges(entry.lhs.?.changes);
                        // Check if the changes cover the whole line or just parts
                        is_partial_deletion = isPartialChange(old_content, entry.lhs.?.changes);
                    } else {
                        // Fallback: compute which parts were deleted
                        const deleted_range = computeDeletedRange(old_content, new_content);
                        if (deleted_range.start < deleted_range.end) {
                            const change_array = try self.allocator.alloc(difft.Change, 1);
                            change_array[0] = .{
                                .start = deleted_range.start,
                                .end = deleted_range.end,
                                .content = try self.allocator.dupe(u8, ""),
                                .highlight = .novel,
                            };
                            deleted_changes = change_array;
                            is_partial_deletion = deleted_range.start > 0 or deleted_range.end < old_content.len;
                        }
                    }

                    if (entry.rhs.?.changes.len > 0) {
                        // Use difftastic's semantic highlighting - copy the changes array
                        added_changes = try self.dupeChanges(entry.rhs.?.changes);
                        is_partial_addition = isPartialChange(new_content, entry.rhs.?.changes);
                    } else {
                        // Fallback: compute which parts were added
                        const added_range = computeAddedRange(old_content, new_content);
                        if (added_range.start < added_range.end) {
                            const change_array = try self.allocator.alloc(difft.Change, 1);
                            change_array[0] = .{
                                .start = added_range.start,
                                .end = added_range.end,
                                .content = try self.allocator.dupe(u8, ""),
                                .highlight = .novel,
                            };
                            added_changes = change_array;
                            is_partial_addition = added_range.start > 0 or added_range.end < new_content.len;
                        }
                    }

                    // Create a unified modification line showing both old and new content
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = old_display_line_num,
                        .new_line_num = new_display_line_num,
                        .content = try self.allocator.dupe(u8, new_content), // New content is primary
                        .old_content = try self.allocator.dupe(u8, old_content), // Old content for reference
                        .changes = added_changes, // Highlights for new content
                        .old_changes = deleted_changes, // Highlights for old content
                        .line_type = .modification,
                        .is_partial_change = is_partial_deletion or is_partial_addition,
                    });

                    // Track both old and new line numbers for context calculation
                    last_shown_old_line = @max(last_shown_old_line, old_line_idx + 1);
                    last_shown_new_line = @max(last_shown_new_line, new_line_idx + 1);
                    last_displayed_old_line = old_display_line_num;
                    last_displayed_new_line = new_display_line_num;
                    // Update offset: for modifications, offset changes if line numbers differ
                    line_offset = @as(i32, @intCast(new_display_line_num)) - @as(i32, @intCast(old_display_line_num));
                } else if (has_lhs and !has_rhs) {
                    // Deletion only - difft uses 0-based indexing
                    const old_line_idx = entry.lhs.?.line_number;
                    const display_line_num = old_line_idx + 1;
                    const content = if (old_line_idx < old_lines.items.len) old_lines.items[old_line_idx] else "";
                    // Copy the changes array to avoid double-free
                    const changes_copy = try self.dupeChanges(entry.lhs.?.changes);
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = display_line_num,
                        .new_line_num = null, // Deletion only: no new line
                        .content = try self.allocator.dupe(u8, content),
                        .changes = changes_copy,
                        .line_type = .deletion,
                    });
                    // Track old line for deletions
                    last_shown_old_line = @max(last_shown_old_line, display_line_num);
                    last_displayed_old_line = display_line_num;
                    // Deletion: old line removed, so offset decreases (new lines are "behind")
                    line_offset -= 1;
                } else if (!has_lhs and has_rhs) {
                    // Addition only - difft uses 0-based indexing
                    const new_line_idx = entry.rhs.?.line_number;
                    const display_line_num = new_line_idx + 1;
                    const content = if (new_line_idx < new_lines.items.len) new_lines.items[new_line_idx] else "";
                    // Copy the changes array to avoid double-free
                    const changes_copy = try self.dupeChanges(entry.rhs.?.changes);
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = null, // Addition only: no old line
                        .new_line_num = display_line_num,
                        .content = try self.allocator.dupe(u8, content),
                        .changes = changes_copy,
                        .line_type = .addition,
                    });
                    last_shown_new_line = display_line_num;
                    last_displayed_new_line = display_line_num;
                    // Addition: new line added, so offset increases
                    line_offset += 1;
                }
            }

            // Add trailing context lines after the chunk (use new file)
            const new_lines_count: u32 = @intCast(new_lines.items.len);
            const context_end_new = @min(last_new_line + CONTEXT_LINES, new_lines_count);
            if (has_new_lines and context_end_new > last_new_line) {
                for (last_new_line + 1..context_end_new + 1) |line_num_usize| {
                    const new_line_num: u32 = @intCast(line_num_usize);
                    if (new_line_num <= last_shown_new_line) continue; // Skip if already shown

                    // Compute old line number based on current offset
                    const old_line_num: u32 = if (line_offset >= 0)
                        new_line_num -| @as(u32, @intCast(line_offset))
                    else
                        new_line_num + @as(u32, @intCast(-line_offset));

                    const idx = new_line_num - 1;
                    const content = if (idx < new_lines.items.len) new_lines.items[idx] else "";
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = old_line_num,
                        .new_line_num = new_line_num,
                        .content = try self.allocator.dupe(u8, content),
                        .changes = &.{},
                        .line_type = .context,
                    });
                    last_shown_new_line = new_line_num;
                    last_shown_old_line = old_line_num;
                }
            }
        }

        // Build split rows from diff_lines for split view
        try self.buildSplitRowsFromDiffLines(old_line_offsets.items, new_line_offsets.items);
    }

    /// Build split rows from the diff_lines for side-by-side view
    /// This converts the unified diff representation into paired rows
    fn buildSplitRowsFromDiffLines(
        self: *UI,
        old_line_offsets: []const u32,
        new_line_offsets: []const u32,
    ) !void {
        // Skip if we already built split rows in the simple cases (added/deleted/unchanged files)
        if (self.split_rows.items.len > 0) return;

        var i: usize = 0;
        while (i < self.diff_lines.items.len) {
            const diff_line = self.diff_lines.items[i];

            switch (diff_line.line_type) {
                .context => {
                    // Context lines appear on both sides
                    const old_ln = diff_line.old_line_num orelse 0;
                    const new_ln = diff_line.new_line_num orelse 0;
                    const old_offset = if (old_ln > 0 and old_ln - 1 < old_line_offsets.len)
                        old_line_offsets[old_ln - 1]
                    else
                        0;
                    const new_offset = if (new_ln > 0 and new_ln - 1 < new_line_offsets.len)
                        new_line_offsets[new_ln - 1]
                    else
                        0;
                    // For context lines, content is the same on both sides
                    const content = diff_line.content;

                    try self.split_rows.append(self.allocator, .{
                        .left = if (old_ln > 0) .{
                            .line_num = old_ln,
                            .content = try self.allocator.dupe(u8, content),
                            .line_type = .context,
                            .content_byte_offset = old_offset,
                        } else null,
                        .right = if (new_ln > 0) .{
                            .line_num = new_ln,
                            .content = try self.allocator.dupe(u8, content),
                            .line_type = .context,
                            .content_byte_offset = new_offset,
                        } else null,
                        .selectable = diff_line.selectable,
                    });
                    i += 1;
                },
                .modification => {
                    // Modification: old on left, new on right (same row)
                    const old_ln = diff_line.old_line_num orelse 0;
                    const new_ln = diff_line.new_line_num orelse 0;
                    const old_offset = if (old_ln > 0 and old_ln - 1 < old_line_offsets.len)
                        old_line_offsets[old_ln - 1]
                    else
                        0;
                    const new_offset = if (new_ln > 0 and new_ln - 1 < new_line_offsets.len)
                        new_line_offsets[new_ln - 1]
                    else
                        0;

                    try self.split_rows.append(self.allocator, .{
                        .left = if (diff_line.old_content) |oc| .{
                            .line_num = old_ln,
                            .content = try self.allocator.dupe(u8, oc),
                            .changes = try self.dupeChanges(diff_line.old_changes),
                            .line_type = .deletion,
                            .content_byte_offset = old_offset,
                        } else null,
                        .right = .{
                            .line_num = new_ln,
                            .content = try self.allocator.dupe(u8, diff_line.content),
                            .changes = try self.dupeChanges(diff_line.changes),
                            .line_type = .addition,
                            .content_byte_offset = new_offset,
                        },
                    });
                    i += 1;
                },
                .deletion => {
                    // Pure deletion: only on left side
                    // Look ahead to see if next line is an addition (can pair them)
                    const old_ln = diff_line.old_line_num orelse 0;
                    const old_offset = if (old_ln > 0 and old_ln - 1 < old_line_offsets.len)
                        old_line_offsets[old_ln - 1]
                    else
                        0;

                    // Check if we should pair with following addition
                    if (i + 1 < self.diff_lines.items.len and
                        self.diff_lines.items[i + 1].line_type == .addition)
                    {
                        const next = self.diff_lines.items[i + 1];
                        const new_ln = next.new_line_num orelse 0;
                        const new_offset = if (new_ln > 0 and new_ln - 1 < new_line_offsets.len)
                            new_line_offsets[new_ln - 1]
                        else
                            0;

                        try self.split_rows.append(self.allocator, .{
                            .left = .{
                                .line_num = old_ln,
                                .content = try self.allocator.dupe(u8, diff_line.content),
                                .changes = try self.dupeChanges(diff_line.changes),
                                .line_type = .deletion,
                                .content_byte_offset = old_offset,
                            },
                            .right = .{
                                .line_num = new_ln,
                                .content = try self.allocator.dupe(u8, next.content),
                                .changes = try self.dupeChanges(next.changes),
                                .line_type = .addition,
                                .content_byte_offset = new_offset,
                            },
                        });
                        i += 2; // Skip both
                    } else {
                        // Standalone deletion
                        try self.split_rows.append(self.allocator, .{
                            .left = .{
                                .line_num = old_ln,
                                .content = try self.allocator.dupe(u8, diff_line.content),
                                .changes = try self.dupeChanges(diff_line.changes),
                                .line_type = .deletion,
                                .content_byte_offset = old_offset,
                            },
                            .right = null,
                        });
                        i += 1;
                    }
                },
                .addition => {
                    // Pure addition: only on right side
                    const new_ln = diff_line.new_line_num orelse 0;
                    const new_offset = if (new_ln > 0 and new_ln - 1 < new_line_offsets.len)
                        new_line_offsets[new_ln - 1]
                    else
                        0;

                    try self.split_rows.append(self.allocator, .{
                        .left = null,
                        .right = .{
                            .line_num = new_ln,
                            .content = try self.allocator.dupe(u8, diff_line.content),
                            .changes = try self.dupeChanges(diff_line.changes),
                            .line_type = .addition,
                            .content_byte_offset = new_offset,
                        },
                    });
                    i += 1;
                },
            }
        }
    }

    /// Returns a vxfw.Widget struct for this model
    pub fn widget(self: *UI) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *UI = @ptrCast(@alignCast(ptr));
        try self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *UI = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn handleEvent(self: *UI, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        switch (event) {
            .init => {
                try self.buildDiffLines();
                return ctx.consumeAndRedraw();
            },
            .key_press => |key| {
                try self.handleKeyPress(ctx, key);
            },
            .tick => {
                // Update spinner while ask is in progress (non-blocking)
                if (self.ask_in_progress) {
                    self.spinner_frame +%= 1;

                    // Check if request completed
                    if (self.ask_thread_done.load(.acquire)) {
                        try self.handleAskComplete();
                    } else {
                        // Schedule next tick to keep animation going
                        try ctx.tick(80, self.widget());
                    }
                    // Request redraw to show updated spinner/result
                    ctx.redraw = true;
                }
            },
            else => {},
        }
    }

    pub fn handleKeyPress(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        switch (self.mode) {
            .normal => try self.handleNormalKey(ctx, key),
            .comment_input => try self.handleCommentInputKey(ctx, key),
            .ask_input => try self.handleAskInputKey(ctx, key),
            .ask_response => self.handleAskResponseKey(ctx, key),
            .ask_response_comment => try self.handleAskResponseCommentKey(ctx, key),
            .help => self.handleHelpKey(ctx, key),
            .file_list => try self.handleFileListKey(ctx, key),
        }
    }

    fn handleNormalKey(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches('c', .{ .ctrl = true })) {
            ctx.quit = true;
            return;
        }

        const cp = key.codepoint;

        if (cp == vaxis.Key.up) {
            if (key.mods.shift) {
                // Shift+Up: start/extend selection upward
                if (self.selection_start == null) {
                    self.selection_start = self.cursor_line;
                }
                self.moveCursorUp();
            } else {
                // Plain Up: move cursor, clear selection
                self.selection_start = null;
                self.moveCursorUp();
            }
            return ctx.consumeAndRedraw();
        } else if (cp == vaxis.Key.down) {
            if (key.mods.shift) {
                // Shift+Down: start/extend selection downward
                if (self.selection_start == null) {
                    self.selection_start = self.cursor_line;
                }
                self.moveCursorDown();
            } else {
                // Plain Down: move cursor, clear selection
                self.selection_start = null;
                self.moveCursorDown();
            }
            return ctx.consumeAndRedraw();
        } else if (cp == vaxis.Key.left) {
            self.session.prevFile();
            self.resetView();
            try self.buildDiffLines();
            return ctx.consumeAndRedraw();
        } else if (cp == vaxis.Key.right) {
            self.session.nextFile();
            self.resetView();
            try self.buildDiffLines();
            return ctx.consumeAndRedraw();
        } else if (cp == vaxis.Key.page_up) {
            if (key.mods.shift) {
                if (self.selection_start == null) {
                    self.selection_start = self.cursor_line;
                }
            } else {
                self.selection_start = null;
            }
            self.pageUp();
            return ctx.consumeAndRedraw();
        } else if (cp == vaxis.Key.page_down) {
            if (key.mods.shift) {
                if (self.selection_start == null) {
                    self.selection_start = self.cursor_line;
                }
            } else {
                self.selection_start = null;
            }
            self.pageDown();
            return ctx.consumeAndRedraw();
        } else if (cp == vaxis.Key.escape) {
            self.selection_start = null;
            self.clearMessage();
            return ctx.consumeAndRedraw();
        }

        switch (cp) {
            'q' => {
                self.should_quit = true;
                ctx.quit = true;
            },
            'f' => {
                if (key.mods.shift) {
                    if (self.selection_start == null) {
                        self.selection_start = self.cursor_line;
                    }
                } else {
                    self.selection_start = null;
                }
                self.pageDown();
                return ctx.consumeAndRedraw();
            },
            'p' => {
                if (key.mods.shift) {
                    if (self.selection_start == null) {
                        self.selection_start = self.cursor_line;
                    }
                } else {
                    self.selection_start = null;
                }
                self.pageUp();
                return ctx.consumeAndRedraw();
            },
            'l', '.' => {
                self.file_list_cursor = self.session.current_file_idx;
                self.mode = .file_list;
                return ctx.consumeAndRedraw();
            },
            'c' => {
                self.mode = .comment_input;
                self.input_buffer.clear();
                return ctx.consumeAndRedraw();
            },
            'a' => {
                self.mode = .ask_input;
                self.input_buffer.clear();
                // Store context for the question
                if (self.session.currentFile()) |file| {
                    self.ask_context_file = file.path;
                }
                const line_start: u32 = @intCast(self.getLineNumber() orelse 1);
                const line_end: u32 = if (self.selection_start) |sel|
                    @intCast(self.getLineNumberAt(sel) orelse line_start)
                else
                    line_start;
                self.ask_context_lines = .{
                    .start = @min(line_start, line_end),
                    .end = @max(line_start, line_end),
                };
                return ctx.consumeAndRedraw();
            },
            ' ' => {
                self.toggleSelection();
                return ctx.consumeAndRedraw();
            },
            'v' => {
                // Toggle between unified and split view
                self.view_mode = if (self.view_mode == .unified) .split else .unified;
                self.setMessage(if (self.view_mode == .split) "Split view" else "Unified view", false);
                return ctx.consumeAndRedraw();
            },
            '\t' => {
                // Toggle focus side (for commenting)
                self.focus_side = if (self.focus_side == .new) .old else .new;
                self.setMessage(if (self.focus_side == .new) "Focus: NEW (right)" else "Focus: OLD (left)", false);
                return ctx.consumeAndRedraw();
            },
            '/' => {
                if (key.mods.shift) {
                    self.mode = .help;
                    return ctx.consumeAndRedraw();
                }
            },
            '?' => {
                self.mode = .help;
                return ctx.consumeAndRedraw();
            },
            'g' => {
                self.goToTop();
                return ctx.consumeAndRedraw();
            },
            'G' => {
                self.goToBottom();
                return ctx.consumeAndRedraw();
            },
            's' => {
                // Toggle summary mode (collapse/expand all)
                self.summary_mode = !self.summary_mode;
                // Update all regions' collapsed state
                for (self.collapse_regions) |*region| {
                    region.collapsed = self.summary_mode;
                }
                for (self.old_collapse_regions) |*region| {
                    region.collapsed = self.summary_mode;
                }
                // Adjust cursor if it's now on a hidden line
                self.adjustCursorAfterCollapse();
                self.setMessage(if (self.summary_mode) "Summary mode (collapsed)" else "Expanded view", false);
                return ctx.consumeAndRedraw();
            },
            vaxis.Key.enter => {
                // Toggle expand/collapse for region at cursor
                if (self.toggleRegionAtCursor()) {
                    // Adjust cursor if it's now on a hidden line
                    self.adjustCursorAfterCollapse();
                    return ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    fn handleCommentInputKey(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const cp = key.codepoint;

        if (cp == vaxis.Key.escape) {
            self.mode = .normal;
            self.input_buffer.clear();
            self.clearMessage();
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.enter) {
            if (self.input_buffer.len > 0) {
                try self.submitComment();
            }
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.backspace) {
            self.input_buffer.backspace();
            return ctx.consumeAndRedraw();
        }

        if (cp >= 32 and cp < 127) {
            self.input_buffer.append(@intCast(cp));
            return ctx.consumeAndRedraw();
        }
    }

    fn handleAskInputKey(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const cp = key.codepoint;

        if (cp == vaxis.Key.escape) {
            self.mode = .normal;
            self.input_buffer.clear();
            self.clearMessage();
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.enter) {
            if (self.input_buffer.len > 0) {
                // Store the original question
                if (self.ask_original_question) |old| {
                    self.allocator.free(old);
                }
                self.ask_original_question = self.allocator.dupe(u8, self.input_buffer.slice()) catch null;

                // Start the ask request (non-blocking)
                self.spinner_frame = 0;
                try self.startAskRequest();

                // Return to normal mode - user can continue navigating
                self.mode = .normal;
                self.input_buffer.clear();
                self.setMessage("Asking Pi...", false);

                // Start the spinner tick
                try ctx.tick(1, self.widget());
            }
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.backspace) {
            self.input_buffer.backspace();
            return ctx.consumeAndRedraw();
        }

        if (cp >= 32 and cp < 127) {
            self.input_buffer.append(@intCast(cp));
            return ctx.consumeAndRedraw();
        }
    }

    fn handleAskResponseKey(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        const cp = key.codepoint;

        if (cp == vaxis.Key.escape or cp == 'q') {
            self.mode = .normal;
            self.ask_scroll_offset = 0;
            return ctx.consumeAndRedraw();
        }

        if (cp == 'c') {
            // Add comment on the original code from response view
            if (self.ask_original_file != null and self.ask_context_lines != null) {
                self.mode = .ask_response_comment;
                self.input_buffer.clear();
                return ctx.consumeAndRedraw();
            } else {
                self.setMessage("No code context available for comment", true);
                return ctx.consumeAndRedraw();
            }
        }

        if (cp == vaxis.Key.up) {
            if (self.ask_scroll_offset > 0) {
                self.ask_scroll_offset -= 1;
            }
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.down) {
            self.ask_scroll_offset += 1;
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.page_up) {
            if (self.ask_scroll_offset >= 20) {
                self.ask_scroll_offset -= 20;
            } else {
                self.ask_scroll_offset = 0;
            }
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.page_down) {
            self.ask_scroll_offset += 20;
            return ctx.consumeAndRedraw();
        }
    }

    fn handleAskResponseCommentKey(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const cp = key.codepoint;

        if (cp == vaxis.Key.escape) {
            // Cancel and go back to response view
            self.mode = .ask_response;
            self.input_buffer.clear();
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.enter) {
            if (self.input_buffer.slice().len > 0) {
                try self.submitResponseComment();
            }
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.backspace) {
            self.input_buffer.backspace();
            return ctx.consumeAndRedraw();
        }

        // Regular character input
        if (cp >= 32 and cp < 127) {
            self.input_buffer.append(@intCast(cp));
            return ctx.consumeAndRedraw();
        }
    }

    fn submitResponseComment(self: *UI) !void {
        const file_path = self.ask_original_file orelse {
            self.mode = .ask_response;
            return;
        };

        const lines = self.ask_context_lines orelse {
            self.mode = .ask_response;
            return;
        };

        const comment = review.Comment{
            .file_path = try self.allocator.dupe(u8, file_path),
            .side = self.focus_side,
            .line_start = lines.start,
            .line_end = lines.end,
            .text = try self.allocator.dupe(u8, self.input_buffer.slice()),
            .allocator = self.allocator,
        };

        try self.session.addComment(comment);

        self.input_buffer.clear();
        self.mode = .ask_response;
        self.setMessage("Comment added", false);
    }

    fn handleHelpKey(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        const cp = key.codepoint;

        if (cp == vaxis.Key.escape or cp == '?' or cp == 'q') {
            self.mode = .normal;
            return ctx.consumeAndRedraw();
        }
    }

    fn handleFileListKey(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        const cp = key.codepoint;

        if (cp == vaxis.Key.escape or cp == 'l' or cp == '.') {
            self.mode = .normal;
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.up) {
            if (self.file_list_cursor > 0) {
                self.file_list_cursor -= 1;
            }
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.down) {
            if (self.file_list_cursor + 1 < self.session.files.len) {
                self.file_list_cursor += 1;
            }
            return ctx.consumeAndRedraw();
        }

        if (cp == vaxis.Key.enter) {
            self.session.goToFile(self.file_list_cursor);
            self.resetView();
            try self.buildDiffLines();
            self.mode = .normal;
            return ctx.consumeAndRedraw();
        }

        if (cp >= '1' and cp <= '9') {
            const idx = cp - '1';
            if (idx < self.session.files.len) {
                self.session.goToFile(idx);
                self.resetView();
                try self.buildDiffLines();
                self.mode = .normal;
                return ctx.consumeAndRedraw();
            }
        }
    }

    fn submitComment(self: *UI) !void {
        const file = self.session.currentFile() orelse {
            self.mode = .normal;
            return;
        };

        const line_start: u32 = @intCast(self.getLineNumber() orelse 1);
        const line_end: u32 = if (self.selection_start) |sel|
            @intCast(self.getLineNumberAt(sel) orelse line_start)
        else
            line_start;

        const comment = review.Comment{
            .file_path = try self.allocator.dupe(u8, file.path),
            .side = self.focus_side,
            .line_start = @min(line_start, line_end),
            .line_end = @max(line_start, line_end),
            .text = try self.allocator.dupe(u8, self.input_buffer.slice()),
            .allocator = self.allocator,
        };

        try self.session.addComment(comment);

        self.input_buffer.clear();
        self.selection_start = null;
        self.mode = .normal;
        self.setMessage("Comment added", false);
    }

    fn startAskRequest(self: *UI) !void {
        // Build the context message for Pi
        const file_path = self.ask_context_file orelse "unknown";
        const lines_start = if (self.ask_context_lines) |l| l.start else 1;
        const lines_end = if (self.ask_context_lines) |l| l.end else 1;
        const question = self.input_buffer.slice();

        // Store the original file path
        if (self.ask_original_file) |old| {
            self.allocator.free(old);
        }
        self.ask_original_file = self.allocator.dupe(u8, file_path) catch null;

        // Clear and store the original diff lines and split rows for the selected range
        self.freeAskOriginalLines();

        // Get the selected code content and store the diff lines
        var code_content: std.ArrayList(u8) = .empty;
        defer code_content.deinit(self.allocator);

        for (self.diff_lines.items) |diff_line| {
            // Use new_line_num for additions/context, old_line_num for deletions
            const line_num = diff_line.new_line_num orelse diff_line.old_line_num;
            if (line_num) |num| {
                if (num >= lines_start and num <= lines_end) {
                    // Store a copy of this diff line
                    try self.ask_original_diff_lines.append(self.allocator, .{
                        .old_line_num = diff_line.old_line_num,
                        .new_line_num = diff_line.new_line_num,
                        .content = try self.allocator.dupe(u8, diff_line.content),
                        .old_content = if (diff_line.old_content) |oc| try self.allocator.dupe(u8, oc) else null,
                        .changes = try self.dupeChanges(diff_line.changes),
                        .old_changes = try self.dupeChanges(diff_line.old_changes),
                        .line_type = diff_line.line_type,
                        .selectable = diff_line.selectable,
                        .is_partial_change = diff_line.is_partial_change,
                        .content_byte_offset = diff_line.content_byte_offset,
                        .old_content_byte_offset = diff_line.old_content_byte_offset,
                    });

                    const prefix: u8 = switch (diff_line.line_type) {
                        .addition => '+',
                        .deletion => '-',
                        .modification => '~',
                        .context => ' ',
                    };
                    try code_content.append(self.allocator, prefix);
                    try code_content.append(self.allocator, ' ');
                    // For modifications, show both old and new content
                    if (diff_line.line_type == .modification) {
                        if (diff_line.old_content) |old| {
                            try code_content.appendSlice(self.allocator, old);
                            try code_content.appendSlice(self.allocator, " → ");
                        }
                    }
                    try code_content.appendSlice(self.allocator, diff_line.content);
                    try code_content.append(self.allocator, '\n');
                }
            }
        }

        // Store split rows for the selected range
        for (self.split_rows.items) |split_row| {
            const left_num = if (split_row.left) |l| l.line_num else 0;
            const right_num = if (split_row.right) |r| r.line_num else 0;
            const row_num = if (right_num > 0) right_num else left_num;

            if (row_num >= lines_start and row_num <= lines_end) {
                try self.ask_original_split_rows.append(self.allocator, .{
                    .left = if (split_row.left) |l| .{
                        .line_num = l.line_num,
                        .content = try self.allocator.dupe(u8, l.content),
                        .changes = try self.dupeChanges(l.changes),
                        .line_type = l.line_type,
                        .content_byte_offset = l.content_byte_offset,
                    } else null,
                    .right = if (split_row.right) |r| .{
                        .line_num = r.line_num,
                        .content = try self.allocator.dupe(u8, r.content),
                        .changes = try self.dupeChanges(r.changes),
                        .line_type = r.line_type,
                        .content_byte_offset = r.content_byte_offset,
                    } else null,
                    .selectable = split_row.selectable,
                    .is_separator = split_row.is_separator,
                });
            }
        }

        // Store the original code for display in response view
        if (self.ask_original_code) |old| {
            self.allocator.free(old);
        }
        self.ask_original_code = self.allocator.dupe(u8, code_content.items) catch null;

        // Build the full prompt with context
        const line_range = if (lines_start == lines_end)
            try std.fmt.allocPrint(self.allocator, "line {d}", .{lines_start})
        else
            try std.fmt.allocPrint(self.allocator, "lines {d}-{d}", .{ lines_start, lines_end });
        defer self.allocator.free(line_range);

        const project_info = if (self.project_path) |p| p else ".";

        const prompt = try std.fmt.allocPrint(self.allocator,
            \\Context: Code review in project "{s}"
            \\File: {s}
            \\Selected {s}:
            \\```
            \\{s}```
            \\
            \\Question: {s}
            \\
            \\Please provide a concise response.
        , .{ project_info, file_path, line_range, code_content.items, question });

        // Store prompt for thread (don't defer free - thread will use it)
        if (self.ask_pending_prompt) |old| {
            self.allocator.free(old);
        }
        self.ask_pending_prompt = prompt;

        // Reset thread state and mark as in progress
        self.ask_thread_done.store(false, .release);
        self.ask_thread_result = null;
        self.ask_thread_error = null;
        self.spinner_frame = 0;
        self.ask_in_progress = true;

        // Spawn thread to do the RPC call
        self.ask_thread = std.Thread.spawn(.{}, askThreadFn, .{self}) catch {
            self.ask_in_progress = false;
            self.setMessage("Failed to start ask thread", true);
            return;
        };
    }

    fn askThreadFn(self: *UI) void {
        const prompt = self.ask_pending_prompt orelse {
            self.ask_thread_error = self.allocator.dupe(u8, "No prompt available") catch null;
            self.ask_thread_done.store(true, .release);
            return;
        };

        const response = pi.askPi(self.allocator, self.io, prompt, self.pi_bin) catch |err| {
            self.ask_thread_error = std.fmt.allocPrint(self.allocator, "RPC error: {}", .{err}) catch null;
            self.ask_thread_done.store(true, .release);
            return;
        };

        self.ask_thread_result = response;
        self.ask_thread_done.store(true, .release);
    }

    /// Handle completion of the async ask request
    fn handleAskComplete(self: *UI) !void {
        // Thread completed, get result
        if (self.ask_thread) |thread| {
            thread.join();
            self.ask_thread = null;
        }

        if (self.ask_thread_error) |err| {
            if (self.ask_response) |old| {
                self.allocator.free(old);
            }
            self.ask_response = err;
            self.ask_thread_error = null;
        } else if (self.ask_thread_result) |result| {
            if (self.ask_response) |old| {
                self.allocator.free(old);
            }
            self.ask_response = result;
            self.ask_thread_result = null;
        }

        if (self.ask_pending_prompt) |prompt| {
            self.allocator.free(prompt);
            self.ask_pending_prompt = null;
        }
        self.ask_thread_done.store(false, .release);
        self.ask_in_progress = false;

        // Switch to response view
        self.ask_scroll_offset = 0;
        self.mode = .ask_response;
        self.clearMessage();
    }

    fn getLineNumber(self: *UI) ?usize {
        return self.getLineNumberAt(self.cursor_line);
    }

    fn getLineNumberAt(self: *UI, idx: usize) ?usize {
        if (self.view_mode == .split) {
            if (idx >= self.split_rows.items.len) return null;
            const row = self.split_rows.items[idx];
            // Return line number based on focus side
            if (self.focus_side == .new) {
                return if (row.right) |r| r.line_num else if (row.left) |l| l.line_num else null;
            } else {
                return if (row.left) |l| l.line_num else if (row.right) |r| r.line_num else null;
            }
        } else {
            if (idx >= self.diff_lines.items.len) return null;
            const line = self.diff_lines.items[idx];
            // Prefer new line number, fall back to old line number
            return if (line.new_line_num) |n| n else if (line.old_line_num) |n| n else null;
        }
    }

    fn getRowCount(self: *UI) usize {
        return if (self.view_mode == .split) self.split_rows.items.len else self.diff_lines.items.len;
    }

    fn isRowSelectable(self: *UI, idx: usize) bool {
        if (self.view_mode == .split) {
            if (idx >= self.split_rows.items.len) return false;
            return self.split_rows.items[idx].selectable;
        } else {
            if (idx >= self.diff_lines.items.len) return false;
            return self.diff_lines.items[idx].selectable;
        }
    }

    /// Check if a row is visible (not hidden by collapse)
    fn isRowVisible(self: *UI, idx: usize) bool {
        if (!self.summary_mode) return true; // All rows visible when not in summary mode

        if (self.view_mode == .split) {
            if (idx >= self.split_rows.items.len) return false;
            const row = self.split_rows.items[idx];
            // Check if either side's line is hidden
            if (row.left) |l| {
                if (collapse.isLineHidden(self.old_collapse_regions, l.line_num)) return false;
            }
            if (row.right) |r| {
                if (collapse.isLineHidden(self.collapse_regions, r.line_num)) return false;
            }
            return true;
        } else {
            if (idx >= self.diff_lines.items.len) return false;
            const line = self.diff_lines.items[idx];
            // Check new file regions for additions/modifications/context
            if (line.new_line_num) |ln| {
                if (collapse.isLineHidden(self.collapse_regions, ln)) return false;
            }
            // Check old file regions for deletions
            if (line.line_type == .deletion) {
                if (line.old_line_num) |ln| {
                    if (collapse.isLineHidden(self.old_collapse_regions, ln)) return false;
                }
            }
            return true;
        }
    }

    /// Check if a row can be navigated to (selectable AND visible)
    fn isRowNavigable(self: *UI, idx: usize) bool {
        return self.isRowSelectable(idx) and self.isRowVisible(idx);
    }

    fn moveCursorDown(self: *UI) void {
        const row_count = self.getRowCount();
        if (self.cursor_line + 1 < row_count) {
            self.cursor_line += 1;
            // Skip non-navigable rows (non-selectable or collapsed)
            while (self.cursor_line < row_count and !self.isRowNavigable(self.cursor_line)) {
                self.cursor_line += 1;
            }
            if (self.cursor_line >= row_count) {
                self.cursor_line -= 1;
                while (self.cursor_line > 0 and !self.isRowNavigable(self.cursor_line)) {
                    self.cursor_line -= 1;
                }
            }
        }
    }

    fn moveCursorUp(self: *UI) void {
        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            // Skip non-navigable rows (non-selectable or collapsed)
            while (self.cursor_line > 0 and !self.isRowNavigable(self.cursor_line)) {
                self.cursor_line -= 1;
            }
            if (!self.isRowNavigable(self.cursor_line)) {
                const row_count = self.getRowCount();
                while (self.cursor_line < row_count and !self.isRowNavigable(self.cursor_line)) {
                    self.cursor_line += 1;
                }
            }
        }
    }

    fn pageDown(self: *UI) void {
        const page_size: usize = 20;
        const row_count = self.getRowCount();
        self.cursor_line = @min(self.cursor_line + page_size, if (row_count > 0) row_count - 1 else 0);
        while (self.cursor_line < row_count and !self.isRowNavigable(self.cursor_line)) {
            self.cursor_line += 1;
        }
        // If we went past the end, go back to find a navigable row
        if (self.cursor_line >= row_count and row_count > 0) {
            self.cursor_line = row_count - 1;
            while (self.cursor_line > 0 and !self.isRowNavigable(self.cursor_line)) {
                self.cursor_line -= 1;
            }
        }
    }

    fn pageUp(self: *UI) void {
        const page_size: usize = 20;
        if (self.cursor_line >= page_size) {
            self.cursor_line -= page_size;
        } else {
            self.cursor_line = 0;
        }
        while (self.cursor_line > 0 and !self.isRowNavigable(self.cursor_line)) {
            self.cursor_line -= 1;
        }
        // If first row isn't navigable, find next navigable row
        if (!self.isRowNavigable(self.cursor_line)) {
            const row_count = self.getRowCount();
            while (self.cursor_line < row_count and !self.isRowNavigable(self.cursor_line)) {
                self.cursor_line += 1;
            }
        }
    }

    fn goToTop(self: *UI) void {
        self.cursor_line = 0;
        self.scroll_offset = 0;
        const row_count = self.getRowCount();
        while (self.cursor_line < row_count and !self.isRowNavigable(self.cursor_line)) {
            self.cursor_line += 1;
        }
    }

    fn goToBottom(self: *UI) void {
        const row_count = self.getRowCount();
        if (row_count > 0) {
            self.cursor_line = row_count - 1;
            while (self.cursor_line > 0 and !self.isRowNavigable(self.cursor_line)) {
                self.cursor_line -= 1;
            }
        }
    }

    fn toggleSelection(self: *UI) void {
        if (self.selection_start) |_| {
            self.selection_start = null;
        } else {
            self.selection_start = self.cursor_line;
        }
    }

    fn resetView(self: *UI) void {
        self.cursor_line = 0;
        self.scroll_offset = 0;
        self.selection_start = null;
    }

    /// Adjust cursor position after collapse state changes
    /// If cursor is on a hidden line, move it to the nearest visible line
    fn adjustCursorAfterCollapse(self: *UI) void {
        if (!self.isRowVisible(self.cursor_line)) {
            // Find the nearest visible line (prefer going up to the header)
            var found = false;

            // First try going up (to find the header of the collapsed region)
            var up_idx = self.cursor_line;
            while (up_idx > 0) {
                up_idx -= 1;
                if (self.isRowNavigable(up_idx)) {
                    self.cursor_line = up_idx;
                    found = true;
                    break;
                }
            }

            // If not found going up, try going down
            if (!found) {
                const row_count = self.getRowCount();
                var down_idx = self.cursor_line;
                while (down_idx + 1 < row_count) {
                    down_idx += 1;
                    if (self.isRowNavigable(down_idx)) {
                        self.cursor_line = down_idx;
                        found = true;
                        break;
                    }
                }
            }

            // If still not found, go to top
            if (!found) {
                self.cursor_line = 0;
            }
        }

        // Also clear selection if it includes hidden lines
        if (self.selection_start) |sel| {
            if (!self.isRowVisible(sel)) {
                self.selection_start = null;
            }
        }
    }

    /// Toggle collapse state for the region at the current cursor position
    fn toggleRegionAtCursor(self: *UI) bool {
        const line_num = self.getLineNumber() orelse return false;
        const line_u32: u32 = @intCast(line_num);

        // Check new file regions first (for right side / additions)
        if (collapse.findRegionWithHeaderAt(@constCast(self.collapse_regions), line_u32)) |region| {
            region.collapsed = !region.collapsed;
            return true;
        }

        // Check old file regions (for left side / deletions)
        if (collapse.findRegionWithHeaderAt(@constCast(self.old_collapse_regions), line_u32)) |region| {
            region.collapsed = !region.collapsed;
            return true;
        }

        return false;
    }

    /// Check if a line should be shown based on collapse state
    fn isLineVisible(self: *UI, line_num: u32, is_old_file: bool) bool {
        if (!self.summary_mode) return true; // All lines visible when not in summary mode

        const regions = if (is_old_file) self.old_collapse_regions else self.collapse_regions;
        return !collapse.isLineHidden(regions, line_num);
    }

    /// Get the collapse indicator for a line (if it's a header line)
    fn getCollapseIndicator(self: *UI, line_num: u32, is_old_file: bool) ?[]const u8 {
        const regions = if (is_old_file) self.old_collapse_regions else self.collapse_regions;

        // Find the innermost (highest level) region with header at this line
        var best_region: ?*const collapse.CollapsibleRegion = null;
        for (regions) |*region| {
            if (region.isHeaderLine(line_num) and region.isCollapsible()) {
                if (best_region == null or region.level > best_region.?.level) {
                    best_region = region;
                }
            }
        }

        if (best_region) |region| {
            // Use different indicators for different levels
            return switch (region.level) {
                1 => if (region.collapsed) "▶" else "▼",
                2 => if (region.collapsed) "›" else "⌄",
                else => if (region.collapsed) "·" else "˅", // Level 3+
            };
        }
        return null;
    }

    /// Get the collapsed region info for display (e.g., "... 15 lines ...")
    fn getCollapsedInfo(self: *UI, line_num: u32, is_old_file: bool) ?struct { lines: u32, name: []const u8, node_type: collapse.NodeType } {
        const regions = if (is_old_file) self.old_collapse_regions else self.collapse_regions;

        for (regions) |region| {
            // Return info when we're at the header end line of a collapsed region
            if (region.collapsed and region.header_end_line == line_num and region.isCollapsible()) {
                return .{
                    .lines = region.bodyLineCount(),
                    .name = region.name,
                    .node_type = region.node_type,
                };
            }
        }
        return null;
    }

    /// Build a list of visible diff line indices, respecting collapse state
    fn buildVisibleIndices(self: *UI, indices: *std.ArrayList(usize)) !void {
        for (self.diff_lines.items, 0..) |diff_line, idx| {
            // Get the line number to check visibility
            const new_line = diff_line.new_line_num;
            const old_line = diff_line.old_line_num;

            // Check if this line should be hidden due to collapse
            var hidden = false;
            if (self.summary_mode) {
                // For additions/modifications/context, check new file regions
                if (new_line) |ln| {
                    if (collapse.isLineHidden(self.collapse_regions, ln)) {
                        hidden = true;
                    }
                }
                // For deletions, check old file regions
                if (old_line) |ln| {
                    if (diff_line.line_type == .deletion) {
                        if (collapse.isLineHidden(self.old_collapse_regions, ln)) {
                            hidden = true;
                        }
                    }
                }
            }

            if (!hidden) {
                try indices.append(self.allocator, idx);
            }
        }
    }

    /// Build a list of visible split row indices, respecting collapse state
    fn buildVisibleSplitIndices(self: *UI, indices: *std.ArrayList(usize)) !void {
        for (self.split_rows.items, 0..) |split_row, idx| {
            // Get line numbers from both sides
            const left_line = if (split_row.left) |l| l.line_num else null;
            const right_line = if (split_row.right) |r| r.line_num else null;

            // Check if this row should be hidden due to collapse
            var hidden = false;
            if (self.summary_mode) {
                // Check left side (old file) regions
                if (left_line) |ln| {
                    if (collapse.isLineHidden(self.old_collapse_regions, ln)) {
                        hidden = true;
                    }
                }
                // Check right side (new file) regions
                if (right_line) |ln| {
                    if (collapse.isLineHidden(self.collapse_regions, ln)) {
                        hidden = true;
                    }
                }
            }

            if (!hidden) {
                try indices.append(self.allocator, idx);
            }
        }
    }

    fn setMessage(self: *UI, msg: []const u8, is_error: bool) void {
        self.message = msg;
        self.message_is_error = is_error;
    }

    fn clearMessage(self: *UI) void {
        self.message = null;
    }

    const ascii_graphemes: [256][]const u8 = init: {
        var table: [256][]const u8 = undefined;
        for (0..256) |i| {
            const arr: *const [1]u8 = &[_]u8{@intCast(i)};
            table[i] = arr;
        }
        break :init table;
    };

    fn grapheme(char: u8) []const u8 {
        return ascii_graphemes[char];
    }

    fn writeString(surface: *vxfw.Surface, col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
        var c = col;
        for (text) |char| {
            if (c >= surface.size.width) break;
            surface.writeCell(c, row, .{
                .char = .{ .grapheme = grapheme(char) },
                .style = style,
            });
            c += 1;
        }
    }

    fn fillRow(surface: *vxfw.Surface, row: u16, char: u8, style: vaxis.Style) void {
        for (0..surface.size.width) |c| {
            surface.writeCell(@intCast(c), row, .{
                .char = .{ .grapheme = grapheme(char) },
                .style = style,
            });
        }
    }

    fn draw(self: *UI, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();

        if (size.height < 5 or size.width < 40) {
            return self.drawMessage(ctx, "Terminal too small");
        }

        return switch (self.mode) {
            .help => self.drawHelp(ctx),
            .file_list => self.drawFileList(ctx),
            .ask_response => self.drawAskResponse(ctx),
            .ask_response_comment => self.drawAskResponseComment(ctx),
            else => self.drawMainView(ctx),
        };
    }

    fn drawMessage(self: *UI, ctx: vxfw.DrawContext, msg: []const u8) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        writeString(&surface, 0, 0, msg, .{});
        return surface;
    }

    fn drawMainView(self: *UI, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        // Draw header (row 0)
        self.drawHeader(&surface);

        // Draw diff content (rows 1 to height-3)
        const content_height = size.height -| 3;

        // Choose between split and unified view based on terminal width
        // Split view needs at least 80 columns to be usable
        if (self.view_mode == .split and size.width >= 80) {
            self.drawSplitDiff(&surface, content_height);
        } else {
            self.drawDiff(&surface, content_height);
        }

        // Draw footer (last 2 rows)
        self.drawFooter(&surface);

        return surface;
    }

    fn drawHeader(self: *UI, surface: *vxfw.Surface) void {
        const file = self.session.currentFile();
        const path = if (file) |f| f.path else "(no files)";

        // Header background style
        const header_style: vaxis.Style = .{
            .bg = .{ .rgb = .{ 0x00, 0x5f, 0xaf } }, // Blue background
            .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } }, // White text
            .bold = true,
        };

        // Fill entire header row with background
        fillRow(surface, 0, ' ', header_style);

        // Build header text with view mode and summary mode indicators
        var buf: [256]u8 = undefined;
        const view_indicator = if (self.view_mode == .split) "[⫿]" else "[≡]";
        const summary_indicator = if (self.summary_mode) "[▶]" else "[▼]";
        const header_text = std.fmt.bufPrint(&buf, " rv: {s} ({d}/{d}) {s} {s}", .{
            path,
            self.session.current_file_idx + 1,
            self.session.files.len,
            view_indicator,
            summary_indicator,
        }) catch " rv";

        // Write header text
        writeString(surface, 0, 0, header_text, header_style);
    }

    fn drawDiff(self: *UI, surface: *vxfw.Surface, height: u16) void {
        const file = self.session.currentFile() orelse {
            writeString(surface, 2, 2, "No files to review", .{});
            return;
        };

        if (file.is_binary) {
            writeString(surface, 2, 2, "(binary file)", .{});
            return;
        }

        if (self.diff_lines.items.len == 0) {
            writeString(surface, 2, 2, "No changes in this file", .{});
            return;
        }

        const width = surface.size.width;

        // Build list of visible line indices (respecting collapse state)
        var visible_indices: std.ArrayList(usize) = .empty;
        defer visible_indices.deinit(self.allocator);
        self.buildVisibleIndices(&visible_indices) catch return;

        if (visible_indices.items.len == 0) {
            writeString(surface, 2, 2, "No visible lines", .{});
            return;
        }

        // Find the visible index for cursor_line
        var cursor_visible_idx: usize = 0;
        for (visible_indices.items, 0..) |idx, vi| {
            if (idx == self.cursor_line) {
                cursor_visible_idx = vi;
                break;
            }
            if (idx > self.cursor_line) {
                cursor_visible_idx = if (vi > 0) vi - 1 else 0;
                break;
            }
        }

        // Adjust scroll to keep cursor visible
        if (cursor_visible_idx < self.scroll_offset) {
            self.scroll_offset = cursor_visible_idx;
        } else if (cursor_visible_idx >= self.scroll_offset + height) {
            self.scroll_offset = cursor_visible_idx - height + 1;
        }

        // Render visible lines in unified diff format
        var row: u16 = 0;
        var visible_idx = self.scroll_offset;
        while (row < height and visible_idx < visible_indices.items.len) : ({
            row += 1;
            visible_idx += 1;
        }) {
            const line_idx = visible_indices.items[visible_idx];
            const diff_line = self.diff_lines.items[line_idx];
            const is_selected = line_idx == self.cursor_line;
            const in_selection = if (self.selection_start) |sel|
                (line_idx >= @min(sel, self.cursor_line) and line_idx <= @max(sel, self.cursor_line))
            else
                false;

            // Determine style and prefix based on line type
            // For partial changes: unchanged parts in white, changed parts in color (red/green)
            // For full line changes: entire line in color
            // If partial change but no specific changes marked, treat entire line as changed
            var style: vaxis.Style = .{};
            var novel_style: vaxis.Style = .{};
            var old_style: vaxis.Style = .{}; // Style for old content in modifications
            var old_novel_style: vaxis.Style = .{}; // Style for changed parts in old content
            const has_specific_changes = diff_line.changes.len > 0;
            const prefix: u8 = switch (diff_line.line_type) {
                .addition => blk: {
                    if (diff_line.is_partial_change and has_specific_changes) {
                        style.fg = .{ .rgb = .{ 0xff, 0xff, 0xff } }; // White for unchanged
                    } else {
                        style.fg = .{ .rgb = .{ 0x00, 0xd7, 0x00 } }; // Green for full line
                    }
                    novel_style.fg = .{ .rgb = .{ 0x00, 0xd7, 0x00 } }; // Green for changed
                    novel_style.bold = true;
                    break :blk '+';
                },
                .deletion => blk: {
                    if (diff_line.is_partial_change and has_specific_changes) {
                        style.fg = .{ .rgb = .{ 0xff, 0xff, 0xff } }; // White for unchanged
                    } else {
                        style.fg = .{ .rgb = .{ 0xd7, 0x00, 0x00 } }; // Red for full line
                    }
                    novel_style.fg = .{ .rgb = .{ 0xd7, 0x00, 0x00 } }; // Red for changed
                    novel_style.bold = true;
                    break :blk '-';
                },
                .modification => blk: {
                    // Modification: show new content in green, old content struck through in red
                    style.fg = .{ .rgb = .{ 0x00, 0xd7, 0x00 } }; // Green for new content
                    novel_style.fg = .{ .rgb = .{ 0x00, 0xd7, 0x00 } };
                    novel_style.bold = true;
                    old_style.fg = .{ .rgb = .{ 0xd7, 0x00, 0x00 } }; // Red for old content
                    old_style.strikethrough = true; // Strike through old content
                    old_novel_style.fg = .{ .rgb = .{ 0xd7, 0x00, 0x00 } };
                    old_novel_style.bold = true;
                    old_novel_style.strikethrough = true;
                    break :blk '~';
                },
                .context => blk: {
                    style.fg = .{ .rgb = .{ 0x80, 0x80, 0x80 } }; // Gray for context
                    novel_style = style;
                    break :blk ' ';
                },
            };

            if (is_selected) {
                style.reverse = true;
            } else if (in_selection) {
                style.bg = .{ .rgb = .{ 0x30, 0x30, 0x50 } }; // Subtle highlight
            }

            // Line number styles
            const dim_style: vaxis.Style = .{
                .fg = .{ .rgb = .{ 0x60, 0x60, 0x60 } },
            };
            const red_line_num_style: vaxis.Style = .{
                .fg = .{ .rgb = .{ 0xd7, 0x00, 0x00 } },
            };
            const green_line_num_style: vaxis.Style = .{
                .fg = .{ .rgb = .{ 0x00, 0xd7, 0x00 } },
            };
            const yellow_line_num_style: vaxis.Style = .{
                .fg = .{ .rgb = .{ 0xd7, 0xd7, 0x00 } }, // Yellow for modifications
            };

            // Selection background color
            const selection_bg: vaxis.Color = .{ .rgb = .{ 0x30, 0x30, 0x50 } };

            const display_row = row + 1; // +1 for header
            var col: u16 = 0;

            // Fill entire row with selection background first if in selection
            if (in_selection and !is_selected) {
                var fill_col: u16 = 0;
                while (fill_col < width) : (fill_col += 1) {
                    surface.writeCell(fill_col, display_row, .{
                        .char = .{ .grapheme = " " },
                        .style = .{ .bg = selection_bg },
                    });
                }
            }

            // Old line number (4 chars) - red for deletions, yellow for modifications, dim for context
            var num_buf: [8]u8 = undefined;
            var old_num_style: vaxis.Style = if (is_selected)
                vaxis.Style{ .reverse = true }
            else if (diff_line.line_type == .deletion)
                red_line_num_style
            else if (diff_line.line_type == .modification)
                yellow_line_num_style
            else
                dim_style;

            // Apply selection background to line numbers
            if (in_selection and !is_selected) {
                old_num_style.bg = selection_bg;
            }

            if (diff_line.old_line_num) |num| {
                const num_str = std.fmt.bufPrint(&num_buf, "{d:>4}", .{num}) catch "    ";
                for (num_str) |c| {
                    if (col < width) {
                        surface.writeCell(col, display_row, .{
                            .char = .{ .grapheme = grapheme(c) },
                            .style = old_num_style,
                        });
                        col += 1;
                    }
                }
            } else {
                // Blank for additions (no old line)
                var blank_style = dim_style;
                if (in_selection and !is_selected) {
                    blank_style.bg = selection_bg;
                }
                while (col < 4 and col < width) : (col += 1) {
                    surface.writeCell(col, display_row, .{
                        .char = .{ .grapheme = grapheme(' ') },
                        .style = blank_style,
                    });
                }
            }

            // Space between line numbers
            if (col < width) {
                var space_style = dim_style;
                if (in_selection and !is_selected) {
                    space_style.bg = selection_bg;
                } else if (is_selected) {
                    space_style.reverse = true;
                }
                surface.writeCell(col, display_row, .{
                    .char = .{ .grapheme = grapheme(' ') },
                    .style = space_style,
                });
                col += 1;
            }

            // New line number (4 chars) - green for additions, yellow for modifications, dim for context
            var new_num_style: vaxis.Style = if (is_selected)
                vaxis.Style{ .reverse = true }
            else if (diff_line.line_type == .addition)
                green_line_num_style
            else if (diff_line.line_type == .modification)
                yellow_line_num_style
            else
                dim_style;

            // Apply selection background to line numbers
            if (in_selection and !is_selected) {
                new_num_style.bg = selection_bg;
            }

            if (diff_line.new_line_num) |num| {
                const num_str = std.fmt.bufPrint(&num_buf, "{d:>4}", .{num}) catch "    ";
                for (num_str) |c| {
                    if (col < width) {
                        surface.writeCell(col, display_row, .{
                            .char = .{ .grapheme = grapheme(c) },
                            .style = new_num_style,
                        });
                        col += 1;
                    }
                }
            } else {
                // Blank for deletions (no new line)
                var blank_style = dim_style;
                if (in_selection and !is_selected) {
                    blank_style.bg = selection_bg;
                }
                while (col < 9 and col < width) : (col += 1) {
                    surface.writeCell(col, display_row, .{
                        .char = .{ .grapheme = grapheme(' ') },
                        .style = blank_style,
                    });
                }
            }

            // Space after line numbers - or collapse indicator
            if (col < width) {
                // Check for collapse indicator on new file lines (most common)
                const collapse_ind = if (diff_line.new_line_num) |ln|
                    self.getCollapseIndicator(ln, false)
                else if (diff_line.old_line_num) |ln|
                    self.getCollapseIndicator(ln, true)
                else
                    null;

                if (collapse_ind) |indicator| {
                    const ind_style: vaxis.Style = .{
                        .fg = .{ .rgb = .{ 0xff, 0xd7, 0x00 } }, // Yellow/gold for collapse indicator
                        .bold = true,
                    };
                    surface.writeCell(col, display_row, .{
                        .char = .{ .grapheme = indicator },
                        .style = if (is_selected) vaxis.Style{ .reverse = true } else ind_style,
                    });
                } else {
                    surface.writeCell(col, display_row, .{
                        .char = .{ .grapheme = grapheme(' ') },
                        .style = style,
                    });
                }
                col += 1;
            }

            // Diff prefix (+, -, or space)
            if (col < width) {
                surface.writeCell(col, display_row, .{
                    .char = .{ .grapheme = grapheme(prefix) },
                    .style = style,
                });
                col += 1;
            }

            // Space after prefix
            if (col < width) {
                surface.writeCell(col, display_row, .{
                    .char = .{ .grapheme = grapheme(' ') },
                    .style = style,
                });
                col += 1;
            }

            // Content rendering
            if (diff_line.line_type == .modification) {
                // For modifications: show inline diff with unchanged parts once,
                // deleted parts in red/strikethrough, added parts in green
                if (diff_line.old_content) |old_content_raw| {
                    var old_content = old_content_raw;
                    while (old_content.len > 0 and (old_content[old_content.len - 1] == '\n' or old_content[old_content.len - 1] == '\r')) {
                        old_content = old_content[0 .. old_content.len - 1];
                    }

                    var new_content = diff_line.content;
                    while (new_content.len > 0 and (new_content[new_content.len - 1] == '\n' or new_content[new_content.len - 1] == '\r')) {
                        new_content = new_content[0 .. new_content.len - 1];
                    }

                    col = self.writeInlineDiff(surface, display_row, col, old_content, new_content, diff_line.old_changes, diff_line.changes, width -| col, style, is_selected or in_selection);
                } else {
                    // No old content, just show new content as addition
                    var content = diff_line.content;
                    while (content.len > 0 and (content[content.len - 1] == '\n' or content[content.len - 1] == '\r')) {
                        content = content[0 .. content.len - 1];
                    }
                    const byte_offset = if (diff_line.content_byte_offset > 0)
                        diff_line.content_byte_offset
                    else if (diff_line.new_line_num) |ln|
                        self.computeLineByteOffset(ln)
                    else
                        0;
                    self.writeContentWithHighlight(surface, display_row, col, content, diff_line.changes, width -| col, style, novel_style, is_selected or in_selection, byte_offset, diff_line.line_type);
                }
            } else {
                // Regular line (addition, deletion, context)
                var content = diff_line.content;
                // Strip trailing newlines only
                while (content.len > 0 and (content[content.len - 1] == '\n' or content[content.len - 1] == '\r')) {
                    content = content[0 .. content.len - 1];
                }

                const byte_offset = if (diff_line.content_byte_offset > 0)
                    diff_line.content_byte_offset
                else if (diff_line.new_line_num) |ln|
                    self.computeLineByteOffset(ln)
                else
                    0;
                self.writeContentWithHighlight(surface, display_row, col, content, diff_line.changes, width -| col, style, novel_style, is_selected or in_selection, byte_offset, diff_line.line_type);
            }
        }
    }

    /// Draw the diff in split (side-by-side) view
    /// Draw the diff in split (side-by-side) view
    fn drawSplitDiff(self: *UI, surface: *vxfw.Surface, height: u16) void {
        const file = self.session.currentFile() orelse {
            writeString(surface, 2, 2, "No files to review", .{});
            return;
        };

        if (file.is_binary) {
            writeString(surface, 2, 2, "(binary file)", .{});
            return;
        }

        if (self.split_rows.items.len == 0) {
            writeString(surface, 2, 2, "No changes in this file", .{});
            return;
        }

        const width = surface.size.width;

        // Build list of visible row indices (respecting collapse state)
        var visible_indices: std.ArrayList(usize) = .empty;
        defer visible_indices.deinit(self.allocator);
        self.buildVisibleSplitIndices(&visible_indices) catch return;

        if (visible_indices.items.len == 0) {
            writeString(surface, 2, 2, "No visible lines", .{});
            return;
        }

        // Calculate panel widths
        // Layout: [line_num(5)][content...] | [line_num(5)][content...]
        const separator_col: u16 = width / 2;
        const left_content_start: u16 = 6; // 5 for line num + 1 space
        const right_content_start: u16 = separator_col + 7; // separator + 5 for line num + 1 space
        const left_content_width: u16 = separator_col -| left_content_start -| 1;
        const right_content_width: u16 = width -| right_content_start;

        // Find the visible index for cursor_line
        var cursor_visible_idx: usize = 0;
        for (visible_indices.items, 0..) |idx, vi| {
            if (idx == self.cursor_line) {
                cursor_visible_idx = vi;
                break;
            }
            if (idx > self.cursor_line) {
                cursor_visible_idx = if (vi > 0) vi - 1 else 0;
                break;
            }
        }

        // Adjust scroll to keep cursor visible
        if (cursor_visible_idx < self.scroll_offset) {
            self.scroll_offset = cursor_visible_idx;
        } else if (cursor_visible_idx >= self.scroll_offset + height) {
            self.scroll_offset = cursor_visible_idx - height + 1;
        }

        // Render visible rows
        var row: u16 = 0;
        var visible_idx = self.scroll_offset;
        while (row < height and visible_idx < visible_indices.items.len) : ({
            row += 1;
            visible_idx += 1;
        }) {
            const line_idx = visible_indices.items[visible_idx];
            const split_row = self.split_rows.items[line_idx];
            const is_selected = line_idx == self.cursor_line;
            const in_selection = if (self.selection_start) |sel|
                (line_idx >= @min(sel, self.cursor_line) and line_idx <= @max(sel, self.cursor_line))
            else
                false;

            const display_row = row + 1; // +1 for header

            // Draw separator
            const separator_style: vaxis.Style = .{
                .fg = .{ .rgb = .{ 0x44, 0x44, 0x44 } },
            };
            surface.writeCell(separator_col, display_row, .{
                .char = .{ .grapheme = "│" },
                .style = separator_style,
            });

            // Draw left panel (old file)
            self.drawSplitPanelCell(
                surface,
                display_row,
                0,
                left_content_start,
                left_content_width,
                split_row.left,
                is_selected and self.focus_side == .old,
                in_selection,
                true, // is_left
            );

            // Draw right panel (new file)
            self.drawSplitPanelCell(
                surface,
                display_row,
                separator_col + 1,
                right_content_start,
                right_content_width,
                split_row.right,
                is_selected and self.focus_side == .new,
                in_selection,
                false, // is_left
            );

            // Highlight the focused side when selected
            if (is_selected) {
                // Draw a subtle indicator for which side is focused
                const focus_indicator_col: u16 = if (self.focus_side == .old) 0 else separator_col + 1;
                const focus_style: vaxis.Style = .{
                    .bg = .{ .rgb = .{ 0x00, 0x5f, 0xaf } }, // Blue for focus
                    .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
                };
                surface.writeCell(focus_indicator_col, display_row, .{
                    .char = .{ .grapheme = if (self.focus_side == .old) "◀" else "▶" },
                    .style = focus_style,
                });
            }
        }
    }

    /// Draw a single cell (left or right) in split view
    fn drawSplitPanelCell(
        self: *UI,
        surface: *vxfw.Surface,
        row: u16,
        panel_start: u16,
        content_start: u16,
        content_width: u16,
        cell: ?SplitRow.SplitCell,
        is_selected: bool,
        in_selection: bool,
        is_left: bool,
    ) void {
        const dim_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x60, 0x60, 0x60 } },
        };
        const selection_bg: vaxis.Color = .{ .rgb = .{ 0x30, 0x30, 0x50 } };
        const panel_end = content_start + content_width;

        // Fill entire panel with selection background first if in selection
        if (in_selection and !is_selected) {
            var fill_col = panel_start + 1;
            while (fill_col < panel_end) : (fill_col += 1) {
                surface.writeCell(fill_col, row, .{
                    .char = .{ .grapheme = " " },
                    .style = .{ .bg = selection_bg },
                });
            }
        }

        if (cell) |c| {
            // Determine colors based on line type
            const deletion_bg: vaxis.Color = .{ .rgb = .{ 0x3d, 0x1a, 0x1a } }; // Dark red
            const addition_bg: vaxis.Color = .{ .rgb = .{ 0x1a, 0x3d, 0x1a } }; // Dark green
            const deletion_fg: vaxis.Color = .{ .rgb = .{ 0xff, 0x5f, 0x5f } }; // Red
            const addition_fg: vaxis.Color = .{ .rgb = .{ 0x5f, 0xff, 0x5f } }; // Green
            const context_fg: vaxis.Color = .{ .rgb = .{ 0xa0, 0xa0, 0xa0 } }; // Gray

            var line_num_style: vaxis.Style = dim_style;
            var content_style: vaxis.Style = .{};
            var bg_color: ?vaxis.Color = null;

            switch (c.line_type) {
                .deletion => {
                    line_num_style.fg = deletion_fg;
                    content_style.fg = deletion_fg;
                    bg_color = deletion_bg;
                },
                .addition => {
                    line_num_style.fg = addition_fg;
                    content_style.fg = addition_fg;
                    bg_color = addition_bg;
                },
                .context => {
                    content_style.fg = context_fg;
                },
                .modification => {
                    // Shouldn't happen in split view, but handle it
                    content_style.fg = .{ .rgb = .{ 0xff, 0xd7, 0x00 } };
                },
            }

            if (is_selected) {
                line_num_style.reverse = true;
                content_style.reverse = true;
            } else if (in_selection) {
                // Apply selection background while preserving foreground colors
                line_num_style.bg = selection_bg;
                content_style.bg = selection_bg;
            } else if (bg_color) |bg| {
                content_style.bg = bg;
            }

            // Draw line number with collapse indicator
            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d:>4}", .{c.line_num}) catch "    ";
            var col = panel_start + 1; // +1 for focus indicator space
            for (num_str) |ch| {
                if (col < content_start - 1) { // -1 to leave room for collapse indicator
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = grapheme(ch) },
                        .style = line_num_style,
                    });
                    col += 1;
                }
            }

            // Draw collapse indicator or space
            if (col < content_start) {
                const collapse_ind = self.getCollapseIndicator(c.line_num, is_left);
                if (collapse_ind) |indicator| {
                    const ind_style: vaxis.Style = .{
                        .fg = .{ .rgb = .{ 0xff, 0xd7, 0x00 } }, // Yellow/gold
                        .bold = true,
                    };
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = indicator },
                        .style = if (is_selected) vaxis.Style{ .reverse = true } else ind_style,
                    });
                } else {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = " " },
                        .style = line_num_style,
                    });
                }
                col += 1;
            }

            // Draw content with syntax highlighting
            var content = c.content;
            // Strip trailing newlines
            while (content.len > 0 and (content[content.len - 1] == '\n' or content[content.len - 1] == '\r')) {
                content = content[0 .. content.len - 1];
            }

            // Draw content with highlighting
            self.writeSplitContent(
                surface,
                row,
                content_start,
                content,
                c.changes,
                content_width,
                content_style,
                is_selected,
                c.content_byte_offset,
                c.line_type,
                is_left,
                in_selection,
            );
        } else {
            // Empty cell - fill with background (selection or default)
            var empty_style = dim_style;
            if (in_selection and !is_selected) {
                empty_style.bg = selection_bg;
            }
            var col = panel_start + 1;
            while (col < panel_end) : (col += 1) {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = " " },
                    .style = empty_style,
                });
            }
        }
    }

    /// Write content in split view with syntax highlighting
    fn writeSplitContent(
        self: *UI,
        surface: *vxfw.Surface,
        row: u16,
        start_col: u16,
        content: []const u8,
        changes: []const difft.Change,
        max_width: u16,
        base_style: vaxis.Style,
        is_selected: bool,
        content_byte_offset: u32,
        line_type: DiffLine.LineType,
        is_left: bool,
        in_selection: bool,
    ) void {
        const deletion_bg: vaxis.Color = .{ .rgb = .{ 0x3d, 0x1a, 0x1a } };
        const addition_bg: vaxis.Color = .{ .rgb = .{ 0x1a, 0x3d, 0x1a } };
        const selection_bg: vaxis.Color = .{ .rgb = .{ 0x30, 0x30, 0x50 } };

        var col = start_col;
        var char_idx: u32 = 0;
        var visual_col: u16 = 0;

        // Use appropriate syntax highlighting based on side
        // Left side always uses old file highlighting, right side uses new file highlighting
        const use_old_highlighting = is_left;

        for (content) |c| {
            if (col >= start_col + max_width) break;

            const global_byte_pos = content_byte_offset + char_idx;

            // Check if in a changed region
            var in_change = false;
            for (changes) |change| {
                if (char_idx >= change.start and char_idx < change.end) {
                    in_change = true;
                    break;
                }
            }

            // Get syntax highlighting style
            // Left side uses old file spans, right side uses new file spans
            var style = if (!is_selected) blk: {
                if (use_old_highlighting) {
                    break :blk self.getOldSyntaxStyle(global_byte_pos, base_style);
                } else {
                    break :blk self.getSyntaxStyle(global_byte_pos, base_style);
                }
            } else base_style;

            // Apply background for additions/deletions or selection
            if (!is_selected) {
                if (in_selection) {
                    style.bg = selection_bg;
                } else {
                    switch (line_type) {
                        .addition => {
                            style.bg = addition_bg;
                            if (in_change) {
                                style.bold = true;
                            }
                        },
                        .deletion => {
                            style.bg = deletion_bg;
                            if (in_change) {
                                style.bold = true;
                            }
                        },
                        else => {},
                    }
                }
            }

            if (c == '\t') {
                const spaces_to_add = TAB_WIDTH - (visual_col % TAB_WIDTH);
                var i: u16 = 0;
                while (i < spaces_to_add and col < start_col + max_width) : (i += 1) {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = " " },
                        .style = style,
                    });
                    col += 1;
                    visual_col += 1;
                }
            } else {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme(c) },
                    .style = style,
                });
                col += 1;
                visual_col += 1;
            }
            char_idx += 1;
        }

        // Fill remaining space with background
        const bg_style: vaxis.Style = if (is_selected)
            .{ .reverse = true }
        else if (in_selection)
            .{ .bg = selection_bg }
        else switch (line_type) {
            .addition => .{ .bg = addition_bg },
            .deletion => .{ .bg = deletion_bg },
            else => .{},
        };
        while (col < start_col + max_width) {
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = " " },
                .style = bg_style,
            });
            col += 1;
        }
    }

    /// Get syntax highlighting style for old file content
    fn getOldSyntaxStyle(self: *UI, byte_pos: u32, base_style: vaxis.Style) vaxis.Style {
        for (self.old_syntax_spans) |span| {
            if (byte_pos >= span.start_byte and byte_pos < span.end_byte) {
                return highlightToStyle(span.highlight, base_style);
            }
        }
        return base_style;
    }

    const TAB_WIDTH: u16 = 4;

    fn writeContentWithHighlight(
        self: *UI,
        surface: *vxfw.Surface,
        row: u16,
        start_col: u16,
        content: []const u8,
        changes: []const difft.Change,
        max_width: u16,
        base_style: vaxis.Style,
        novel_style: vaxis.Style,
        is_selected: bool,
        content_byte_offset: u32,
        line_type: DiffLine.LineType,
    ) void {
        _ = self.writeContentWithHighlightAndReturn(surface, row, start_col, content, changes, max_width, base_style, novel_style, is_selected, content_byte_offset, line_type);
    }

    fn writeContentWithHighlightAndReturn(
        self: *UI,
        surface: *vxfw.Surface,
        row: u16,
        start_col: u16,
        content: []const u8,
        changes: []const difft.Change,
        max_width: u16,
        base_style: vaxis.Style,
        novel_style: vaxis.Style,
        is_selected: bool,
        content_byte_offset: u32,
        line_type: DiffLine.LineType,
    ) u16 {
        // Background colors for additions/deletions
        const addition_bg: vaxis.Color = .{ .rgb = .{ 0x1a, 0x3d, 0x1a } }; // Dark green
        const deletion_bg: vaxis.Color = .{ .rgb = .{ 0x3d, 0x1a, 0x1a } }; // Dark red

        var col = start_col;
        var char_idx: u32 = 0;
        // Track visual column for tab alignment (relative to content start)
        var visual_col: u16 = 0;

        // Only apply syntax highlighting for lines from the new file
        // (context, addition, modification). Deletions come from the old file
        // which we don't parse, so syntax highlighting would be incorrect.
        const use_syntax_highlighting = line_type != .deletion;

        for (content) |c| {
            if (col >= start_col + max_width) break;

            // Global byte position in the file
            const global_byte_pos = content_byte_offset + char_idx;

            // Determine if this character is in a changed region
            var in_change = false;
            for (changes) |*change| {
                if (char_idx >= change.start and char_idx < change.end) {
                    in_change = true;
                    break;
                }
            }

            // Compute the style:
            // 1. Start with syntax highlighting if available (only for new file content)
            // 2. Apply background color for additions/deletions
            // 3. Override foreground for changed regions in modifications
            var style = if (!is_selected and use_syntax_highlighting)
                self.getSyntaxStyle(global_byte_pos, base_style)
            else
                base_style;

            // Apply background for additions/deletions
            if (!is_selected) {
                switch (line_type) {
                    .addition => {
                        style.bg = addition_bg;
                    },
                    .deletion => {
                        style.bg = deletion_bg;
                    },
                    .modification => {
                        // For modifications, highlight changed parts with background
                        if (in_change) {
                            style.bg = addition_bg;
                            // Use novel_style foreground for changed parts
                            style.fg = novel_style.fg;
                        }
                    },
                    .context => {
                        // Keep syntax highlighting only
                    },
                }
            }

            if (c == '\t') {
                // Expand tab to spaces (to next tab stop)
                const spaces_to_add = TAB_WIDTH - (visual_col % TAB_WIDTH);
                var i: u16 = 0;
                while (i < spaces_to_add and col < start_col + max_width) : (i += 1) {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = grapheme(' ') },
                        .style = style,
                    });
                    col += 1;
                    visual_col += 1;
                }
            } else {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme(c) },
                    .style = style,
                });
                col += 1;
                visual_col += 1;
            }
            char_idx += 1;
        }
        return col;
    }

    /// Get syntax highlighting style for a byte position
    fn getSyntaxStyle(self: *UI, byte_pos: u32, base_style: vaxis.Style) vaxis.Style {
        // Binary search could be faster but linear is fine for now
        for (self.syntax_spans) |span| {
            if (byte_pos >= span.start_byte and byte_pos < span.end_byte) {
                return highlightToStyle(span.highlight, base_style);
            }
        }
        return base_style;
    }

    /// Compute byte offset for a given line number in new content
    fn computeLineByteOffset(self: *UI, line_num: u32) u32 {
        const file = self.session.currentFile() orelse return 0;
        const content = file.new_content;

        var offset: u32 = 0;
        var current_line: u32 = 1;

        for (content, 0..) |c, i| {
            if (current_line == line_num) {
                return @intCast(i);
            }
            if (c == '\n') {
                current_line += 1;
            }
            offset = @intCast(i + 1);
        }

        return if (current_line == line_num) offset else 0;
    }

    /// Convert highlight type to vaxis style
    fn highlightToStyle(hl: highlight.HighlightType, base_style: vaxis.Style) vaxis.Style {
        var style = base_style;
        switch (hl) {
            .keyword => {
                style.fg = .{ .rgb = .{ 0xc5, 0x8a, 0xff } }; // Purple
                style.bold = true;
            },
            .type_ => {
                style.fg = .{ .rgb = .{ 0x00, 0xd7, 0xd7 } }; // Cyan
            },
            .function => {
                style.fg = .{ .rgb = .{ 0x61, 0xaf, 0xef } }; // Blue
            },
            .string => {
                style.fg = .{ .rgb = .{ 0x98, 0xc3, 0x79 } }; // Green
            },
            .number => {
                style.fg = .{ .rgb = .{ 0xd1, 0x9a, 0x66 } }; // Orange
            },
            .comment => {
                style.fg = .{ .rgb = .{ 0x5c, 0x63, 0x70 } }; // Gray
                style.italic = true;
            },
            .constant => {
                style.fg = .{ .rgb = .{ 0xe5, 0xc0, 0x7b } }; // Yellow
            },
            .operator, .punctuation => {
                style.fg = .{ .rgb = .{ 0xab, 0xb2, 0xbf } }; // Light gray
            },
            .variable => {
                // Keep base style for variables
            },
            .none => {},
        }
        return style;
    }

    /// Write an inline diff showing unchanged parts once, deletions in red/strikethrough,
    /// and additions in green. This creates a compact view like: "const -x-+a+ = 10;"
    fn writeInlineDiff(
        self: *UI,
        surface: *vxfw.Surface,
        row: u16,
        start_col: u16,
        old_content: []const u8,
        new_content: []const u8,
        old_changes: []const difft.Change,
        new_changes: []const difft.Change,
        max_width: u16,
        base_style: vaxis.Style,
        is_selected: bool,
    ) u16 {
        _ = self;
        _ = old_changes;
        _ = new_changes;
        _ = base_style;
        var col = start_col;

        // Styles for different parts
        const deletion_style: vaxis.Style = if (is_selected) .{ .reverse = true } else .{
            .fg = .{ .rgb = .{ 0xff, 0x5f, 0x5f } }, // Red
            .strikethrough = true,
        };
        const addition_style: vaxis.Style = if (is_selected) .{ .reverse = true } else .{
            .fg = .{ .rgb = .{ 0x5f, 0xd7, 0x5f } }, // Green
        };
        // Unchanged parts should be gray/dim, not inherit the modification color
        const unchanged_style: vaxis.Style = if (is_selected) .{ .reverse = true } else .{
            .fg = .{ .rgb = .{ 0x9e, 0x9e, 0x9e } }, // Gray for unchanged parts
        };

        // Compute the actual diff by finding common prefix and suffix
        // This is more reliable than using difftastic's change markers which may mark entire lines

        // Find common prefix length
        var prefix_len: usize = 0;
        while (prefix_len < old_content.len and prefix_len < new_content.len) {
            if (old_content[prefix_len] != new_content[prefix_len]) break;
            prefix_len += 1;
        }

        // Find common suffix length (but don't overlap with prefix)
        var suffix_len: usize = 0;
        while (suffix_len < old_content.len - prefix_len and suffix_len < new_content.len - prefix_len) {
            const old_idx = old_content.len - 1 - suffix_len;
            const new_idx = new_content.len - 1 - suffix_len;
            if (old_content[old_idx] != new_content[new_idx]) break;
            suffix_len += 1;
        }

        // The differing parts
        const old_diff_start = prefix_len;
        const old_diff_end = old_content.len - suffix_len;
        const new_diff_start = prefix_len;
        const new_diff_end = new_content.len - suffix_len;

        // Render common prefix (unchanged)
        for (old_content[0..prefix_len]) |c| {
            if (col >= start_col + max_width) break;
            if (c == '\t') {
                var spaces: u16 = 0;
                while (spaces < TAB_WIDTH and col < start_col + max_width) : (spaces += 1) {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = " " },
                        .style = unchanged_style,
                    });
                    col += 1;
                }
            } else {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme(c) },
                    .style = unchanged_style,
                });
                col += 1;
            }
        }

        // Render deleted part (from old content) in red with strikethrough
        for (old_content[old_diff_start..old_diff_end]) |c| {
            if (col >= start_col + max_width) break;
            if (c == '\t') {
                var spaces: u16 = 0;
                while (spaces < TAB_WIDTH and col < start_col + max_width) : (spaces += 1) {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = " " },
                        .style = deletion_style,
                    });
                    col += 1;
                }
            } else {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme(c) },
                    .style = deletion_style,
                });
                col += 1;
            }
        }

        // Render added part (from new content) in green
        for (new_content[new_diff_start..new_diff_end]) |c| {
            if (col >= start_col + max_width) break;
            if (c == '\t') {
                var spaces: u16 = 0;
                while (spaces < TAB_WIDTH and col < start_col + max_width) : (spaces += 1) {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = " " },
                        .style = addition_style,
                    });
                    col += 1;
                }
            } else {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme(c) },
                    .style = addition_style,
                });
                col += 1;
            }
        }

        // Render common suffix (unchanged)
        if (suffix_len > 0) {
            for (new_content[new_content.len - suffix_len ..]) |c| {
                if (col >= start_col + max_width) break;
                if (c == '\t') {
                    var spaces: u16 = 0;
                    while (spaces < TAB_WIDTH and col < start_col + max_width) : (spaces += 1) {
                        surface.writeCell(col, row, .{
                            .char = .{ .grapheme = " " },
                            .style = unchanged_style,
                        });
                        col += 1;
                    }
                } else {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = grapheme(c) },
                        .style = unchanged_style,
                    });
                    col += 1;
                }
            }
        }

        return col;
    }

    /// Get semantic syntax highlighting style based on difftastic's highlight type
    /// Combines the base novel color (red/green) with semantic token styling
    fn getSemanticStyle(hl_type: difft.Highlight, novel_style: vaxis.Style) vaxis.Style {
        var style = novel_style;

        switch (hl_type) {
            .string => {
                // Strings: warm orange/yellow tint
                style.fg = blendSemanticColor(novel_style.fg, .{ .rgb = .{ 0xff, 0xd7, 0x00 } });
            },
            .comment => {
                // Comments: dimmed/italic appearance
                style.italic = true;
                style.fg = blendSemanticColor(novel_style.fg, .{ .rgb = .{ 0x87, 0x87, 0x87 } });
            },
            .keyword => {
                // Keywords: bold with slight blue tint
                style.bold = true;
                style.fg = blendSemanticColor(novel_style.fg, .{ .rgb = .{ 0x87, 0xaf, 0xff } });
            },
            .type_ => {
                // Types: cyan tint
                style.fg = blendSemanticColor(novel_style.fg, .{ .rgb = .{ 0x00, 0xd7, 0xd7 } });
            },
            .delimiter => {
                // Delimiters: slightly dimmed
                style.fg = blendSemanticColor(novel_style.fg, .{ .rgb = .{ 0xaf, 0xaf, 0xaf } });
            },
            .tree_sitter_error => {
                // Parse errors: underlined
                style.ul_style = .single;
            },
            .novel, .normal => {
                // Default: use the novel_style as-is
            },
        }

        return style;
    }

    /// Blend a semantic color with the base diff color (red/green)
    /// This keeps the diff indication while adding semantic meaning
    fn blendSemanticColor(base: vaxis.Color, semantic: vaxis.Color) vaxis.Color {
        const base_rgb = switch (base) {
            .rgb => |rgb| rgb,
            else => return semantic, // If not RGB, just use semantic color
        };
        const semantic_rgb = switch (semantic) {
            .rgb => |rgb| rgb,
            else => return base,
        };

        // Blend: 60% base (diff color) + 40% semantic color
        // This maintains visibility of add/delete while showing token type
        return .{ .rgb = .{
            @intCast((@as(u16, base_rgb[0]) * 6 + @as(u16, semantic_rgb[0]) * 4) / 10),
            @intCast((@as(u16, base_rgb[1]) * 6 + @as(u16, semantic_rgb[1]) * 4) / 10),
            @intCast((@as(u16, base_rgb[2]) * 6 + @as(u16, semantic_rgb[2]) * 4) / 10),
        } };
    }

    fn drawFooter(self: *UI, surface: *vxfw.Surface) void {
        const height = surface.size.height;
        const width = surface.size.width;
        const footer_row: u16 = @intCast(height -| 2);
        const status_row: u16 = @intCast(height -| 1);

        const dim_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x80, 0x80, 0x80 } },
        };

        switch (self.mode) {
            .comment_input => {
                writeString(surface, 0, footer_row, "Comment: ", .{ .bold = true });
                writeString(surface, 9, footer_row, self.input_buffer.slice(), .{});
                writeString(surface, 0, status_row, "[Enter] submit  [Esc] cancel", dim_style);
            },
            .ask_input => {
                writeString(surface, 0, footer_row, "Ask Pi: ", .{ .bold = true, .fg = .{ .rgb = .{ 0xaf, 0x5f, 0xff } } });
                writeString(surface, 8, footer_row, self.input_buffer.slice(), .{});
                writeString(surface, 0, status_row, "[Enter] ask  [Esc] cancel", dim_style);
            },
            else => {
                writeString(surface, 0, footer_row, "[↑↓] nav  [Shift+↑↓] select  [c] comment  [a] ask  [v] view  [Tab] side  [?] help", dim_style);

                // Show spinner if ask is in progress
                if (self.ask_in_progress) {
                    const spinner_frames = [_][]const u8{ "⣶", "⣧", "⣏", "⡟", "⠿", "⢻", "⣹", "⣼" };
                    const frame_idx = self.spinner_frame % spinner_frames.len;
                    const spinner_char = spinner_frames[frame_idx];

                    const spinner_style: vaxis.Style = .{
                        .fg = .{ .rgb = .{ 0xaf, 0x5f, 0xff } }, // Purple
                        .bold = true,
                    };

                    surface.writeCell(0, status_row, .{
                        .char = .{ .grapheme = spinner_char, .width = 1 },
                        .style = spinner_style,
                    });
                    writeString(surface, 2, status_row, "Asking Pi...", spinner_style);
                } else if (self.message) |msg| {
                    const msg_style: vaxis.Style = .{
                        .fg = if (self.message_is_error)
                            .{ .rgb = .{ 0xd7, 0x00, 0x00 } }
                        else
                            .{ .rgb = .{ 0x00, 0xd7, 0x00 } },
                    };
                    writeString(surface, 0, status_row, msg, msg_style);
                } else {
                    var buf: [64]u8 = undefined;
                    const comment_text = std.fmt.bufPrint(&buf, "Comments: {d}", .{self.session.comments.items.len}) catch "Comments: ?";
                    writeString(surface, 0, status_row, comment_text, dim_style);
                }

                // Show view mode and focus indicator
                var mode_buf: [32]u8 = undefined;
                const view_text = if (self.view_mode == .split) "SPLIT" else "UNIFIED";
                const focus_text = if (self.focus_side == .new) "NEW" else "OLD";
                const mode_text = std.fmt.bufPrint(&mode_buf, "{s} | {s}", .{ view_text, focus_text }) catch "?";
                if (width > 20) {
                    writeString(surface, @intCast(width -| @as(u16, @intCast(mode_text.len)) -| 1), status_row, mode_text, dim_style);
                }
            },
        }
    }

    fn drawHelp(self: *UI, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        const help_lines = [_][]const u8{
            "",
            "  rv - A local code review tool for the agentic world",
            "",
            "  Navigation:",
            "    Up/Down             Move cursor by line",
            "    Shift+Up/Down       Select lines",
            "    Left/Right          Previous/next file",
            "    f/p                 Page forward/backward",
            "    Shift+f/p           Page with selection",
            "    g/G                 Go to top/bottom",
            "    PgUp/PgDn           Page up/down",
            "    Shift+PgUp/PgDn     Page with selection",
            "    l or .              Show file list",
            "",
            "  View:",
            "    v                   Toggle split/unified view",
            "    Tab                 Toggle focus (old/new side)",
            "    s                   Toggle summary/expanded mode",
            "    Enter               Expand/collapse region at cursor",
            "",
            "  Actions:",
            "    c                   Add comment at cursor/selection",
            "    a                   Ask Pi about cursor/selection",
            "    Space               Toggle line selection",
            "    Esc                 Clear selection/message",
            "    q                   Quit and export markdown",
            "    ?                   Toggle this help",
            "",
            "  In Pi Response View:",
            "    c                   Add comment on the code",
            "    Up/Down/PgUp/PgDn   Scroll answer",
            "    Esc/q               Close response",
            "",
            "  Press ? or Esc to close",
        };

        for (help_lines, 0..) |line, row| {
            if (row >= size.height) break;
            writeString(&surface, 0, @intCast(row), line, .{});
        }

        return surface;
    }

    fn drawFileList(self: *UI, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        writeString(&surface, 2, 1, "Files to review:", .{ .bold = true });

        var row: u16 = 3;
        for (self.session.files, 0..) |file, idx| {
            if (row >= size.height -| 2) break;

            const is_current = idx == self.session.current_file_idx;
            const is_selected = idx == self.file_list_cursor;

            var style: vaxis.Style = .{};
            if (is_selected) {
                style.bold = true;
                style.bg = .{ .rgb = .{ 0x44, 0x44, 0x44 } }; // Dark gray background
                style.fg = .{ .rgb = .{ 0xff, 0xff, 0xff } }; // White text
            } else if (is_current) {
                style.bold = true;
                style.fg = .{ .rgb = .{ 0xd7, 0xd7, 0x00 } }; // Yellow
            }

            var buf: [256]u8 = undefined;
            const line_text = std.fmt.bufPrint(&buf, "  {d}. {s}{s}", .{
                idx + 1,
                if (is_current) "> " else "  ",
                file.path,
            }) catch "  ?. (error)";

            writeString(&surface, 0, row, line_text, style);
            row += 1;
        }

        const dim_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x80, 0x80, 0x80 } },
        };
        writeString(&surface, 2, @intCast(size.height -| 1), "[↑↓] navigate  [Enter] select  [l/Esc] close", dim_style);

        return surface;
    }

    fn drawAskResponse(self: *UI, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        // Header
        const header_style: vaxis.Style = .{
            .bg = .{ .rgb = .{ 0x5f, 0x00, 0xaf } }, // Purple background
            .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
            .bold = true,
        };
        fillRow(&surface, 0, ' ', header_style);
        writeString(&surface, 1, 0, " Pi Response", header_style);

        const dim_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x80, 0x80, 0x80 } },
        };
        const question_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0xaf, 0x5f, 0xff } }, // Purple for question
            .bold = true,
        };
        const label_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x5f, 0x87, 0xaf } }, // Blue for labels
            .bold = true,
        };
        const separator_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x44, 0x44, 0x44 } },
        };

        // Use stored original lines count
        const code_line_count: u16 = @intCast(self.ask_original_diff_lines.items.len);

        // Layout calculation
        const footer_row: u16 = size.height -| 1;
        var current_row: u16 = 1;

        // File and line info (use stored original file)
        if (self.ask_original_file) |file| {
            var info_buf: [128]u8 = undefined;
            const info = if (self.ask_context_lines) |l|
                if (l.start == l.end)
                    std.fmt.bufPrint(&info_buf, "File: {s}, Line {d}", .{ file, l.start }) catch "File: ?"
                else
                    std.fmt.bufPrint(&info_buf, "File: {s}, Lines {d}-{d}", .{ file, l.start, l.end }) catch "File: ?"
            else
                std.fmt.bufPrint(&info_buf, "File: {s}", .{file}) catch "File: ?";
            writeString(&surface, 2, current_row, info, dim_style);
            current_row += 1;
        }

        // Question section
        writeString(&surface, 2, current_row, "Question:", label_style);
        current_row += 1;
        if (self.ask_original_question) |q| {
            const max_question_width = size.width -| 4;
            const display_q = if (q.len > max_question_width) q[0..max_question_width] else q;
            writeString(&surface, 2, current_row, display_q, question_style);
            current_row += 1;
        }

        // Separator
        current_row += 1;
        var sep_col: u16 = 0;
        while (sep_col < size.width) : (sep_col += 1) {
            surface.writeCell(sep_col, current_row, .{
                .char = .{ .grapheme = "─" },
                .style = separator_style,
            });
        }
        current_row += 1;

        // Code section label
        writeString(&surface, 2, current_row, "Selected Code:", label_style);
        current_row += 1;

        // Calculate space for code and answer
        const remaining_rows = footer_row -| current_row -| 3; // -3 for separator and answer label
        const max_code_rows = @min(code_line_count, remaining_rows / 2);
        const code_section_end = current_row + max_code_rows;

        // Draw the stored diff lines (use stored original lines)
        if (self.view_mode == .split and size.width >= 80 and self.ask_original_split_rows.items.len > 0) {
            // Split view for code
            const panel_width = (size.width -| 1) / 2;
            const separator_col = panel_width;
            const left_content_start: u16 = 6;
            const right_content_start: u16 = separator_col + 7;
            const left_content_width = separator_col -| left_content_start -| 1;
            const right_content_width = size.width -| right_content_start;

            var code_row = current_row;
            for (self.ask_original_split_rows.items) |split_row| {
                if (code_row >= code_section_end) break;

                // Draw separator
                surface.writeCell(separator_col, code_row, .{
                    .char = .{ .grapheme = "│" },
                    .style = separator_style,
                });

                // Draw left panel
                self.drawResponseCodeCell(&surface, code_row, 0, left_content_start, left_content_width, split_row.left, true);

                // Draw right panel
                self.drawResponseCodeCell(&surface, code_row, separator_col + 1, right_content_start, right_content_width, split_row.right, false);

                code_row += 1;
            }
            current_row = code_row;
        } else {
            // Unified view for code (use stored original diff lines)
            var code_row = current_row;
            for (self.ask_original_diff_lines.items) |diff_line| {
                if (code_row >= code_section_end) break;
                self.drawResponseUnifiedLine(&surface, code_row, diff_line, size.width);
                code_row += 1;
            }
            current_row = code_row;
        }

        // Separator before answer
        current_row += 1;
        sep_col = 0;
        while (sep_col < size.width) : (sep_col += 1) {
            surface.writeCell(sep_col, current_row, .{
                .char = .{ .grapheme = "─" },
                .style = separator_style,
            });
        }
        current_row += 1;

        // Answer section
        writeString(&surface, 2, current_row, "Answer:", label_style);
        current_row += 1;

        const response = self.ask_response orelse "(No response)";
        var resp_iter = std.mem.splitScalar(u8, response, '\n');

        // Skip lines based on scroll offset for answer section
        var lines_to_skip = self.ask_scroll_offset;
        while (resp_iter.next()) |line| {
            if (current_row >= footer_row) break;

            // Word wrap long lines
            if (line.len > size.width -| 4) {
                var start: usize = 0;
                while (start < line.len) {
                    if (current_row >= footer_row) break;
                    const end = @min(start + size.width -| 4, line.len);

                    if (lines_to_skip > 0) {
                        lines_to_skip -= 1;
                    } else {
                        writeString(&surface, 2, current_row, line[start..end], .{});
                        current_row += 1;
                    }
                    start = end;
                }
            } else {
                if (lines_to_skip > 0) {
                    lines_to_skip -= 1;
                } else {
                    writeString(&surface, 2, current_row, line, .{});
                    current_row += 1;
                }
            }
        }

        // Footer
        writeString(&surface, 2, footer_row, "[↑↓/PgUp/PgDn] scroll  [c] add comment  [Esc/q] close", dim_style);

        return surface;
    }

    fn drawAskResponseComment(self: *UI, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        // Header
        const header_style: vaxis.Style = .{
            .bg = .{ .rgb = .{ 0x00, 0x5f, 0x87 } }, // Blue background
            .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
            .bold = true,
        };
        fillRow(&surface, 0, ' ', header_style);
        writeString(&surface, 1, 0, " Add Comment", header_style);

        const dim_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x80, 0x80, 0x80 } },
        };
        const label_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x5f, 0x87, 0xaf } }, // Blue for labels
            .bold = true,
        };
        const separator_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x44, 0x44, 0x44 } },
        };
        const input_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
        };

        var current_row: u16 = 1;

        // File and line info
        if (self.ask_original_file) |file| {
            var info_buf: [128]u8 = undefined;
            const info = if (self.ask_context_lines) |l|
                if (l.start == l.end)
                    std.fmt.bufPrint(&info_buf, "File: {s}, Line {d}", .{ file, l.start }) catch "File: ?"
                else
                    std.fmt.bufPrint(&info_buf, "File: {s}, Lines {d}-{d}", .{ file, l.start, l.end }) catch "File: ?"
            else
                std.fmt.bufPrint(&info_buf, "File: {s}", .{file}) catch "File: ?";
            writeString(&surface, 2, current_row, info, dim_style);
            current_row += 1;
        }

        // Separator
        current_row += 1;
        var sep_col: u16 = 0;
        while (sep_col < size.width) : (sep_col += 1) {
            surface.writeCell(sep_col, current_row, .{
                .char = .{ .grapheme = "─" },
                .style = separator_style,
            });
        }
        current_row += 1;

        // Code section label
        writeString(&surface, 2, current_row, "Code Context:", label_style);
        current_row += 1;

        // Show the code (limited)
        const code_line_count: u16 = @intCast(self.ask_original_diff_lines.items.len);
        const max_code_rows = @min(code_line_count, 8); // Max 8 lines of code
        const code_section_end = current_row + max_code_rows;

        if (self.view_mode == .split and size.width >= 80 and self.ask_original_split_rows.items.len > 0) {
            const panel_width = (size.width -| 1) / 2;
            const separator_col = panel_width;
            const left_content_start: u16 = 6;
            const right_content_start: u16 = separator_col + 7;
            const left_content_width = separator_col -| left_content_start -| 1;
            const right_content_width = size.width -| right_content_start;

            var code_row = current_row;
            for (self.ask_original_split_rows.items) |split_row| {
                if (code_row >= code_section_end) break;

                surface.writeCell(separator_col, code_row, .{
                    .char = .{ .grapheme = "│" },
                    .style = separator_style,
                });

                self.drawResponseCodeCell(&surface, code_row, 0, left_content_start, left_content_width, split_row.left, true);
                self.drawResponseCodeCell(&surface, code_row, separator_col + 1, right_content_start, right_content_width, split_row.right, false);

                code_row += 1;
            }
            current_row = code_row;
        } else {
            var code_row = current_row;
            for (self.ask_original_diff_lines.items) |diff_line| {
                if (code_row >= code_section_end) break;
                self.drawResponseUnifiedLine(&surface, code_row, diff_line, size.width);
                code_row += 1;
            }
            current_row = code_row;
        }

        // Show "..." if there's more code
        if (code_line_count > max_code_rows) {
            writeString(&surface, 2, current_row, "...", dim_style);
            current_row += 1;
        }

        // Separator before input
        current_row += 1;
        sep_col = 0;
        while (sep_col < size.width) : (sep_col += 1) {
            surface.writeCell(sep_col, current_row, .{
                .char = .{ .grapheme = "─" },
                .style = separator_style,
            });
        }
        current_row += 1;

        // Comment input section
        writeString(&surface, 2, current_row, "Comment:", label_style);
        current_row += 1;

        // Input field with cursor
        const input_row = current_row;
        writeString(&surface, 2, input_row, self.input_buffer.slice(), input_style);

        // Draw cursor
        const cursor_col: u16 = 2 + @as(u16, @intCast(self.input_buffer.slice().len));
        surface.writeCell(cursor_col, input_row, .{
            .char = .{ .grapheme = "▌" },
            .style = .{ .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } } },
        });

        // Footer
        const footer_row: u16 = size.height -| 1;
        writeString(&surface, 2, footer_row, "[Enter] submit  [Esc] cancel", dim_style);

        return surface;
    }

    /// Draw a single cell in the response code section (for split view)
    /// Note: Does not use syntax highlighting since stored lines may be from a different file
    fn drawResponseCodeCell(
        _: *UI,
        surface: *vxfw.Surface,
        row: u16,
        panel_start: u16,
        content_start: u16,
        content_width: u16,
        cell: ?SplitRow.SplitCell,
        _: bool, // is_left - not used since no syntax highlighting
    ) void {
        const dim_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x60, 0x60, 0x60 } } };
        const deletion_bg: vaxis.Color = .{ .rgb = .{ 0x3d, 0x1a, 0x1a } };
        const addition_bg: vaxis.Color = .{ .rgb = .{ 0x1a, 0x3d, 0x1a } };
        const deletion_fg: vaxis.Color = .{ .rgb = .{ 0xff, 0x5f, 0x5f } };
        const addition_fg: vaxis.Color = .{ .rgb = .{ 0x5f, 0xff, 0x5f } };
        const context_fg: vaxis.Color = .{ .rgb = .{ 0xa0, 0xa0, 0xa0 } };

        const panel_end = content_start + content_width;

        if (cell) |c| {
            var line_num_style = dim_style;
            var content_style: vaxis.Style = .{};

            switch (c.line_type) {
                .deletion => {
                    line_num_style.fg = deletion_fg;
                    content_style.fg = deletion_fg;
                    content_style.bg = deletion_bg;
                },
                .addition => {
                    line_num_style.fg = addition_fg;
                    content_style.fg = addition_fg;
                    content_style.bg = addition_bg;
                },
                .context => {
                    content_style.fg = context_fg;
                },
                .modification => {
                    content_style.fg = .{ .rgb = .{ 0xff, 0xd7, 0x00 } };
                },
            }

            // Draw line number
            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d:>4} ", .{c.line_num}) catch "     ";
            var col = panel_start;
            for (num_str) |ch| {
                if (col < content_start) {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = grapheme(ch) },
                        .style = line_num_style,
                    });
                    col += 1;
                }
            }

            // Draw content directly without syntax highlighting
            var content = c.content;
            while (content.len > 0 and (content[content.len - 1] == '\n' or content[content.len - 1] == '\r')) {
                content = content[0 .. content.len - 1];
            }

            // Render content character by character
            var visual_col: u16 = 0;
            for (content) |ch| {
                if (col >= panel_end) break;

                if (ch == '\t') {
                    const spaces_to_add = TAB_WIDTH - (visual_col % TAB_WIDTH);
                    var i: u16 = 0;
                    while (i < spaces_to_add and col < panel_end) : (i += 1) {
                        surface.writeCell(col, row, .{
                            .char = .{ .grapheme = " " },
                            .style = content_style,
                        });
                        col += 1;
                        visual_col += 1;
                    }
                } else {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = grapheme(ch) },
                        .style = content_style,
                    });
                    col += 1;
                    visual_col += 1;
                }
            }

            // Fill remaining space
            while (col < panel_end) : (col += 1) {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = " " },
                    .style = content_style,
                });
            }
        } else {
            // Empty cell
            var col = panel_start;
            while (col < panel_end) : (col += 1) {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = " " },
                    .style = dim_style,
                });
            }
        }
    }

    /// Draw a single line in the response code section (for unified view)
    /// Note: Does not use syntax highlighting since stored lines may be from a different file
    fn drawResponseUnifiedLine(_: *UI, surface: *vxfw.Surface, row: u16, diff_line: DiffLine, width: u16) void {
        const dim_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x60, 0x60, 0x60 } } };
        const deletion_fg: vaxis.Color = .{ .rgb = .{ 0xd7, 0x00, 0x00 } };
        const addition_fg: vaxis.Color = .{ .rgb = .{ 0x00, 0xd7, 0x00 } };
        const deletion_bg: vaxis.Color = .{ .rgb = .{ 0x3d, 0x1a, 0x1a } };
        const addition_bg: vaxis.Color = .{ .rgb = .{ 0x1a, 0x3d, 0x1a } };

        var style: vaxis.Style = .{};
        const prefix: u8 = switch (diff_line.line_type) {
            .addition => blk: {
                style.fg = addition_fg;
                style.bg = addition_bg;
                break :blk '+';
            },
            .deletion => blk: {
                style.fg = deletion_fg;
                style.bg = deletion_bg;
                break :blk '-';
            },
            .modification => blk: {
                style.fg = .{ .rgb = .{ 0xff, 0xd7, 0x00 } };
                break :blk '~';
            },
            .context => blk: {
                style.fg = .{ .rgb = .{ 0x80, 0x80, 0x80 } };
                break :blk ' ';
            },
        };

        var col: u16 = 2; // Start with indent

        // Line numbers
        var num_buf: [8]u8 = undefined;
        if (diff_line.old_line_num) |num| {
            const num_str = std.fmt.bufPrint(&num_buf, "{d:>4}", .{num}) catch "    ";
            for (num_str) |c| {
                if (col < width) {
                    surface.writeCell(col, row, .{ .char = .{ .grapheme = grapheme(c) }, .style = dim_style });
                    col += 1;
                }
            }
        } else {
            while (col < 6) : (col += 1) {
                surface.writeCell(col, row, .{ .char = .{ .grapheme = " " }, .style = dim_style });
            }
        }

        if (col < width) {
            surface.writeCell(col, row, .{ .char = .{ .grapheme = " " }, .style = dim_style });
            col += 1;
        }

        if (diff_line.new_line_num) |num| {
            const num_str = std.fmt.bufPrint(&num_buf, "{d:>4}", .{num}) catch "    ";
            for (num_str) |c| {
                if (col < width) {
                    surface.writeCell(col, row, .{ .char = .{ .grapheme = grapheme(c) }, .style = dim_style });
                    col += 1;
                }
            }
        } else {
            while (col < 11) : (col += 1) {
                surface.writeCell(col, row, .{ .char = .{ .grapheme = " " }, .style = dim_style });
            }
        }

        // Prefix
        if (col < width) {
            surface.writeCell(col, row, .{ .char = .{ .grapheme = " " }, .style = style });
            col += 1;
        }
        if (col < width) {
            surface.writeCell(col, row, .{ .char = .{ .grapheme = grapheme(prefix) }, .style = style });
            col += 1;
        }
        if (col < width) {
            surface.writeCell(col, row, .{ .char = .{ .grapheme = " " }, .style = style });
            col += 1;
        }

        // Content - render directly without syntax highlighting
        var content = diff_line.content;
        while (content.len > 0 and (content[content.len - 1] == '\n' or content[content.len - 1] == '\r')) {
            content = content[0 .. content.len - 1];
        }

        var visual_col: u16 = 0;
        for (content) |ch| {
            if (col >= width) break;

            if (ch == '\t') {
                const spaces_to_add = TAB_WIDTH - (visual_col % TAB_WIDTH);
                var i: u16 = 0;
                while (i < spaces_to_add and col < width) : (i += 1) {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = " " },
                        .style = style,
                    });
                    col += 1;
                    visual_col += 1;
                }
            } else {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme(ch) },
                    .style = style,
                });
                col += 1;
                visual_col += 1;
            }
        }

        // Fill remaining space with background
        while (col < width) : (col += 1) {
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = " " },
                .style = style,
            });
        }
    }

    /// Run the UI with vxfw
    pub fn run(self: *UI, process_init: std.process.Init) !void {
        var app = try vxfw.App.init(process_init.gpa, process_init.io);
        defer app.deinit();

        app.run(self.widget(), .{}) catch |err| {
            return err;
        };
    }
};

/// Check if the changes only affect part of the line content
/// Returns true if there are unchanged portions at the start or end of the line
fn isPartialChange(content: []const u8, changes: []const difft.Change) bool {
    if (changes.len == 0) return false;
    if (content.len == 0) return false;

    // Find the min start and max end of all changes
    var min_start: u32 = std.math.maxInt(u32);
    var max_end: u32 = 0;

    for (changes) |change| {
        min_start = @min(min_start, change.start);
        max_end = @max(max_end, change.end);
    }

    // If changes don't start at 0 or don't extend to the end, it's partial
    return min_start > 0 or max_end < content.len;
}

/// Compute which range of characters in old_content were deleted compared to new_content
/// Returns the start and end indices of the deleted portion in old_content
fn computeDeletedRange(old_content: []const u8, new_content: []const u8) struct { start: u32, end: u32 } {
    // Find common prefix length
    var prefix_len: usize = 0;
    while (prefix_len < old_content.len and prefix_len < new_content.len and
        old_content[prefix_len] == new_content[prefix_len])
    {
        prefix_len += 1;
    }

    // Find common suffix length (don't overlap with prefix)
    var suffix_len: usize = 0;
    while (suffix_len < old_content.len - prefix_len and
        suffix_len < new_content.len - prefix_len and
        old_content[old_content.len - 1 - suffix_len] == new_content[new_content.len - 1 - suffix_len])
    {
        suffix_len += 1;
    }

    // The deleted range is everything between prefix and suffix in old_content
    const start: u32 = @intCast(prefix_len);
    const end: u32 = @intCast(old_content.len - suffix_len);

    return .{ .start = start, .end = end };
}

/// Compute which range of characters in new_content were added compared to old_content
/// Returns the start and end indices of the added portion in new_content
fn computeAddedRange(old_content: []const u8, new_content: []const u8) struct { start: u32, end: u32 } {
    // Find common prefix length
    var prefix_len: usize = 0;
    while (prefix_len < old_content.len and prefix_len < new_content.len and
        old_content[prefix_len] == new_content[prefix_len])
    {
        prefix_len += 1;
    }

    // Find common suffix length (don't overlap with prefix)
    var suffix_len: usize = 0;
    while (suffix_len < old_content.len - prefix_len and
        suffix_len < new_content.len - prefix_len and
        old_content[old_content.len - 1 - suffix_len] == new_content[new_content.len - 1 - suffix_len])
    {
        suffix_len += 1;
    }

    // The added range is everything between prefix and suffix in new_content
    const start: u32 = @intCast(prefix_len);
    const end: u32 = @intCast(new_content.len - suffix_len);

    return .{ .start = start, .end = end };
}

test "deleted file shows content" {
    const allocator = std.testing.allocator;

    // Create a simple deleted file diff with no chunks (as difft produces)
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .removed,
        .chunks = &.{},
        .allocator = allocator,
    };

    const old_content = "line 1\nline 2\nline 3";
    const new_content = "";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    // Create UI and build the diff lines
    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Verify that deleted lines are shown with content
    try std.testing.expect(ui.diff_lines.items.len == 3);
    try std.testing.expect(ui.diff_lines.items[0].line_type == .deletion);
    try std.testing.expectEqualStrings("line 1", ui.diff_lines.items[0].content);

    try std.testing.expect(ui.diff_lines.items[1].line_type == .deletion);
    try std.testing.expectEqualStrings("line 2", ui.diff_lines.items[1].content);

    try std.testing.expect(ui.diff_lines.items[2].line_type == .deletion);
    try std.testing.expectEqualStrings("line 3", ui.diff_lines.items[2].content);
}

test "added file shows content" {
    const allocator = std.testing.allocator;

    // Create a simple added file diff with no chunks (as difft produces)
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "new.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .added,
        .chunks = &.{},
        .allocator = allocator,
    };

    const old_content = "";
    const new_content = "fn main() {}";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "new.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    // Create UI and build the diff lines
    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Verify that added lines are shown with content
    try std.testing.expect(ui.diff_lines.items.len == 1);
    try std.testing.expect(ui.diff_lines.items[0].line_type == .addition);
    try std.testing.expectEqualStrings("fn main() {}", ui.diff_lines.items[0].content);
}

test "context lines added around changes" {
    const allocator = std.testing.allocator;

    // Create a diff with changes in the middle of a file
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var changes: std.ArrayList(difft.Change) = .empty;
    defer changes.deinit(allocator);

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Add a modified line at difft line 5 (0-based) = display line 6 (1-based)
    try chunk_entries.append(allocator, .{
        .lhs = .{
            .line_number = 5,
            .changes = &.{},
        },
        .rhs = .{
            .line_number = 5,
            .changes = &.{},
        },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    // Create content with 10 lines
    const old_content = "line 1\nline 2\nline 3\nline 4\nline 5\nold line 6\nline 7\nline 8\nline 9\nline 10";
    const new_content = "line 1\nline 2\nline 3\nline 4\nline 5\nnew line 6\nline 7\nline 8\nline 9\nline 10";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Should have: 3 context lines before (3-5), 1 modification line for line 6, and 3 context lines after (7-9)
    // Total: 3 + 1 + 3 = 7 lines
    try std.testing.expect(ui.diff_lines.items.len == 7);

    // Lines 3, 4, 5 should be context (before the change at display line 6)
    try std.testing.expectEqual(ui.diff_lines.items[0].new_line_num, 3);
    try std.testing.expect(ui.diff_lines.items[0].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[1].new_line_num, 4);
    try std.testing.expect(ui.diff_lines.items[1].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[2].new_line_num, 5);
    try std.testing.expect(ui.diff_lines.items[2].line_type == .context);

    // Line 6 is shown as unified modification (both old and new content)
    try std.testing.expectEqual(ui.diff_lines.items[3].old_line_num, 6);
    try std.testing.expectEqual(ui.diff_lines.items[3].new_line_num, 6);
    try std.testing.expect(ui.diff_lines.items[3].line_type == .modification);
    try std.testing.expectEqualStrings("new line 6", ui.diff_lines.items[3].content);
    try std.testing.expect(ui.diff_lines.items[3].old_content != null);
    try std.testing.expectEqualStrings("old line 6", ui.diff_lines.items[3].old_content.?);

    // Lines 7, 8, 9 should be context (after the change)
    try std.testing.expectEqual(ui.diff_lines.items[4].new_line_num, 7);
    try std.testing.expect(ui.diff_lines.items[4].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[5].new_line_num, 8);
    try std.testing.expect(ui.diff_lines.items[5].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[6].new_line_num, 9);
    try std.testing.expect(ui.diff_lines.items[6].line_type == .context);
}

test "context lines handle file boundaries" {
    const allocator = std.testing.allocator;

    // Create a diff with changes near the start of the file
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Add a modified line at difft line 1 (0-based) = display line 2 (1-based)
    try chunk_entries.append(allocator, .{
        .lhs = .{
            .line_number = 1,
            .changes = &.{},
        },
        .rhs = .{
            .line_number = 1,
            .changes = &.{},
        },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    // Create content with 5 lines
    const old_content = "line 1\nold line 2\nline 3\nline 4\nline 5";
    const new_content = "line 1\nnew line 2\nline 3\nline 4\nline 5";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // difft line 1 (0-based) = display line 2
    // context_start = max(1, 2 - 3) = 1
    // Should have: 1 context line before (line 1), 1 modification line for line 2, 3 context lines after (3-5)
    // Total: 1 + 1 + 3 = 5 lines
    try std.testing.expect(ui.diff_lines.items.len == 5);

    try std.testing.expectEqual(ui.diff_lines.items[0].new_line_num, 1);
    try std.testing.expect(ui.diff_lines.items[0].line_type == .context);

    // Modification has both line numbers
    try std.testing.expectEqual(ui.diff_lines.items[1].old_line_num, 2);
    try std.testing.expectEqual(ui.diff_lines.items[1].new_line_num, 2);
    try std.testing.expect(ui.diff_lines.items[1].line_type == .modification);
    try std.testing.expectEqualStrings("new line 2", ui.diff_lines.items[1].content);
    try std.testing.expect(ui.diff_lines.items[1].old_content != null);
    try std.testing.expectEqualStrings("old line 2", ui.diff_lines.items[1].old_content.?);

    try std.testing.expectEqual(ui.diff_lines.items[2].new_line_num, 3);
    try std.testing.expect(ui.diff_lines.items[2].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[3].new_line_num, 4);
    try std.testing.expect(ui.diff_lines.items[3].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[4].new_line_num, 5);
    try std.testing.expect(ui.diff_lines.items[4].line_type == .context);
}

test "separator shown between distant chunks" {
    const allocator = std.testing.allocator;

    // Create two chunks far apart
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk1_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk1_entries.deinit(allocator);

    var chunk2_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk2_entries.deinit(allocator);

    // First chunk at line 5
    try chunk1_entries.append(allocator, .{
        .lhs = .{ .line_number = 5, .changes = &.{} },
        .rhs = .{ .line_number = 5, .changes = &.{} },
    });

    // Second chunk at line 50 (far away)
    try chunk2_entries.append(allocator, .{
        .lhs = .{ .line_number = 50, .changes = &.{} },
        .rhs = .{ .line_number = 50, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk1_entries.toOwnedSlice(allocator));
    try chunks.append(allocator, try chunk2_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    // Create content with 60 lines
    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(allocator);
    for (0..60) |_| {
        try content_buf.appendSlice(allocator, "line content\n");
    }
    const content = try allocator.dupe(u8, content_buf.items);
    defer allocator.free(content);

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, content),
        .new_content = try allocator.dupe(u8, content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Should have:
    // - Lines 2-4 (context before first chunk)
    // - Line 5 (first chunk)
    // - Lines 6-8 (context after first chunk)
    // - "..." (separator)
    // - Lines 47-49 (context before second chunk)
    // - Line 50 (second chunk)
    // - Lines 51-53 (context after second chunk)
    // Total: 14 lines

    var separator_found = false;
    for (ui.diff_lines.items) |line| {
        if (line.old_line_num == null and line.new_line_num == null and std.mem.eql(u8, line.content, "...")) {
            separator_found = true;
            break;
        }
    }

    try std.testing.expect(separator_found);
}

test "partial file deletion shows content" {
    const allocator = std.testing.allocator;

    // Create a file with a deletion in the middle
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Add a deletion at difft line 5 (0-based) = display line 6 (1-based)
    // old file has it at index 5, new file doesn't
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 5, .changes = &.{} },
        .rhs = null,
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    // Old file: 7 lines (indices 0-6), line at index 5 is "deleted line"
    const old_content = "line 1\nline 2\nline 3\nline 4\nline 5\ndeleted line\nline 7";
    const new_content = "line 1\nline 2\nline 3\nline 4\nline 5\nline 7";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the deletion line (difft line 5 = display line 6)
    var deletion_found = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion or line.line_type == .modification and line.new_line_num == 6 or line.old_line_num == 6) {
            deletion_found = true;
            // Verify it has content
            try std.testing.expectEqualStrings("deleted line", line.content);
            break;
        }
    }

    try std.testing.expect(deletion_found);
}

test "deleted comment line shows content" {
    const allocator = std.testing.allocator;

    // Create a file with a deleted comment line
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Add a deletion of comment line at difft line 2 (0-based) = display line 3 (1-based)
    // old_content index 2 is "// comment line"
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 2, .changes = &.{} },
        .rhs = null,
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "line 1\nline 2\n// comment line\nline 4";
    const new_content = "line 1\nline 2\nline 4";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the deletion line (difft line 2 = display line 3)
    var deletion_found = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion or line.line_type == .modification and line.new_line_num == 3 or line.old_line_num == 3) {
            deletion_found = true;
            // Verify it has the comment content
            try std.testing.expectEqualStrings("// comment line", line.content);
            break;
        }
    }

    try std.testing.expect(deletion_found);
}

test "blank line deletion shows empty content" {
    const allocator = std.testing.allocator;

    // Create a file with a blank line deletion
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Add a deletion of blank line at difft line 2 (0-based) = display line 3 (1-based)
    // old_content index 2 is "" (blank line)
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 2, .changes = &.{} },
        .rhs = null,
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "line 1\nline 2\n\nline 4";
    const new_content = "line 1\nline 2\nline 4";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the deletion line (difft line 2 = display line 3, should be empty string for blank line)
    var deletion_found = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion or line.line_type == .modification and line.new_line_num == 3 or line.old_line_num == 3) {
            deletion_found = true;
            // Blank line deletion should have empty content
            try std.testing.expectEqualStrings("", line.content);
            break;
        }
    }

    try std.testing.expect(deletion_found);
}

test "modified line shows both deletion and addition" {
    const allocator = std.testing.allocator;

    // Create a file with a modified line (both lhs and rhs present)
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Add a modified line at line 5 (0-based index from difft)
    // This represents line 6 in the display (1-based)
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 5, .changes = &.{} },
        .rhs = .{ .line_number = 5, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "line 1\nline 2\nline 3\nline 4\nline 5\nold content here\nline 7\nline 8\nline 9\nline 10";
    const new_content = "line 1\nline 2\nline 3\nline 4\nline 5\nnew content here\nline 7\nline 8\nline 9\nline 10";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Modified lines now show as a unified modification with both old and new content
    var found_modification = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification) {
            found_modification = true;
            // New content is in .content, old content is in .old_content
            try std.testing.expectEqualStrings("new content here", line.content);
            try std.testing.expect(line.old_content != null);
            try std.testing.expectEqualStrings("old content here", line.old_content.?);
            try std.testing.expectEqual(line.old_line_num, 6);
            try std.testing.expectEqual(line.new_line_num, 6);
        }
    }

    try std.testing.expect(found_modification);
}

test "context lines use correct 1-based line numbers" {
    const allocator = std.testing.allocator;

    // Create a diff with a change at line index 7 (0-based from difft)
    // This is display line 8, so context should show lines 5, 6, 7 before
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // difft uses 0-based line numbers, so line_number=7 means the 8th line
    try chunk_entries.append(allocator, .{
        .lhs = null,
        .rhs = .{ .line_number = 7, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    // Create content with 12 lines (0-indexed: 0-11, display: 1-12)
    const old_content = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 9\nline 10\nline 11\nline 12";
    const new_content = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nnew line 8\nline 9\nline 10\nline 11\nline 12";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // The change is at display line 8 (0-based index 7)
    // Context before should be lines 5, 6, 7 (display numbers)
    // Context after should be lines 9, 10, 11 (display numbers)

    // Check that line 5, 6, 7 are shown as context before
    var found_line_5 = false;
    var found_line_6 = false;
    var found_line_7 = false;
    var found_line_8_addition = false;

    for (ui.diff_lines.items) |line| {
        if (line.new_line_num orelse line.old_line_num) |num| {
            if (num == 5 and line.line_type == .context) found_line_5 = true;
            if (num == 6 and line.line_type == .context) found_line_6 = true;
            if (num == 7 and line.line_type == .context) found_line_7 = true;
            if (num == 8 and line.line_type == .addition) found_line_8_addition = true;
        }
    }

    try std.testing.expect(found_line_5); // Context line 5 should be present
    try std.testing.expect(found_line_6); // Context line 6 should be present
    try std.testing.expect(found_line_7); // Context line 7 should be present
    try std.testing.expect(found_line_8_addition); // The addition at line 8 should be present
}

test "separator lines are not selectable" {
    const allocator = std.testing.allocator;

    // Create a diff with a separator line
    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk1_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk1_entries.deinit(allocator);

    var chunk2_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk2_entries.deinit(allocator);

    // First chunk at line 5
    try chunk1_entries.append(allocator, .{
        .lhs = .{ .line_number = 5, .changes = &.{} },
        .rhs = .{ .line_number = 5, .changes = &.{} },
    });

    // Second chunk at line 50
    try chunk2_entries.append(allocator, .{
        .lhs = .{ .line_number = 50, .changes = &.{} },
        .rhs = .{ .line_number = 50, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk1_entries.toOwnedSlice(allocator));
    try chunks.append(allocator, try chunk2_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(allocator);
    for (0..60) |_| {
        try content_buf.appendSlice(allocator, "line content\n");
    }
    const content = try allocator.dupe(u8, content_buf.items);
    defer allocator.free(content);

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, content),
        .new_content = try allocator.dupe(u8, content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the separator line
    var separator_idx: ?usize = null;
    for (ui.diff_lines.items, 0..) |line, i| {
        if (line.old_line_num == null and line.new_line_num == null and std.mem.eql(u8, line.content, "...")) {
            separator_idx = i;
            break;
        }
    }

    try std.testing.expect(separator_idx != null);

    // Verify the separator is marked as non-selectable
    try std.testing.expect(!ui.diff_lines.items[separator_idx.?].selectable);
}

test "computeDeletedRange finds correct deleted portion" {
    // Test case 1: suffix removed
    {
        const result = computeDeletedRange("Hello world, extra stuff", "Hello world");
        // Common prefix: "Hello world" (11 chars)
        // Common suffix: none (old ends with "f", new ends with "d")
        // Deleted: ", extra stuff" from position 11 to 24
        try std.testing.expectEqual(@as(u32, 11), result.start);
        try std.testing.expectEqual(@as(u32, 24), result.end);
    }

    // Test case 2: deletion in the middle
    {
        const result = computeDeletedRange("Hello beautiful world", "Hello world");
        // Common prefix: "Hello " (6 chars)
        // Common suffix: "world" (5 chars)
        // Deleted: "beautiful " (10 chars) from position 6 to 16
        try std.testing.expectEqual(@as(u32, 6), result.start);
        try std.testing.expectEqual(@as(u32, 16), result.end);
    }

    // Test case 3: no change
    {
        const result = computeDeletedRange("same content", "same content");
        // No deletion - start should equal end
        try std.testing.expectEqual(result.start, result.end);
    }

    // Test case 4: entire line deleted (new is empty)
    {
        const result = computeDeletedRange("deleted line", "");
        try std.testing.expectEqual(@as(u32, 0), result.start);
        try std.testing.expectEqual(@as(u32, 12), result.end);
    }
}

test "computeAddedRange finds correct added portion" {
    // Test case 1: suffix added
    {
        const result = computeAddedRange("Hello world", "Hello world, extra stuff");
        // Common prefix: "Hello world" (11 chars)
        // Common suffix: none
        // Added: ", extra stuff" from position 11 to 24
        try std.testing.expectEqual(@as(u32, 11), result.start);
        try std.testing.expectEqual(@as(u32, 24), result.end);
    }

    // Test case 2: addition in the middle
    {
        const result = computeAddedRange("Hello world", "Hello beautiful world");
        // Common prefix: "Hello " (6 chars)
        // Common suffix: "world" (5 chars)
        // Added: "beautiful " (10 chars) from position 6 to 16
        try std.testing.expectEqual(@as(u32, 6), result.start);
        try std.testing.expectEqual(@as(u32, 16), result.end);
    }

    // Test case 3: no change
    {
        const result = computeAddedRange("same content", "same content");
        // No addition - start should equal end
        try std.testing.expectEqual(result.start, result.end);
    }

    // Test case 4: entire line added (old is empty)
    {
        const result = computeAddedRange("", "added line");
        try std.testing.expectEqual(@as(u32, 0), result.start);
        try std.testing.expectEqual(@as(u32, 10), result.end);
    }
}

test "modified line with partial change has correct changes arrays" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Add a modified line
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = &.{} },
        .rhs = .{ .line_number = 0, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    // Old line has extra content at the end that was deleted
    const old_content = "Hello world, this part was deleted";
    const new_content = "Hello world";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui_instance = UI.initForTest(allocator, &session);
    defer ui_instance.deinit();

    try ui_instance.buildDiffLines();

    // Should have at least one modification line
    try std.testing.expect(ui_instance.diff_lines.items.len >= 1);

    // Find the modification line
    var found_modification = false;
    for (ui_instance.diff_lines.items) |line| {
        if (line.line_type == .modification and line.old_line_num == 1 and line.new_line_num == 1) {
            found_modification = true;
            // New content should be the shortened line
            try std.testing.expectEqualStrings("Hello world", line.content);
            // Old content should be the original longer line
            try std.testing.expect(line.old_content != null);
            try std.testing.expectEqualStrings("Hello world, this part was deleted", line.old_content.?);
        }
    }
    try std.testing.expect(found_modification);
}

test "identical lines are skipped (no false positives)" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Add an entry where difft reports a change but content is identical
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 2, .changes = &.{} },
        .rhs = .{ .line_number = 2, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "file.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    // Both old and new have identical content
    const content = "line 1\nline 2\nidentical line\nline 4\nline 5";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "file.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, content),
        .new_content = try allocator.dupe(u8, content),
    });

    var ui_instance = UI.initForTest(allocator, &session);
    defer ui_instance.deinit();

    try ui_instance.buildDiffLines();

    // Should NOT have any deletion or addition lines for the "identical line"
    // because old_content == new_content for that line
    for (ui_instance.diff_lines.items) |line| {
        if (line.new_line_num == 3 or line.old_line_num == 3) { // display line 3 = index 2
            // If this line appears, it should only be context, not deletion/addition
            try std.testing.expect(line.line_type == .context);
        }
    }
}

test "binary file produces no diff lines" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "binary.png"),
        .language = try allocator.dupe(u8, "Image"),
        .status = .changed,
        .chunks = &.{},
        .allocator = allocator,
    };

    // Binary file content (contains null byte)
    const content = "PNG\x00binary data";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "binary.png"),
        .diff = file_diff,
        .is_binary = true, // Marked as binary
        .old_content = try allocator.dupe(u8, content),
        .new_content = try allocator.dupe(u8, content),
    });

    var ui_instance = UI.initForTest(allocator, &session);
    defer ui_instance.deinit();

    try ui_instance.buildDiffLines();

    // Binary files should produce no diff lines
    try std.testing.expectEqual(@as(usize, 0), ui_instance.diff_lines.items.len);
}

// =============================================================================
// Complex difftastic-style test cases
// =============================================================================

test "difftastic semantic changes: use difft's character-level changes" {
    // This test verifies that we use difftastic's semantic change highlighting
    // instead of computing our own basic text diff
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Create changes that difft would provide - specific semantic tokens
    // Example: changing variable name from "x" to "a" in "const x = 10;"
    // difft would highlight only the "x" -> "a" portion, not the whole line
    const lhs_changes = try allocator.alloc(difft.Change, 1);
    lhs_changes[0] = .{
        .start = 6, // "x" starts at position 6
        .end = 7, // "x" ends at position 7
        .content = try allocator.dupe(u8, "x"),
        .highlight = .novel,
    };

    const rhs_changes = try allocator.alloc(difft.Change, 1);
    rhs_changes[0] = .{
        .start = 6, // "a" starts at position 6
        .end = 7, // "a" ends at position 7
        .content = try allocator.dupe(u8, "a"),
        .highlight = .novel,
    };

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = lhs_changes },
        .rhs = .{ .line_number = 0, .changes = rhs_changes },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "const x = 10;";
    const new_content = "const a = 10;";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Should have at least one line (modification)
    try std.testing.expect(ui.diff_lines.items.len >= 1);

    // Find the modification line and verify it uses difft's changes
    var found_modification = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification and line.old_line_num == 1 and line.new_line_num == 1) {
            found_modification = true;
            // New content should be "const a = 10;"
            try std.testing.expectEqualStrings("const a = 10;", line.content);
            // Old content should be "const x = 10;"
            try std.testing.expect(line.old_content != null);
            try std.testing.expectEqualStrings("const x = 10;", line.old_content.?);
            // Should use difft's semantic change highlighting (position 6-7 for the changed char)
            try std.testing.expect(line.changes.len >= 1);
            try std.testing.expectEqual(@as(u32, 6), line.changes[0].start);
            try std.testing.expectEqual(@as(u32, 7), line.changes[0].end);
        }
    }

    try std.testing.expect(found_modification);
}

test "difftastic: multiple semantic changes on same line" {
    // Test case: multiple variable name changes on the same line
    // Old: "let result = x + y;"
    // New: "let sum = a + b;"
    // difft would highlight: "result" -> "sum", "x" -> "a", "y" -> "b"
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Create changes that difft would provide
    const lhs_changes = try allocator.alloc(difft.Change, 3);
    lhs_changes[0] = .{ .start = 4, .end = 10, .content = try allocator.dupe(u8, "result"), .highlight = .novel };
    lhs_changes[1] = .{ .start = 13, .end = 14, .content = try allocator.dupe(u8, "x"), .highlight = .novel };
    lhs_changes[2] = .{ .start = 17, .end = 18, .content = try allocator.dupe(u8, "y"), .highlight = .novel };

    const rhs_changes = try allocator.alloc(difft.Change, 3);
    rhs_changes[0] = .{ .start = 4, .end = 7, .content = try allocator.dupe(u8, "sum"), .highlight = .novel };
    rhs_changes[1] = .{ .start = 10, .end = 11, .content = try allocator.dupe(u8, "a"), .highlight = .novel };
    rhs_changes[2] = .{ .start = 14, .end = 15, .content = try allocator.dupe(u8, "b"), .highlight = .novel };

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = lhs_changes },
        .rhs = .{ .line_number = 0, .changes = rhs_changes },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "let result = x + y;";
    const new_content = "let sum = a + b;";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the modification line and verify it has the changes
    var found_modification = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification and line.old_line_num == 1 and line.new_line_num == 1) {
            found_modification = true;
            // New content changes should have 3 separate highlights
            try std.testing.expectEqual(@as(usize, 3), line.changes.len);
            // First change: "sum" at position 4-7
            try std.testing.expectEqual(@as(u32, 4), line.changes[0].start);
            try std.testing.expectEqual(@as(u32, 7), line.changes[0].end);

            // Old content changes should also have 3 separate highlights
            try std.testing.expectEqual(@as(usize, 3), line.old_changes.len);
            // First change: "result" at position 4-10
            try std.testing.expectEqual(@as(u32, 4), line.old_changes[0].start);
            try std.testing.expectEqual(@as(u32, 10), line.old_changes[0].end);
        }
    }
    try std.testing.expect(found_modification);
}

test "difftastic: line moved to different position (asymmetric line numbers)" {
    // Test case where lhs and rhs have different line numbers
    // This happens when lines are inserted/deleted above the change
    // Old file line 3 corresponds to new file line 5
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const lhs_changes = try allocator.alloc(difft.Change, 1);
    lhs_changes[0] = .{ .start = 0, .end = 5, .content = try allocator.dupe(u8, "hello"), .highlight = .novel };

    const rhs_changes = try allocator.alloc(difft.Change, 1);
    rhs_changes[0] = .{ .start = 0, .end = 5, .content = try allocator.dupe(u8, "world"), .highlight = .novel };

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // lhs line 2 (0-based) corresponds to rhs line 4 (0-based)
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 2, .changes = lhs_changes },
        .rhs = .{ .line_number = 4, .changes = rhs_changes },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    // Old content has "hello" at line 3 (index 2)
    const old_content = "line1\nline2\nhello\nline4";
    // New content has "world" at line 5 (index 4) due to inserted lines
    const new_content = "line1\nline2\nnew1\nnew2\nworld\nline4";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // With unified modifications, even asymmetric line numbers get combined
    // The modification shows old content "hello" becoming "world"
    var found_modification = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification) {
            found_modification = true;
            try std.testing.expectEqualStrings("world", line.content);
            try std.testing.expect(line.old_content != null);
            try std.testing.expectEqualStrings("hello", line.old_content.?);
            // Old line was 3 (0-based 2 + 1), new line is 5 (0-based 4 + 1)
            try std.testing.expectEqual(@as(u32, 3), line.old_line_num.?);
            try std.testing.expectEqual(@as(u32, 5), line.new_line_num.?);
        }
    }

    try std.testing.expect(found_modification);
}

test "difftastic: pure addition (rhs only)" {
    // Test case where difft reports only rhs (new line added)
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const rhs_changes = try allocator.alloc(difft.Change, 1);
    rhs_changes[0] = .{
        .start = 0,
        .end = 18,
        .content = try allocator.dupe(u8, "// new comment line"),
        .highlight = .novel,
    };

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Only rhs - this is a pure addition
    try chunk_entries.append(allocator, .{
        .lhs = null,
        .rhs = .{ .line_number = 1, .changes = rhs_changes },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "line1\nline3";
    const new_content = "line1\n// new comment line\nline3";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the addition and verify it uses difft's changes
    var found_addition = false;
    for (ui.diff_lines.items) |line| {
        if ((line.line_type == .addition or line.line_type == .modification) and (line.new_line_num == 2)) {
            found_addition = true;
            try std.testing.expectEqualStrings("// new comment line", line.content);
            // Should use difft's provided changes
            try std.testing.expectEqual(@as(usize, 1), line.changes.len);
        }
    }
    try std.testing.expect(found_addition);
}

test "difftastic: pure deletion (lhs only)" {
    // Test case where difft reports only lhs (old line removed)
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const lhs_changes = try allocator.alloc(difft.Change, 1);
    lhs_changes[0] = .{
        .start = 0,
        .end = 22,
        .content = try allocator.dupe(u8, "// deleted comment line"),
        .highlight = .novel,
    };

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Only lhs - this is a pure deletion
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 1, .changes = lhs_changes },
        .rhs = null,
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "line1\n// deleted comment line\nline3";
    const new_content = "line1\nline3";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the deletion and verify it uses difft's changes
    var found_deletion = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion or line.line_type == .modification and line.new_line_num == 2 or line.old_line_num == 2) {
            found_deletion = true;
            try std.testing.expectEqualStrings("// deleted comment line", line.content);
            // Should use difft's provided changes
            try std.testing.expectEqual(@as(usize, 1), line.changes.len);
        }
    }
    try std.testing.expect(found_deletion);
}

test "difftastic: mixed operations in single chunk" {
    // Complex case: one chunk contains additions, deletions, and modifications
    // This mimics real difftastic output like:
    // - Line 1: modified (lhs + rhs)
    // - Line 2: deleted (lhs only)
    // - Line 3: added (rhs only)
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Entry 1: Modified line (both lhs and rhs at line 0)
    const mod_lhs_changes = try allocator.alloc(difft.Change, 1);
    mod_lhs_changes[0] = .{ .start = 0, .end = 3, .content = try allocator.dupe(u8, "old"), .highlight = .novel };
    const mod_rhs_changes = try allocator.alloc(difft.Change, 1);
    mod_rhs_changes[0] = .{ .start = 0, .end = 3, .content = try allocator.dupe(u8, "new"), .highlight = .novel };

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = mod_lhs_changes },
        .rhs = .{ .line_number = 0, .changes = mod_rhs_changes },
    });

    // Entry 2: Deleted line (only lhs at line 1)
    const del_lhs_changes = try allocator.alloc(difft.Change, 1);
    del_lhs_changes[0] = .{ .start = 0, .end = 12, .content = try allocator.dupe(u8, "deleted line"), .highlight = .novel };

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 1, .changes = del_lhs_changes },
        .rhs = null,
    });

    // Entry 3: Added line (only rhs at line 1)
    const add_rhs_changes = try allocator.alloc(difft.Change, 1);
    add_rhs_changes[0] = .{ .start = 0, .end = 10, .content = try allocator.dupe(u8, "added line"), .highlight = .novel };

    try chunk_entries.append(allocator, .{
        .lhs = null,
        .rhs = .{ .line_number = 1, .changes = add_rhs_changes },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "old text\ndeleted line\nend";
    const new_content = "new text\nadded line\nend";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Count the different types of lines
    var deletion_count: usize = 0;
    var addition_count: usize = 0;
    var modification_count: usize = 0;

    for (ui.diff_lines.items) |line| {
        switch (line.line_type) {
            .deletion => deletion_count += 1,
            .addition => addition_count += 1,
            .modification => modification_count += 1,
            .context => {},
        }
    }

    // With unified modifications, we should have:
    // - 1 modification (the modified line is now unified)
    // - 1 deletion (pure deletion)
    // - 1 addition (pure addition)
    try std.testing.expectEqual(@as(usize, 1), modification_count);
    try std.testing.expectEqual(@as(usize, 1), deletion_count);
    try std.testing.expectEqual(@as(usize, 1), addition_count);
}

test "isPartialChange detects partial changes correctly" {
    // Test isPartialChange helper function
    const content = "Hello, world!"; // 13 chars

    // Full line change (0 to 13)
    const full_change = [_]difft.Change{.{
        .start = 0,
        .end = 13,
        .content = "",
        .highlight = .novel,
    }};
    try std.testing.expect(!isPartialChange(content, &full_change));

    // Partial change at start (0 to 5)
    const start_change = [_]difft.Change{.{
        .start = 0,
        .end = 5,
        .content = "",
        .highlight = .novel,
    }};
    try std.testing.expect(isPartialChange(content, &start_change));

    // Partial change in middle (5 to 10)
    const middle_change = [_]difft.Change{.{
        .start = 5,
        .end = 10,
        .content = "",
        .highlight = .novel,
    }};
    try std.testing.expect(isPartialChange(content, &middle_change));

    // Partial change at end (10 to 13)
    const end_change = [_]difft.Change{.{
        .start = 10,
        .end = 13,
        .content = "",
        .highlight = .novel,
    }};
    try std.testing.expect(isPartialChange(content, &end_change));

    // Multiple changes covering the whole line
    const multi_changes = [_]difft.Change{
        .{ .start = 0, .end = 5, .content = "", .highlight = .novel },
        .{ .start = 5, .end = 13, .content = "", .highlight = .novel },
    };
    try std.testing.expect(!isPartialChange(content, &multi_changes));

    // Empty changes array
    const empty_changes: []const difft.Change = &.{};
    try std.testing.expect(!isPartialChange(content, empty_changes));
}

test "unicode content handling" {
    // Test that unicode characters are handled correctly
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const lhs_changes = try allocator.alloc(difft.Change, 1);
    lhs_changes[0] = .{ .start = 0, .end = 5, .content = try allocator.dupe(u8, "hello"), .highlight = .novel };

    const rhs_changes = try allocator.alloc(difft.Change, 1);
    rhs_changes[0] = .{ .start = 0, .end = 5, .content = try allocator.dupe(u8, "héllo"), .highlight = .novel };

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = lhs_changes },
        .rhs = .{ .line_number = 0, .changes = rhs_changes },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "hello world 日本語";
    const new_content = "héllo world 日本語";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Should have a modification with old_content="hello..." and content="héllo..."
    var found_modification = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification) {
            found_modification = true;
            // New content should have "héllo"
            try std.testing.expect(std.mem.indexOf(u8, line.content, "héllo") != null);
            // Old content should have "hello"
            try std.testing.expect(line.old_content != null);
            try std.testing.expect(std.mem.indexOf(u8, line.old_content.?, "hello") != null);
        }
    }

    try std.testing.expect(found_modification);
}

test "empty file to non-empty file" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "new_file.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .added,
        .chunks = &.{},
        .allocator = allocator,
    };

    const old_content = "";
    const new_content = "line1\nline2\nline3";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "new_file.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // All lines should be additions
    try std.testing.expectEqual(@as(usize, 3), ui.diff_lines.items.len);
    for (ui.diff_lines.items) |line| {
        try std.testing.expect(line.line_type == .addition);
    }
}

test "non-empty file to empty file" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "deleted_file.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .removed,
        .chunks = &.{},
        .allocator = allocator,
    };

    const old_content = "line1\nline2\nline3";
    const new_content = "";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "deleted_file.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // All lines should be deletions
    try std.testing.expectEqual(@as(usize, 3), ui.diff_lines.items.len);
    for (ui.diff_lines.items) |line| {
        try std.testing.expect(line.line_type == .deletion or line.line_type == .modification);
    }
}

test "whitespace-only changes" {
    // Test handling of whitespace changes (tabs, spaces)
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const lhs_changes = try allocator.alloc(difft.Change, 1);
    lhs_changes[0] = .{ .start = 0, .end = 4, .content = try allocator.dupe(u8, "    "), .highlight = .novel }; // 4 spaces

    const rhs_changes = try allocator.alloc(difft.Change, 1);
    rhs_changes[0] = .{ .start = 0, .end = 1, .content = try allocator.dupe(u8, "\t"), .highlight = .novel }; // 1 tab

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = lhs_changes },
        .rhs = .{ .line_number = 0, .changes = rhs_changes },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "    indented";
    const new_content = "\tindented";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Should have a modification
    var found_modification = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification) {
            found_modification = true;
            // New content should start with tab
            try std.testing.expect(std.mem.startsWith(u8, line.content, "\t"));
            // Old content should start with 4 spaces
            try std.testing.expect(line.old_content != null);
            try std.testing.expect(std.mem.startsWith(u8, line.old_content.?, "    "));
        }
    }

    try std.testing.expect(found_modification);
}

test "very long lines" {
    // Test handling of very long lines
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    // Create a very long line (1000 chars)
    var long_line_buf: [1000]u8 = undefined;
    @memset(&long_line_buf, 'x');

    var new_line_buf: [1000]u8 = undefined;
    @memset(&new_line_buf, 'y');

    const old_content = try allocator.dupe(u8, &long_line_buf);
    defer allocator.free(old_content);
    const new_content = try allocator.dupe(u8, &new_line_buf);
    defer allocator.free(new_content);

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = &.{} },
        .rhs = .{ .line_number = 0, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "long.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    try session.addFile(.{
        .path = try allocator.dupe(u8, "long.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Should have a modification
    var found_modification = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification) {
            found_modification = true;
            // New content (1000 y's)
            try std.testing.expectEqual(@as(usize, 1000), line.content.len);
            // Old content (1000 x's)
            try std.testing.expect(line.old_content != null);
            try std.testing.expectEqual(@as(usize, 1000), line.old_content.?.len);
        }
    }

    try std.testing.expect(found_modification);
}

// =============================================================================
// Inline diff tests - verify unchanged/deleted/added parts are identified correctly
// =============================================================================

test "inline diff: addition at end of line" {
    // Test that adding content at the end shows prefix as unchanged
    // Old: "$ zig build"
    // New: "$ zig build  # Build the binary"
    // Expected: "$ zig build" unchanged (gray), "  # Build the binary" added (green)
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = &.{} },
        .rhs = .{ .line_number = 0, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "$ zig build";
    const new_content = "$ zig build  # Build the binary";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the modification line
    var found_modification = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification) {
            found_modification = true;
            // The modification should have both old and new content
            try std.testing.expectEqualStrings("$ zig build  # Build the binary", line.content);
            try std.testing.expect(line.old_content != null);
            try std.testing.expectEqualStrings("$ zig build", line.old_content.?);
        }
    }
    try std.testing.expect(found_modification);
}

test "inline diff: modification in middle of line" {
    // Test that changing content in the middle shows prefix and suffix as unchanged
    // Old: "const x = 10;"
    // New: "const y = 10;"
    // Expected: "const " unchanged, "x" deleted, "y" added, " = 10;" unchanged
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = &.{} },
        .rhs = .{ .line_number = 0, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "const x = 10;";
    const new_content = "const y = 10;";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the modification line and verify structure
    var found_modification = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification) {
            found_modification = true;
            try std.testing.expectEqualStrings("const y = 10;", line.content);
            try std.testing.expect(line.old_content != null);
            try std.testing.expectEqualStrings("const x = 10;", line.old_content.?);
            // Both lines have same length, only 1 char differs at position 6
        }
    }
    try std.testing.expect(found_modification);
}

test "inline diff: deletion at beginning of line" {
    // Test that removing content from the beginning shows suffix as unchanged
    // Old: "    indented line"
    // New: "indented line"
    // Expected: "    " deleted, "indented line" unchanged
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 0, .changes = &.{} },
        .rhs = .{ .line_number = 0, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "    indented line";
    const new_content = "indented line";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    var found_modification = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification) {
            found_modification = true;
            try std.testing.expectEqualStrings("indented line", line.content);
            try std.testing.expect(line.old_content != null);
            try std.testing.expectEqualStrings("    indented line", line.old_content.?);
        }
    }
    try std.testing.expect(found_modification);
}

// =============================================================================
// Line number offset tests - verify old/new line numbers track correctly
// =============================================================================

test "line numbers: additions shift subsequent line numbers" {
    // When lines are added, context lines after should show different old/new numbers
    // Old file: line1, line2, line3
    // New file: line1, NEW_LINE, line2, line3
    // After the addition, "line2" should show old=2, new=3
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Addition at line 2 (0-based: 1)
    try chunk_entries.append(allocator, .{
        .lhs = null,
        .rhs = .{ .line_number = 1, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "line1\nline2\nline3\nline4\nline5";
    const new_content = "line1\nNEW_LINE\nline2\nline3\nline4\nline5";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Check that the addition is at new line 2
    var found_addition = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .addition and line.new_line_num == 2) {
            found_addition = true;
            try std.testing.expectEqualStrings("NEW_LINE", line.content);
            try std.testing.expect(line.old_line_num == null); // Addition has no old line
        }
    }
    try std.testing.expect(found_addition);

    // Check context lines after the addition have offset line numbers
    // "line2" content should be at old=2, new=3
    var found_line2_context = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .context and std.mem.eql(u8, line.content, "line2")) {
            found_line2_context = true;
            try std.testing.expectEqual(@as(u32, 2), line.old_line_num.?);
            try std.testing.expectEqual(@as(u32, 3), line.new_line_num.?);
        }
    }
    try std.testing.expect(found_line2_context);
}

test "line numbers: deletions shift subsequent line numbers" {
    // When lines are deleted, context lines after should show different old/new numbers
    // Old file: line1, DELETED, line2, line3
    // New file: line1, line2, line3
    // After the deletion, "line2" should show old=3, new=2
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Deletion at old line 2 (0-based: 1)
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 1, .changes = &.{} },
        .rhs = null,
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "line1\nDELETED\nline2\nline3\nline4\nline5";
    const new_content = "line1\nline2\nline3\nline4\nline5";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Check that the deletion is at old line 2
    var found_deletion = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion and line.old_line_num == 2) {
            found_deletion = true;
            try std.testing.expectEqualStrings("DELETED", line.content);
            try std.testing.expect(line.new_line_num == null); // Deletion has no new line
        }
    }
    try std.testing.expect(found_deletion);
}

test "line numbers: multiple additions accumulate offset" {
    // Multiple additions should accumulate the offset
    // Old file: line1, line2
    // New file: line1, NEW1, NEW2, line2
    // "line2" should show old=2, new=4 (offset of 2)
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Two additions at lines 2 and 3 (0-based: 1 and 2)
    try chunk_entries.append(allocator, .{
        .lhs = null,
        .rhs = .{ .line_number = 1, .changes = &.{} },
    });
    try chunk_entries.append(allocator, .{
        .lhs = null,
        .rhs = .{ .line_number = 2, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "line1\nline2\nline3\nline4\nline5";
    const new_content = "line1\nNEW1\nNEW2\nline2\nline3\nline4\nline5";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Check that additions are present
    var addition_count: usize = 0;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .addition) {
            addition_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), addition_count);

    // Check context line "line2" has correct offset (old=2, new=4)
    var found_line2 = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .context and std.mem.eql(u8, line.content, "line2")) {
            found_line2 = true;
            try std.testing.expectEqual(@as(u32, 2), line.old_line_num.?);
            try std.testing.expectEqual(@as(u32, 4), line.new_line_num.?);
        }
    }
    try std.testing.expect(found_line2);
}

test "line numbers: modification preserves line mapping" {
    // A modification (same line changed) should update offset based on actual positions
    // Old file line 3: "old content"
    // New file line 5: "new content" (due to additions above)
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    var chunk_entries: std.ArrayList(difft.DiffEntry) = .empty;
    defer chunk_entries.deinit(allocator);

    // Modification: old line 2 (0-based) maps to new line 4 (0-based)
    try chunk_entries.append(allocator, .{
        .lhs = .{ .line_number = 2, .changes = &.{} },
        .rhs = .{ .line_number = 4, .changes = &.{} },
    });

    var chunks: std.ArrayList([]const difft.DiffEntry) = .empty;
    defer chunks.deinit(allocator);
    try chunks.append(allocator, try chunk_entries.toOwnedSlice(allocator));

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.txt"),
        .language = try allocator.dupe(u8, "Text"),
        .status = .changed,
        .chunks = try chunks.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    const old_content = "line1\nline2\nold content\nline4";
    const new_content = "line1\nline2\nnew1\nnew2\nnew content\nline4";

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.txt"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, old_content),
        .new_content = try allocator.dupe(u8, new_content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Find the modification and verify line numbers
    var found_modification = false;
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .modification) {
            found_modification = true;
            // Old line 3 (1-based), new line 5 (1-based)
            try std.testing.expectEqual(@as(u32, 3), line.old_line_num.?);
            try std.testing.expectEqual(@as(u32, 5), line.new_line_num.?);
        }
    }
    try std.testing.expect(found_modification);
}

test "split view: deleted file shows content on left side" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "test.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .removed,
        .chunks = &.{},
        .allocator = allocator,
    };

    try session.addFile(.{
        .path = try allocator.dupe(u8, "test.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, "line 1\nline 2"),
        .new_content = try allocator.dupe(u8, ""),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Verify split rows are built correctly
    try std.testing.expectEqual(@as(usize, 2), ui.split_rows.items.len);

    // Row 1: deletion on left, empty on right
    try std.testing.expect(ui.split_rows.items[0].left != null);
    try std.testing.expect(ui.split_rows.items[0].right == null);
    try std.testing.expectEqual(@as(u32, 1), ui.split_rows.items[0].left.?.line_num);
    try std.testing.expectEqualStrings("line 1", ui.split_rows.items[0].left.?.content);
    try std.testing.expectEqual(DiffLine.LineType.deletion, ui.split_rows.items[0].left.?.line_type);

    // Row 2: deletion on left, empty on right
    try std.testing.expect(ui.split_rows.items[1].left != null);
    try std.testing.expect(ui.split_rows.items[1].right == null);
    try std.testing.expectEqual(@as(u32, 2), ui.split_rows.items[1].left.?.line_num);
    try std.testing.expectEqualStrings("line 2", ui.split_rows.items[1].left.?.content);
}

test "split view: added file shows content on right side" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "new.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .added,
        .chunks = &.{},
        .allocator = allocator,
    };

    try session.addFile(.{
        .path = try allocator.dupe(u8, "new.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, ""),
        .new_content = try allocator.dupe(u8, "fn main() {}\nreturn;"),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Verify split rows are built correctly
    try std.testing.expectEqual(@as(usize, 2), ui.split_rows.items.len);

    // Row 1: empty on left, addition on right
    try std.testing.expect(ui.split_rows.items[0].left == null);
    try std.testing.expect(ui.split_rows.items[0].right != null);
    try std.testing.expectEqual(@as(u32, 1), ui.split_rows.items[0].right.?.line_num);
    try std.testing.expectEqualStrings("fn main() {}", ui.split_rows.items[0].right.?.content);
    try std.testing.expectEqual(DiffLine.LineType.addition, ui.split_rows.items[0].right.?.line_type);

    // Row 2: empty on left, addition on right
    try std.testing.expect(ui.split_rows.items[1].left == null);
    try std.testing.expect(ui.split_rows.items[1].right != null);
    try std.testing.expectEqual(@as(u32, 2), ui.split_rows.items[1].right.?.line_num);
}

test "split view: unchanged file shows same content on both sides" {
    const allocator = std.testing.allocator;

    var session = review.ReviewSession.init(allocator);
    defer session.deinit();

    const file_diff = difft.FileDiff{
        .path = try allocator.dupe(u8, "same.zig"),
        .language = try allocator.dupe(u8, "Zig"),
        .status = .unchanged,
        .chunks = &.{},
        .allocator = allocator,
    };

    const content = "const x = 1;\nconst y = 2;";
    try session.addFile(.{
        .path = try allocator.dupe(u8, "same.zig"),
        .diff = file_diff,
        .is_binary = false,
        .old_content = try allocator.dupe(u8, content),
        .new_content = try allocator.dupe(u8, content),
    });

    var ui = UI.initForTest(allocator, &session);
    defer ui.deinit();

    try ui.buildDiffLines();

    // Verify split rows show same content on both sides
    try std.testing.expectEqual(@as(usize, 2), ui.split_rows.items.len);

    // Both rows should have content on both sides
    for (ui.split_rows.items) |row| {
        try std.testing.expect(row.left != null);
        try std.testing.expect(row.right != null);
        try std.testing.expectEqual(row.left.?.line_num, row.right.?.line_num);
        try std.testing.expectEqual(DiffLine.LineType.context, row.left.?.line_type);
        try std.testing.expectEqual(DiffLine.LineType.context, row.right.?.line_type);
    }
}

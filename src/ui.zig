const std = @import("std");
const Allocator = std.mem.Allocator;
const review = @import("review.zig");
const difft = @import("difft.zig");
const highlight = @import("highlight.zig");
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
    ask_pending,
    ask_response,
    help,
    file_list,
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

    const LineType = enum {
        context, // Unchanged line (shown with space prefix)
        addition, // Added line (shown with + prefix)
        deletion, // Deleted line (shown with - prefix)
        modification, // Modified line (shown with ~ prefix, both old and new)
    };
};

/// Main application model for the code review TUI
pub const UI = struct {
    allocator: Allocator,
    session: *review.ReviewSession,
    mode: Mode = .normal,
    scroll_offset: usize = 0,
    cursor_line: usize = 0,
    selection_start: ?usize = null,
    input_buffer: InputBuffer = .{},
    message: ?[]const u8 = null,
    message_is_error: bool = false,
    diff_lines: std.ArrayList(DiffLine),
    should_quit: bool = false,
    focus_side: review.CommentSide = .new,
    file_list_cursor: usize = 0,
    // Syntax highlighting
    highlighter: ?highlight.Highlighter = null,
    syntax_spans: []const highlight.HighlightSpan = &.{},
    // Ask mode state
    ask_response: ?[]const u8 = null,
    ask_scroll_offset: usize = 0,
    ask_context_file: ?[]const u8 = null,
    ask_context_lines: ?struct { start: u32, end: u32 } = null,
    project_path: ?[]const u8 = null,
    // Async ask state
    ask_thread: ?std.Thread = null,
    ask_thread_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ask_thread_result: ?[]const u8 = null,
    ask_thread_error: ?[]const u8 = null,
    ask_pending_prompt: ?[]const u8 = null,
    spinner_frame: usize = 0,

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

    pub fn init(allocator: Allocator, session: *review.ReviewSession) UI {
        return UI{
            .allocator = allocator,
            .session = session,
            .diff_lines = .empty,
        };
    }

    pub fn setProjectPath(self: *UI, path: []const u8) void {
        self.project_path = path;
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
        // Clean up syntax highlighting
        if (self.syntax_spans.len > 0) {
            self.allocator.free(self.syntax_spans);
        }
        if (self.highlighter) |*hl| {
            hl.deinit();
        }
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

        // Clean up old syntax highlighting
        if (self.syntax_spans.len > 0) {
            self.allocator.free(self.syntax_spans);
            self.syntax_spans = &.{};
        }
        if (self.highlighter) |*hl| {
            hl.deinit();
            self.highlighter = null;
        }

        const file = self.session.currentFile() orelse return;
        if (file.is_binary) return;

        // Initialize syntax highlighter for this file
        if (highlight.Language.fromPath(file.path)) |lang| {
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

        var old_lines: std.ArrayList([]const u8) = .empty;
        defer old_lines.deinit(self.allocator);
        var new_lines: std.ArrayList([]const u8) = .empty;
        defer new_lines.deinit(self.allocator);
        var new_line_offsets: std.ArrayList(u32) = .empty;
        defer new_line_offsets.deinit(self.allocator);

        var old_iter = std.mem.splitScalar(u8, file.old_content, '\n');
        while (old_iter.next()) |line| {
            try old_lines.append(self.allocator, line);
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
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = line_num,
                        .new_line_num = null,
                        .content = try self.allocator.dupe(u8, line),
                        .changes = &.{},
                        .line_type = .deletion,
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
                }
            } else if (file.diff.status == .unchanged) {
                // For unchanged files, show all lines as context
                for (new_lines.items, 0..) |line, idx| {
                    const line_num: u32 = @intCast(idx + 1);
                    const offset = if (idx < new_line_offsets.items.len) new_line_offsets.items[idx] else 0;
                    try self.diff_lines.append(self.allocator, .{
                        .old_line_num = line_num,
                        .new_line_num = line_num,
                        .content = try self.allocator.dupe(u8, line),
                        .changes = &.{},
                        .line_type = .context,
                        .content_byte_offset = offset,
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
                // For ask_pending mode, update spinner and request redraw
                if (self.mode == .ask_pending) {
                    self.spinner_frame +%= 1;
                    // Schedule next tick to keep animation going
                    try ctx.tick(80, self.widget());
                    // Request redraw to show updated spinner
                    ctx.redraw = true;
                }
            },
            else => {},
        }
    }

    fn handleKeyPress(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        switch (self.mode) {
            .normal => try self.handleNormalKey(ctx, key),
            .comment_input => try self.handleCommentInputKey(ctx, key),
            .ask_input => try self.handleAskInputKey(ctx, key),
            .ask_pending => self.handleAskPendingKey(ctx, key),
            .ask_response => self.handleAskResponseKey(ctx, key),
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
            self.moveCursorUp();
            return ctx.consumeAndRedraw();
        } else if (cp == vaxis.Key.down) {
            self.moveCursorDown();
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
            self.pageUp();
            return ctx.consumeAndRedraw();
        } else if (cp == vaxis.Key.page_down) {
            self.pageDown();
            return ctx.consumeAndRedraw();
        } else if (cp == vaxis.Key.escape) {
            self.clearMessage();
            return ctx.consumeAndRedraw();
        }

        switch (cp) {
            'q' => {
                self.should_quit = true;
                ctx.quit = true;
            },
            'f' => {
                self.pageDown();
                return ctx.consumeAndRedraw();
            },
            'p' => {
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
                // Switch to pending mode and start the ask request
                self.mode = .ask_pending;
                self.spinner_frame = 0;
                try self.startAskRequest();
                // Start the spinner tick immediately
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

    fn handleAskPendingKey(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        const cp = key.codepoint;

        // Allow escape to cancel - we'll let the thread finish in background
        // but ignore its result
        if (cp == vaxis.Key.escape) {
            // Note: We can't easily kill the thread, so we just switch mode
            // The thread will complete and its result will be ignored on next ask
            self.mode = .normal;
            self.input_buffer.clear();
            self.clearMessage();
            self.setMessage("Ask cancelled", false);
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

        // Get the selected code content
        var code_content: std.ArrayList(u8) = .empty;
        defer code_content.deinit(self.allocator);

        for (self.diff_lines.items) |diff_line| {
            // Use new_line_num for additions/context, old_line_num for deletions
            const line_num = diff_line.new_line_num orelse diff_line.old_line_num;
            if (line_num) |num| {
                if (num >= lines_start and num <= lines_end) {
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

        // Reset thread state
        self.ask_thread_done.store(false, .release);
        self.ask_thread_result = null;
        self.ask_thread_error = null;
        self.spinner_frame = 0;

        // Spawn thread to do the RPC call
        self.ask_thread = std.Thread.spawn(.{}, askThreadFn, .{self}) catch {
            self.mode = .normal;
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

        const response = pi.askPi(self.allocator, prompt) catch |err| {
            self.ask_thread_error = std.fmt.allocPrint(self.allocator, "RPC error: {}", .{err}) catch null;
            self.ask_thread_done.store(true, .release);
            return;
        };

        self.ask_thread_result = response;
        self.ask_thread_done.store(true, .release);
    }

    fn getLineNumber(self: *UI) ?usize {
        return self.getLineNumberAt(self.cursor_line);
    }

    fn getLineNumberAt(self: *UI, idx: usize) ?usize {
        if (idx >= self.diff_lines.items.len) return null;
        const line = self.diff_lines.items[idx];
        // Prefer new line number, fall back to old line number
        return if (line.new_line_num) |n| n else if (line.old_line_num) |n| n else null;
    }

    fn moveCursorDown(self: *UI) void {
        if (self.cursor_line + 1 < self.diff_lines.items.len) {
            self.cursor_line += 1;
            while (self.cursor_line < self.diff_lines.items.len and !self.diff_lines.items[self.cursor_line].selectable) {
                self.cursor_line += 1;
            }
            if (self.cursor_line >= self.diff_lines.items.len) {
                self.cursor_line -= 1;
                while (self.cursor_line > 0 and !self.diff_lines.items[self.cursor_line].selectable) {
                    self.cursor_line -= 1;
                }
            }
        }
    }

    fn moveCursorUp(self: *UI) void {
        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            while (self.cursor_line > 0 and !self.diff_lines.items[self.cursor_line].selectable) {
                self.cursor_line -= 1;
            }
            if (!self.diff_lines.items[self.cursor_line].selectable) {
                while (self.cursor_line < self.diff_lines.items.len and !self.diff_lines.items[self.cursor_line].selectable) {
                    self.cursor_line += 1;
                }
            }
        }
    }

    fn pageDown(self: *UI) void {
        const page_size: usize = 20;
        self.cursor_line = @min(self.cursor_line + page_size, if (self.diff_lines.items.len > 0) self.diff_lines.items.len - 1 else 0);
        while (self.cursor_line < self.diff_lines.items.len and !self.diff_lines.items[self.cursor_line].selectable) {
            self.cursor_line += 1;
        }
    }

    fn pageUp(self: *UI) void {
        const page_size: usize = 20;
        if (self.cursor_line >= page_size) {
            self.cursor_line -= page_size;
        } else {
            self.cursor_line = 0;
        }
        while (self.cursor_line > 0 and !self.diff_lines.items[self.cursor_line].selectable) {
            self.cursor_line -= 1;
        }
    }

    fn goToTop(self: *UI) void {
        self.cursor_line = 0;
        self.scroll_offset = 0;
        while (self.cursor_line < self.diff_lines.items.len and !self.diff_lines.items[self.cursor_line].selectable) {
            self.cursor_line += 1;
        }
    }

    fn goToBottom(self: *UI) void {
        if (self.diff_lines.items.len > 0) {
            self.cursor_line = self.diff_lines.items.len - 1;
            while (self.cursor_line > 0 and !self.diff_lines.items[self.cursor_line].selectable) {
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
            .ask_pending => self.drawAskPending(ctx),
            .ask_response => self.drawAskResponse(ctx),
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
        self.drawDiff(&surface, content_height);

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

        // Build header text
        var buf: [256]u8 = undefined;
        const header_text = std.fmt.bufPrint(&buf, " rv: {s} ({d}/{d})", .{
            path,
            self.session.current_file_idx + 1,
            self.session.files.len,
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

        // Adjust scroll to keep cursor visible
        if (self.cursor_line < self.scroll_offset) {
            self.scroll_offset = self.cursor_line;
        } else if (self.cursor_line >= self.scroll_offset + height) {
            self.scroll_offset = self.cursor_line - height + 1;
        }

        // Render visible lines in unified diff format
        var row: u16 = 0;
        var line_idx = self.scroll_offset;
        while (row < height and line_idx < self.diff_lines.items.len) : ({
            row += 1;
            line_idx += 1;
        }) {
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

            const display_row = row + 1; // +1 for header
            var col: u16 = 0;

            // Old line number (4 chars) - red for deletions, yellow for modifications, dim for context
            var num_buf: [8]u8 = undefined;
            const old_num_style = if (is_selected)
                vaxis.Style{ .reverse = true }
            else if (diff_line.line_type == .deletion)
                red_line_num_style
            else if (diff_line.line_type == .modification)
                yellow_line_num_style
            else
                dim_style;

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
                while (col < 4 and col < width) : (col += 1) {
                    surface.writeCell(col, display_row, .{
                        .char = .{ .grapheme = grapheme(' ') },
                        .style = dim_style,
                    });
                }
            }

            // Space between line numbers
            if (col < width) {
                surface.writeCell(col, display_row, .{
                    .char = .{ .grapheme = grapheme(' ') },
                    .style = dim_style,
                });
                col += 1;
            }

            // New line number (4 chars) - green for additions, yellow for modifications, dim for context
            const new_num_style = if (is_selected)
                vaxis.Style{ .reverse = true }
            else if (diff_line.line_type == .addition)
                green_line_num_style
            else if (diff_line.line_type == .modification)
                yellow_line_num_style
            else
                dim_style;

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
                while (col < 9 and col < width) : (col += 1) {
                    surface.writeCell(col, display_row, .{
                        .char = .{ .grapheme = grapheme(' ') },
                        .style = dim_style,
                    });
                }
            }

            // Space after line numbers
            if (col < width) {
                surface.writeCell(col, display_row, .{
                    .char = .{ .grapheme = grapheme(' ') },
                    .style = style,
                });
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
                writeString(surface, 0, footer_row, "[↑↓] nav  [←→] files  [c] comment  [a] ask  [Space] select  [l] list  [q] quit  [?] help", dim_style);

                if (self.message) |msg| {
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

                // Show focus indicator
                const focus_text = if (self.focus_side == .new) "Focus: NEW" else "Focus: OLD";
                if (width > 20) {
                    writeString(surface, @intCast(width -| 12), status_row, focus_text, dim_style);
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
            "    Left/Right          Previous/next file",
            "    f/p                 Page forward/backward",
            "    g/G                 Go to top/bottom",
            "    PgUp/PgDn           Page up/down",
            "    l or .              Show file list",
            "",
            "  Actions:",
            "    c                   Add comment at cursor",
            "    a                   Ask Pi about selected lines",
            "    Space               Start/end line selection",
            "    q                   Quit and export markdown",
            "    ?                   Toggle this help",
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

    fn drawAskPending(self: *UI, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        // Check if thread completed (poll on every draw)
        if (self.ask_thread_done.load(.acquire)) {
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

            self.ask_scroll_offset = 0;
            self.mode = .ask_response;
            self.input_buffer.clear();
            self.selection_start = null;

            // Draw the response instead
            return self.drawAskResponse(ctx);
        }

        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        const header_style: vaxis.Style = .{
            .bg = .{ .rgb = .{ 0x5f, 0x00, 0xaf } }, // Purple background
            .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } },
            .bold = true,
        };
        fillRow(&surface, 0, ' ', header_style);
        writeString(&surface, 1, 0, "Ask Pi", header_style);

        const center_row = size.height / 2;

        // Static loading message with dots
        writeString(&surface, 2, center_row - 1, "⏳ Asking Pi...", .{
            .bold = true,
            .fg = .{ .rgb = .{ 0xaf, 0x5f, 0xff } }, // Purple text
        });
        writeString(&surface, 2, center_row + 1, "Please wait for response", .{
            .fg = .{ .rgb = .{ 0x80, 0x80, 0x80 } },
        });

        const dim_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x80, 0x80, 0x80 } },
        };
        writeString(&surface, 2, @intCast(size.height -| 1), "[Esc] cancel", dim_style);

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

        var header_buf: [128]u8 = undefined;
        const file_info = self.ask_context_file orelse "unknown";
        const lines_info = if (self.ask_context_lines) |l|
            if (l.start == l.end)
                std.fmt.bufPrint(&header_buf, " Pi Response - {s}:{d}", .{ file_info, l.start }) catch " Pi Response"
            else
                std.fmt.bufPrint(&header_buf, " Pi Response - {s}:{d}-{d}", .{ file_info, l.start, l.end }) catch " Pi Response"
        else
            " Pi Response";

        writeString(&surface, 0, 0, lines_info, header_style);

        // Content area
        const content_height = size.height -| 2;
        const response = self.ask_response orelse "(No response)";

        // Split response into lines
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(ctx.arena);

        var line_iter = std.mem.splitScalar(u8, response, '\n');
        while (line_iter.next()) |line| {
            // Word wrap long lines
            if (line.len > size.width -| 4) {
                var start: usize = 0;
                while (start < line.len) {
                    const end = @min(start + size.width -| 4, line.len);
                    lines.append(ctx.arena, line[start..end]) catch break;
                    start = end;
                }
            } else {
                lines.append(ctx.arena, line) catch break;
            }
        }

        // Clamp scroll offset
        if (lines.items.len > 0 and self.ask_scroll_offset >= lines.items.len) {
            self.ask_scroll_offset = lines.items.len - 1;
        }

        // Draw visible lines
        var row: u16 = 1;
        var line_idx = self.ask_scroll_offset;
        while (row < content_height and line_idx < lines.items.len) : ({
            row += 1;
            line_idx += 1;
        }) {
            writeString(&surface, 2, row, lines.items[line_idx], .{});
        }

        // Footer
        const dim_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 0x80, 0x80, 0x80 } },
        };
        writeString(&surface, 2, @intCast(size.height -| 1), "[↑↓/PgUp/PgDn] scroll  [Esc/q] close", dim_style);

        return surface;
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
    var ui = UI.init(allocator, &session);
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
    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui_instance = UI.init(allocator, &session);
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

    var ui_instance = UI.init(allocator, &session);
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

    var ui_instance = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

    var ui = UI.init(allocator, &session);
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

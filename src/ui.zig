const std = @import("std");
const Allocator = std.mem.Allocator;
const review = @import("review.zig");
const difft = @import("difft.zig");

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
    help,
    file_list,
};

/// Represents a single line in the unified diff view
const DiffLine = struct {
    line_num: ?u32,
    content: []const u8,
    changes: []const difft.Change = &.{},
    line_type: LineType,
    selectable: bool = true,
    is_partial_change: bool = false, // True if only part of line changed (unchanged parts shown in white)

    const LineType = enum {
        context, // Unchanged line (shown with space prefix)
        addition, // Added line (shown with + prefix)
        deletion, // Deleted line (shown with - prefix)
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

    pub fn deinit(self: *UI) void {
        for (self.diff_lines.items) |line| {
            if (line.content.len > 0) self.allocator.free(line.content);
            if (line.changes.len > 0) {
                for (line.changes) |change| {
                    if (change.content.len > 0) self.allocator.free(change.content);
                }
                self.allocator.free(line.changes);
            }
        }
        self.diff_lines.deinit(self.allocator);
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
            if (line.changes.len > 0) {
                for (line.changes) |change| {
                    if (change.content.len > 0) self.allocator.free(change.content);
                }
                self.allocator.free(line.changes);
            }
        }
        self.diff_lines.clearRetainingCapacity();

        const file = self.session.currentFile() orelse return;
        if (file.is_binary) return;

        var old_lines: std.ArrayList([]const u8) = .empty;
        defer old_lines.deinit(self.allocator);
        var new_lines: std.ArrayList([]const u8) = .empty;
        defer new_lines.deinit(self.allocator);

        var old_iter = std.mem.splitScalar(u8, file.old_content, '\n');
        while (old_iter.next()) |line| {
            try old_lines.append(self.allocator, line);
        }

        var new_iter = std.mem.splitScalar(u8, file.new_content, '\n');
        while (new_iter.next()) |line| {
            try new_lines.append(self.allocator, line);
        }

        if (file.diff.chunks.len == 0 and (file.diff.status == .removed or file.diff.status == .added)) {
            if (file.diff.status == .removed) {
                for (old_lines.items, 0..) |line, idx| {
                    const line_num: u32 = @intCast(idx + 1);
                    try self.diff_lines.append(self.allocator, .{
                        .line_num = line_num,
                        .content = try self.allocator.dupe(u8, line),
                        .changes = &.{},
                        .line_type = .deletion,
                    });
                }
            } else if (file.diff.status == .added) {
                for (new_lines.items, 0..) |line, idx| {
                    const line_num: u32 = @intCast(idx + 1);
                    try self.diff_lines.append(self.allocator, .{
                        .line_num = line_num,
                        .content = try self.allocator.dupe(u8, line),
                        .changes = &.{},
                        .line_type = .addition,
                    });
                }
            }
        }

        const CONTEXT_LINES: u32 = 3;
        var last_shown_new_line: u32 = 0;

        for (file.diff.chunks) |chunk| {
            // difft uses 0-based line numbers, we need 1-based for display
            var first_line_in_chunk_0based: u32 = std.math.maxInt(u32);
            var last_line_in_chunk_0based: u32 = 0;

            for (chunk) |entry| {
                if (entry.rhs) |rhs| {
                    first_line_in_chunk_0based = @min(first_line_in_chunk_0based, rhs.line_number);
                    last_line_in_chunk_0based = @max(last_line_in_chunk_0based, rhs.line_number);
                } else if (entry.lhs) |lhs| {
                    first_line_in_chunk_0based = @min(first_line_in_chunk_0based, lhs.line_number);
                    last_line_in_chunk_0based = @max(last_line_in_chunk_0based, lhs.line_number);
                }
            }

            // Convert to 1-based display line numbers
            const first_line_in_chunk = first_line_in_chunk_0based + 1;
            const last_line_in_chunk = last_line_in_chunk_0based + 1;

            const context_start = if (first_line_in_chunk > CONTEXT_LINES) first_line_in_chunk - CONTEXT_LINES else 1;
            if (last_shown_new_line > 0 and context_start > last_shown_new_line + 1) {
                try self.diff_lines.append(self.allocator, .{
                    .line_num = null,
                    .content = try self.allocator.dupe(u8, "..."),
                    .changes = &.{},
                    .line_type = .context,
                    .selectable = false,
                });
            }

            if (context_start < first_line_in_chunk) {
                for (context_start..first_line_in_chunk) |line_num_usize| {
                    const line_num: u32 = @intCast(line_num_usize);
                    if (line_num <= last_shown_new_line) continue; // Skip if already shown

                    const idx = line_num - 1;
                    const content = if (idx < new_lines.items.len) new_lines.items[idx] else "";
                    try self.diff_lines.append(self.allocator, .{
                        .line_num = line_num,
                        .content = try self.allocator.dupe(u8, content),
                        .changes = &.{},
                        .line_type = .context,
                    });
                    last_shown_new_line = line_num;
                }
            }

            // Sort entries by LHS line number (or RHS if no LHS) to display in order
            var sorted_entries: std.ArrayList(struct {
                const Self = @This();
                idx: usize,
                sort_key: u32,
            }) = .empty;
            defer sorted_entries.deinit(self.allocator);
            for (chunk, 0..) |entry, idx| {
                const sort_key = if (entry.lhs) |lhs| lhs.line_number else (if (entry.rhs) |rhs| rhs.line_number else 0);
                try sorted_entries.append(self.allocator, .{ .idx = idx, .sort_key = sort_key });
            }
            std.mem.sort(@TypeOf(sorted_entries.items[0]), sorted_entries.items, {}, struct {
                fn lessThan(_: void, a: @TypeOf(sorted_entries.items[0]), b: @TypeOf(sorted_entries.items[0])) bool {
                    return a.sort_key < b.sort_key;
                }
            }.lessThan);

            for (sorted_entries.items) |entry_info| {
                const entry = chunk[entry_info.idx];
                const has_lhs = entry.lhs != null;
                const has_rhs = entry.rhs != null;

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
                        last_shown_new_line = @max(last_shown_new_line, new_line_idx + 1);
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

                    // Show deletion line (old content with deleted parts highlighted)
                    try self.diff_lines.append(self.allocator, .{
                        .line_num = old_display_line_num,
                        .content = try self.allocator.dupe(u8, old_content),
                        .changes = deleted_changes,
                        .line_type = .deletion,
                        .is_partial_change = is_partial_deletion,
                    });

                    // Show addition line (new content with added parts highlighted)
                    try self.diff_lines.append(self.allocator, .{
                        .line_num = new_display_line_num,
                        .content = try self.allocator.dupe(u8, new_content),
                        .changes = added_changes,
                        .line_type = .addition,
                        .is_partial_change = is_partial_addition,
                    });

                    // Track the new line number for context calculation
                    last_shown_new_line = @max(last_shown_new_line, new_line_idx + 1);
                } else if (has_lhs and !has_rhs) {
                    // Deletion only - difft uses 0-based indexing
                    const old_line_idx = entry.lhs.?.line_number;
                    const display_line_num = old_line_idx + 1;
                    const content = if (old_line_idx < old_lines.items.len) old_lines.items[old_line_idx] else "";
                    // Copy the changes array to avoid double-free
                    const changes_copy = try self.dupeChanges(entry.lhs.?.changes);
                    try self.diff_lines.append(self.allocator, .{
                        .line_num = display_line_num,
                        .content = try self.allocator.dupe(u8, content),
                        .changes = changes_copy,
                        .line_type = .deletion,
                    });
                } else if (!has_lhs and has_rhs) {
                    // Addition only - difft uses 0-based indexing
                    const new_line_idx = entry.rhs.?.line_number;
                    const display_line_num = new_line_idx + 1;
                    const content = if (new_line_idx < new_lines.items.len) new_lines.items[new_line_idx] else "";
                    // Copy the changes array to avoid double-free
                    const changes_copy = try self.dupeChanges(entry.rhs.?.changes);
                    try self.diff_lines.append(self.allocator, .{
                        .line_num = display_line_num,
                        .content = try self.allocator.dupe(u8, content),
                        .changes = changes_copy,
                        .line_type = .addition,
                    });
                    last_shown_new_line = display_line_num;
                }
            }

            const new_lines_count: u32 = @intCast(new_lines.items.len);
            const context_end = @min(last_line_in_chunk + CONTEXT_LINES, new_lines_count);
            // Only add context after if we have lines to show (context_end > last_line_in_chunk)
            if (context_end > last_line_in_chunk) {
                for (last_line_in_chunk + 1..context_end + 1) |line_num_usize| {
                    const line_num: u32 = @intCast(line_num_usize);
                    if (line_num <= last_shown_new_line) continue; // Skip if already shown

                    const idx = line_num - 1;
                    const content = if (idx < new_lines.items.len) new_lines.items[idx] else "";
                    try self.diff_lines.append(self.allocator, .{
                        .line_num = line_num,
                        .content = try self.allocator.dupe(u8, content),
                        .changes = &.{},
                        .line_type = .context,
                    });
                    last_shown_new_line = line_num;
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
            else => {},
        }
    }

    fn handleKeyPress(self: *UI, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        switch (self.mode) {
            .normal => try self.handleNormalKey(ctx, key),
            .comment_input => try self.handleCommentInputKey(ctx, key),
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

    fn getLineNumber(self: *UI) ?usize {
        return self.getLineNumberAt(self.cursor_line);
    }

    fn getLineNumberAt(self: *UI, idx: usize) ?usize {
        if (idx >= self.diff_lines.items.len) return null;
        const line = self.diff_lines.items[idx];
        return if (line.line_num) |n| n else null;
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

            // Line number style (dimmed)
            var line_num_style: vaxis.Style = .{
                .fg = .{ .rgb = .{ 0x60, 0x60, 0x60 } },
            };
            if (is_selected) {
                line_num_style.reverse = true;
            }

            const display_row = row + 1; // +1 for header
            var col: u16 = 0;

            // Line number (5 chars)
            var num_buf: [8]u8 = undefined;
            if (diff_line.line_num) |num| {
                const num_str = std.fmt.bufPrint(&num_buf, "{d:>5}", .{num}) catch "     ";
                for (num_str) |c| {
                    if (col < width) {
                        surface.writeCell(col, display_row, .{
                            .char = .{ .grapheme = grapheme(c) },
                            .style = line_num_style,
                        });
                        col += 1;
                    }
                }
            } else {
                while (col < 5 and col < width) : (col += 1) {
                    surface.writeCell(col, display_row, .{
                        .char = .{ .grapheme = grapheme(' ') },
                        .style = line_num_style,
                    });
                }
            }

            // Space after line number
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

            // Content (preserving indentation)
            var content = diff_line.content;
            // Strip trailing newlines only
            while (content.len > 0 and (content[content.len - 1] == '\n' or content[content.len - 1] == '\r')) {
                content = content[0 .. content.len - 1];
            }

            self.writeContentWithHighlight(surface, display_row, col, content, diff_line.changes, width -| col, style, novel_style, is_selected or in_selection);
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
    ) void {
        _ = self;

        var col = start_col;
        var char_idx: u32 = 0;
        // Track visual column for tab alignment (relative to content start)
        var visual_col: u16 = 0;

        for (content) |c| {
            if (col >= start_col + max_width) break;

            // Determine if this character is in a changed region
            var is_novel = false;
            for (changes) |change| {
                if (char_idx >= change.start and char_idx < change.end) {
                    is_novel = true;
                    break;
                }
            }

            const style = if (is_novel and !is_selected) novel_style else base_style;

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
            else => {
                writeString(surface, 0, footer_row, "[↑↓] nav  [←→] files  [f/p] page  [c] comment  [Space] select  [l] list  [q] quit  [?] help", dim_style);

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

    // Should have: 3 context lines before (3-5), 2 modified lines (deletion + addition for line 6), and 3 context lines after (7-9)
    // Total: 3 + 2 + 3 = 8 lines
    try std.testing.expect(ui.diff_lines.items.len == 8);

    // Lines 3, 4, 5 should be context (before the change at display line 6)
    try std.testing.expectEqual(ui.diff_lines.items[0].line_num, 3);
    try std.testing.expect(ui.diff_lines.items[0].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[1].line_num, 4);
    try std.testing.expect(ui.diff_lines.items[1].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[2].line_num, 5);
    try std.testing.expect(ui.diff_lines.items[2].line_type == .context);

    // Line 6 is shown as deletion (old content)
    try std.testing.expectEqual(ui.diff_lines.items[3].line_num, 6);
    try std.testing.expect(ui.diff_lines.items[3].line_type == .deletion);
    try std.testing.expectEqualStrings("old line 6", ui.diff_lines.items[3].content);

    // Line 6 is also shown as addition (new content)
    try std.testing.expectEqual(ui.diff_lines.items[4].line_num, 6);
    try std.testing.expect(ui.diff_lines.items[4].line_type == .addition);
    try std.testing.expectEqualStrings("new line 6", ui.diff_lines.items[4].content);

    // Lines 7, 8, 9 should be context (after the change)
    try std.testing.expectEqual(ui.diff_lines.items[5].line_num, 7);
    try std.testing.expect(ui.diff_lines.items[5].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[6].line_num, 8);
    try std.testing.expect(ui.diff_lines.items[6].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[7].line_num, 9);
    try std.testing.expect(ui.diff_lines.items[7].line_type == .context);
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
    // Should have: 1 context line before (line 1), 2 modified lines (deletion + addition for line 2), 3 context lines after (3-5)
    // Total: 1 + 2 + 3 = 6 lines
    try std.testing.expect(ui.diff_lines.items.len == 6);

    try std.testing.expectEqual(ui.diff_lines.items[0].line_num, 1);
    try std.testing.expect(ui.diff_lines.items[0].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[1].line_num, 2);
    try std.testing.expect(ui.diff_lines.items[1].line_type == .deletion);
    try std.testing.expectEqualStrings("old line 2", ui.diff_lines.items[1].content);

    try std.testing.expectEqual(ui.diff_lines.items[2].line_num, 2);
    try std.testing.expect(ui.diff_lines.items[2].line_type == .addition);
    try std.testing.expectEqualStrings("new line 2", ui.diff_lines.items[2].content);

    try std.testing.expectEqual(ui.diff_lines.items[3].line_num, 3);
    try std.testing.expect(ui.diff_lines.items[3].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[4].line_num, 4);
    try std.testing.expect(ui.diff_lines.items[4].line_type == .context);

    try std.testing.expectEqual(ui.diff_lines.items[5].line_num, 5);
    try std.testing.expect(ui.diff_lines.items[5].line_type == .context);
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
        if (line.line_num == null and std.mem.eql(u8, line.content, "...")) {
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
        if (line.line_type == .deletion and line.line_num == 6) {
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
        if (line.line_type == .deletion and line.line_num == 3) {
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
        if (line.line_type == .deletion and line.line_num == 3) {
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

    // Modified lines show BOTH deletion (old content) and addition (new content)
    var found_old_content = false;
    var found_new_content = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion and std.mem.eql(u8, line.content, "old content here")) {
            found_old_content = true;
            try std.testing.expectEqual(line.line_num, 6); // Display line 6
        }
        if (line.line_type == .addition and std.mem.eql(u8, line.content, "new content here")) {
            found_new_content = true;
            try std.testing.expectEqual(line.line_num, 6); // Display line 6
        }
    }

    try std.testing.expect(found_old_content);
    try std.testing.expect(found_new_content);
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
        if (line.line_num) |num| {
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
        if (line.line_num == null and std.mem.eql(u8, line.content, "...")) {
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

    // Should have two diff lines (deletion + addition)
    try std.testing.expect(ui_instance.diff_lines.items.len >= 2);

    // Find the deletion line
    var found_deletion = false;
    var found_addition = false;
    for (ui_instance.diff_lines.items) |line| {
        if (line.line_type == .deletion and line.line_num == 1) {
            found_deletion = true;
            // Should be marked as partial change
            try std.testing.expect(line.is_partial_change);
            // Should have a changes array marking the deleted portion
            try std.testing.expect(line.changes.len == 1);
            // The deleted portion starts at "Hello world" (11 chars)
            try std.testing.expectEqual(@as(u32, 11), line.changes[0].start);
            try std.testing.expectEqual(@as(u32, 34), line.changes[0].end);
        }
        if (line.line_type == .addition and line.line_num == 1) {
            found_addition = true;
            // Addition line should NOT be marked as partial change (nothing was added, only deleted)
            try std.testing.expect(!line.is_partial_change);
            // No changes to highlight in new content (it's all unchanged)
            try std.testing.expect(line.changes.len == 0);
        }
    }
    try std.testing.expect(found_deletion);
    try std.testing.expect(found_addition);
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
        if (line.line_num == 3) { // display line 3 = index 2
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

    // Should have deletion and addition lines
    try std.testing.expect(ui.diff_lines.items.len >= 2);

    // Find the deletion line and verify it uses difft's changes
    var found_deletion_with_changes = false;
    var found_addition_with_changes = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion and line.line_num == 1) {
            found_deletion_with_changes = true;
            // Should use difft's semantic change highlighting (position 6-7 for "x")
            try std.testing.expect(line.changes.len >= 1);
            // The change should highlight position 6-7 (the "x")
            try std.testing.expectEqual(@as(u32, 6), line.changes[0].start);
            try std.testing.expectEqual(@as(u32, 7), line.changes[0].end);
        }
        if (line.line_type == .addition and line.line_num == 1) {
            found_addition_with_changes = true;
            // Should use difft's semantic change highlighting (position 6-7 for "a")
            try std.testing.expect(line.changes.len >= 1);
            try std.testing.expectEqual(@as(u32, 6), line.changes[0].start);
            try std.testing.expectEqual(@as(u32, 7), line.changes[0].end);
        }
    }

    try std.testing.expect(found_deletion_with_changes);
    try std.testing.expect(found_addition_with_changes);
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

    // Find the deletion line and verify it has all 3 changes
    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion and line.line_num == 1) {
            // Should have 3 separate change highlights
            try std.testing.expectEqual(@as(usize, 3), line.changes.len);
            // First change: "result" at position 4-10
            try std.testing.expectEqual(@as(u32, 4), line.changes[0].start);
            try std.testing.expectEqual(@as(u32, 10), line.changes[0].end);
        }
        if (line.line_type == .addition and line.line_num == 1) {
            // Should have 3 separate change highlights
            try std.testing.expectEqual(@as(usize, 3), line.changes.len);
            // First change: "sum" at position 4-7
            try std.testing.expectEqual(@as(u32, 4), line.changes[0].start);
            try std.testing.expectEqual(@as(u32, 7), line.changes[0].end);
        }
    }
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

    // Verify we show the deletion with old line number and addition with new line number
    var found_deletion = false;
    var found_addition = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion and std.mem.eql(u8, line.content, "hello")) {
            found_deletion = true;
            try std.testing.expectEqual(@as(u32, 3), line.line_num.?); // Display line 3 (1-based)
        }
        if (line.line_type == .addition and std.mem.eql(u8, line.content, "world")) {
            found_addition = true;
            try std.testing.expectEqual(@as(u32, 5), line.line_num.?); // Display line 5 (1-based)
        }
    }

    try std.testing.expect(found_deletion);
    try std.testing.expect(found_addition);
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
        if (line.line_type == .addition and line.line_num == 2) {
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
        if (line.line_type == .deletion and line.line_num == 2) {
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

    for (ui.diff_lines.items) |line| {
        switch (line.line_type) {
            .deletion => deletion_count += 1,
            .addition => addition_count += 1,
            .context => {},
        }
    }

    // Should have:
    // - 2 deletions (one from modification, one from pure deletion)
    // - 2 additions (one from modification, one from pure addition)
    try std.testing.expectEqual(@as(usize, 2), deletion_count);
    try std.testing.expectEqual(@as(usize, 2), addition_count);
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

    // Should have deletion and addition
    var found_deletion = false;
    var found_addition = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion) {
            found_deletion = true;
            try std.testing.expect(std.mem.indexOf(u8, line.content, "hello") != null);
        }
        if (line.line_type == .addition) {
            found_addition = true;
            try std.testing.expect(std.mem.indexOf(u8, line.content, "héllo") != null);
        }
    }

    try std.testing.expect(found_deletion);
    try std.testing.expect(found_addition);
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
        try std.testing.expect(line.line_type == .deletion);
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

    // Should have deletion and addition
    var found_deletion = false;
    var found_addition = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion) {
            found_deletion = true;
            try std.testing.expect(std.mem.startsWith(u8, line.content, "    ")); // 4 spaces
        }
        if (line.line_type == .addition) {
            found_addition = true;
            try std.testing.expect(std.mem.startsWith(u8, line.content, "\t")); // tab
        }
    }

    try std.testing.expect(found_deletion);
    try std.testing.expect(found_addition);
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

    // Should have deletion and addition
    var found_deletion = false;
    var found_addition = false;

    for (ui.diff_lines.items) |line| {
        if (line.line_type == .deletion) {
            found_deletion = true;
            try std.testing.expectEqual(@as(usize, 1000), line.content.len);
        }
        if (line.line_type == .addition) {
            found_addition = true;
            try std.testing.expectEqual(@as(usize, 1000), line.content.len);
        }
    }

    try std.testing.expect(found_deletion);
    try std.testing.expect(found_addition);
}

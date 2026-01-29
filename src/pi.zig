const std = @import("std");
const Allocator = std.mem.Allocator;

// C library functions for popen
const FILE = opaque {};
extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn pclose(stream: *FILE) c_int;
extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const PiError = error{
    CommandFailed,
    PipeFailed,
    NoResponse,
    RpcError,
} || Allocator.Error;

/// Call Pi via RPC with a prompt and return the response
pub fn askPi(allocator: Allocator, prompt: []const u8) PiError![]const u8 {
    // Build the JSON command with proper escaping
    const json_prompt = try jsonEscapeString(allocator, prompt);
    defer allocator.free(json_prompt);

    // Get pi binary path from environment or use default
    const pi_bin: []const u8 = if (getenv("RV_PI_BIN")) |env_ptr|
        std.mem.sliceTo(env_ptr, 0)
    else
        "pi";

    // Build the JSON payload
    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "{\"type\":\"prompt\",\"message\":");
    try json_buf.appendSlice(allocator, json_prompt);
    try json_buf.appendSlice(allocator, "}\n");

    // Base64 encode JSON to avoid shell escaping issues
    const base64 = std.base64.standard;
    const encoded_len = base64.Encoder.calcSize(json_buf.items.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = base64.Encoder.encode(encoded, json_buf.items);

    // Use base64 decode piped to pi - no temp file needed
    const cmd = try std.fmt.allocPrint(allocator, "echo '{s}' | base64 -d | {s} --mode rpc --no-session 2>&1", .{ encoded, pi_bin });
    defer allocator.free(cmd);

    const cmd_z = try allocator.dupeZ(u8, cmd);
    defer allocator.free(cmd_z);

    // Use popen to run the command
    const fp = popen(cmd_z.ptr, "r") orelse {
        return PiError.PipeFailed;
    };
    defer _ = pclose(fp);

    // Read all output
    var response_text: std.ArrayList(u8) = .empty;
    defer response_text.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        try response_text.appendSlice(allocator, buf[0..n]);
    }

    // Check if we got any output at all
    if (response_text.items.len == 0) {
        return PiError.NoResponse;
    }

    // Parse the response - look for text_delta events and concatenate
    return try parseRpcResponse(allocator, response_text.items);
}

/// Parse RPC response from Pi, extracting text_delta content
fn parseRpcResponse(allocator: Allocator, response: []const u8) PiError![]const u8 {
    var has_error: bool = false;
    var error_message: ?[]const u8 = null;

    var final_response: std.ArrayList(u8) = .empty;
    errdefer final_response.deinit(allocator);

    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Check for error response
        if (std.mem.indexOf(u8, line, "\"success\":false")) |_| {
            has_error = true;
            // Try to extract error message
            if (std.mem.indexOf(u8, line, "\"error\":\"")) |err_start| {
                const content_start = err_start + 9;
                var end = content_start;
                while (end < line.len and line[end] != '"') : (end += 1) {}
                error_message = line[content_start..end];
            }
        }

        // Look for text_delta in message_update events
        if (std.mem.indexOf(u8, line, "\"text_delta\"")) |_| {
            // Extract the delta value
            if (std.mem.indexOf(u8, line, "\"delta\":\"")) |delta_start| {
                const content_start = delta_start + 9;
                var end = content_start;
                var escape_next = false;
                while (end < line.len) : (end += 1) {
                    if (escape_next) {
                        escape_next = false;
                        continue;
                    }
                    if (line[end] == '\\') {
                        escape_next = true;
                        continue;
                    }
                    if (line[end] == '"') break;
                }
                const delta = line[content_start..end];
                // Unescape the JSON string
                const unescaped = try jsonUnescapeString(allocator, delta);
                defer allocator.free(unescaped);
                try final_response.appendSlice(allocator, unescaped);
            }
        }
    }

    // If we got an error, report it
    if (has_error) {
        if (error_message) |msg| {
            return try std.fmt.allocPrint(allocator, "Pi returned an error:\n{s}", .{msg});
        }
        return try allocator.dupe(u8, "Pi returned an error (unknown)");
    }

    if (final_response.items.len == 0) {
        // Show first part of raw output for debugging
        const preview_len = @min(response.len, 500);
        return try std.fmt.allocPrint(allocator, "No text response found in Pi output.\n\nRaw output preview ({d} bytes total):\n{s}{s}", .{
            response.len,
            response[0..preview_len],
            if (response.len > 500) "\n..." else "",
        });
    }

    return try final_response.toOwnedSlice(allocator);
}

/// Escape a string for use in JSON
pub fn jsonEscapeString(allocator: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try result.appendSlice(allocator, "\\u00");
                    const hex = "0123456789abcdef";
                    try result.append(allocator, hex[c >> 4]);
                    try result.append(allocator, hex[c & 0xf]);
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }
    try result.append(allocator, '"');

    return try result.toOwnedSlice(allocator);
}

/// Unescape a JSON string
pub fn jsonUnescapeString(allocator: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'n' => {
                    try result.append(allocator, '\n');
                    i += 2;
                },
                'r' => {
                    try result.append(allocator, '\r');
                    i += 2;
                },
                't' => {
                    try result.append(allocator, '\t');
                    i += 2;
                },
                '"' => {
                    try result.append(allocator, '"');
                    i += 2;
                },
                '\\' => {
                    try result.append(allocator, '\\');
                    i += 2;
                },
                'u' => {
                    // Handle \uXXXX - simple handling, just skip for now
                    if (i + 5 < s.len) {
                        i += 6;
                    } else {
                        try result.append(allocator, s[i]);
                        i += 1;
                    }
                },
                else => {
                    try result.append(allocator, s[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(allocator, s[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

// Tests
test "jsonEscapeString" {
    const allocator = std.testing.allocator;

    {
        const result = try jsonEscapeString(allocator, "hello");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("\"hello\"", result);
    }

    {
        const result = try jsonEscapeString(allocator, "hello\nworld");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("\"hello\\nworld\"", result);
    }

    {
        const result = try jsonEscapeString(allocator, "say \"hi\"");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", result);
    }
}

test "jsonUnescapeString" {
    const allocator = std.testing.allocator;

    {
        const result = try jsonUnescapeString(allocator, "hello");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("hello", result);
    }

    {
        const result = try jsonUnescapeString(allocator, "hello\\nworld");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("hello\nworld", result);
    }

    {
        const result = try jsonUnescapeString(allocator, "say \\\"hi\\\"");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("say \"hi\"", result);
    }
}

test "parseRpcResponse with text_delta" {
    const allocator = std.testing.allocator;

    const response =
        \\{"type":"message_update","delta":{"type":"text_delta","delta":"Hello "}}
        \\{"type":"message_update","delta":{"type":"text_delta","delta":"world!"}}
    ;

    const result = try parseRpcResponse(allocator, response);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello world!", result);
}

test "parseRpcResponse with error" {
    const allocator = std.testing.allocator;

    const response =
        \\{"success":false,"error":"Something went wrong"}
    ;

    const result = try parseRpcResponse(allocator, response);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "error") != null);
}

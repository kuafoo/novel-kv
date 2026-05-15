const std = @import("std");

pub const RespValue = union(enum) {
    simple_string: []const u8,
    error_msg: []const u8,
    integer: i64,
    bulk_string: ?[]const u8,
    array: []RespValue,
};

pub const Parser = struct {
    buf: []u8,
    pos: usize,
    len: usize,
    inline_buf: [1024]u8,
    array_buf: [4096]u8,

    pub fn init(buf: []u8) Parser {
        return Parser{ .buf = buf, .pos = 0, .len = 0, .inline_buf = undefined, .array_buf = undefined };
    }

    pub fn append(parser: *Parser, bytes: []const u8) usize {
        const available = parser.buf[parser.len..];
        const n = @min(bytes.len, available.len);
        @memcpy(parser.buf[parser.len .. parser.len + n], bytes[0..n]);
        parser.len += n;
        return n;
    }

    pub fn compact(parser: *Parser) void {
        if (parser.pos == 0) return;
        const rem = parser.len - parser.pos;
        if (rem > 0) {
            std.mem.copyForwards(u8, parser.buf[0..rem], parser.buf[parser.pos..parser.len]);
        }
        parser.pos = 0;
        parser.len = rem;
    }

    pub fn getData(parser: *const Parser) []const u8 {
        return parser.buf[parser.pos..parser.len];
    }

    pub fn parseCommand(parser: *Parser) ?RespValue {
        const d = parser.getData();
        if (d.len == 0) return null;

        if (d[0] == '*') {
            return parser.parseArray();
        }
        return parser.parseInline();
    }

    fn parseInline(parser: *Parser) ?RespValue {
        const d = parser.getData();
        const nl = findNewline(d) orelse return null;
        const line = d[0..nl];

        var fib = std.heap.FixedBufferAllocator.init(&parser.inline_buf);
        const fib_alloc = fib.allocator();
        var parts = std.ArrayList(RespValue).initCapacity(fib_alloc, 8) catch return null;

        var iter = std.mem.splitSequence(u8, line, " ");
        while (iter.next()) |part| {
            if (part.len > 0) {
                parts.append(fib_alloc, RespValue{ .bulk_string = part }) catch return null;
            }
        }

        parser.pos += nl + 2;

        if (parts.items.len == 0) return null;

        const items = parts.toOwnedSlice(fib_alloc) catch return null;
        return RespValue{ .array = items };
    }

    fn parseArray(parser: *Parser) ?RespValue {
        const d = parser.getData();
        const nl = findNewline(d) orelse return null;

        const count_str = d[1..nl];
        const count = std.fmt.parseInt(usize, count_str, 10) catch return null;

        var fib = std.heap.FixedBufferAllocator.init(&parser.array_buf);
        const fib_alloc = fib.allocator();
        var items = std.ArrayList(RespValue).initCapacity(fib_alloc, count) catch return null;

        var cur = parser.pos + nl + 2;

        for (0..count) |_| {
            if (cur >= parser.len) return null;
            if (parser.buf[cur] != '$') return null;

            const bs_nl = findNewline(parser.buf[cur..parser.len]) orelse return null;
            const bs_len = std.fmt.parseInt(usize, parser.buf[cur + 1 .. cur + bs_nl], 10) catch return null;
            cur += bs_nl + 2;

            if (cur + bs_len + 2 > parser.len) return null;

            if (bs_len == 0) {
                items.append(fib_alloc, RespValue{ .bulk_string = "" }) catch return null;
            } else {
                items.append(fib_alloc, RespValue{ .bulk_string = parser.buf[cur .. cur + bs_len] }) catch return null;
            }
            cur += bs_len + 2;
        }

        parser.pos = cur;
        return RespValue{ .array = items.toOwnedSlice(fib_alloc) catch return null };
    }

    fn findNewline(d: []const u8) ?usize {
        var i: usize = 0;
        while (i + 1 < d.len) : (i += 1) {
            if (d[i] == '\r' and d[i + 1] == '\n') return i;
        }
        return null;
    }
};

pub fn writeSimpleString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('+');
    try writer.writeAll(s);
    try writer.writeAll("\r\n");
}

pub fn writeError(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('-');
    try writer.writeAll(s);
    try writer.writeAll("\r\n");
}

pub fn writeBulkString(writer: *std.Io.Writer, s: ?[]const u8) !void {
    if (s) |val| {
        try writer.writeByte('$');
        try writer.print("{d}\r\n", .{val.len});
        try writer.writeAll(val);
        try writer.writeAll("\r\n");
    } else {
        try writer.writeAll("$-1\r\n");
    }
}

pub fn writeInteger(writer: *std.Io.Writer, n: i64) !void {
    try writer.writeByte(':');
    try writer.print("{d}\r\n", .{n});
}

test "RESP parse inline command" {
    var buf: [1024]u8 = undefined;
    var parser = Parser.init(&buf);
    _ = parser.append("PING\r\n");
    const result = parser.parseCommand();
    try std.testing.expect(result != null);
}

test "RESP parse array command" {
    var buf: [1024]u8 = undefined;
    var parser = Parser.init(&buf);
    _ = parser.append("*2\r\n$3\r\nGET\r\n$3\r\nfoo\r\n");
    const result = parser.parseCommand();
    try std.testing.expect(result != null);
    switch (result.?) {
        .array => |arr| {
            try std.testing.expect(arr.len >= 2);
        },
        else => try std.testing.expect(false),
    }
}

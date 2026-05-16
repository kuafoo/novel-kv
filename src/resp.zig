// NovelKV - 专用小说章节文本 KV 存储系统
// RESP 协议序列化：将内部数据类型编码为 Redis Serialization Protocol 格式写入客户端
const std = @import("std");

/// RESP 数据类型标签，用于解析时区分传入值的类型
pub const RespValue = union(enum) {
    simple_string: []const u8,
    error_msg: []const u8,
    integer: i64,
    bulk_string: ?[]const u8,
    array: []RespValue,
};

/// 写入 RESP Simple String：+<s>\r\n
pub fn writeSimpleString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('+');
    try writer.writeAll(s);
    try writer.writeAll("\r\n");
}

/// 写入 RESP Error：-<s>\r\n
pub fn writeError(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('-');
    try writer.writeAll(s);
    try writer.writeAll("\r\n");
}

/// 写入 RESP Bulk String：$<len>\r\n<data>\r\n，null 时写入 $-1\r\n
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

/// 写入 RESP Integer：:<n>\r\n
pub fn writeInteger(writer: *std.Io.Writer, n: i64) !void {
    try writer.writeByte(':');
    try writer.print("{d}\r\n", .{n});
}

/// 写入完整 RESP 数组：*<count>\r\n 逐项写入 bulk string（用于主端广播）
pub fn writeRespArray(writer: *std.Io.Writer, items: []const []const u8) !void {
    try writer.print("*{d}\r\n", .{items.len});
    for (items) |item| {
        try writer.print("${d}\r\n", .{item.len});
        try writer.writeAll(item);
        try writer.writeAll("\r\n");
    }
}

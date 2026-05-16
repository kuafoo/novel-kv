// NovelKV - 专用小说章节文本 KV 存储系统
// 分级日志模块：支持 debug/info/warn/error 四级，输出到 stderr，可通过 --log-level 调节
const std = @import("std");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

var min_level: Level = .info;

pub fn setLevel(level: Level) void {
    min_level = level;
}

pub fn getLevel() Level {
    return min_level;
}

pub fn log(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;

    std.debug.print("[{s}] " ++ fmt ++ "\n", .{level.label()} ++ args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

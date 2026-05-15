const std = @import("std");
const storage = @import("storage.zig");
const resp = @import("resp.zig");
const command = @import("command.zig");

pub fn serve(io: std.Io, allocator: std.mem.Allocator, db: *storage.Database, host: []const u8, port: u16) !void {
    const address = try std.Io.net.IpAddress.parse(host, port);
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    std.debug.print("NovelKV listening on {s}:{d}\n", .{ host, port });

    var group: std.Io.Group = .init;

    while (true) {
        const stream = tcp_server.accept(io) catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        group.concurrent(io, handleConnection, .{ io, allocator, db, stream }) catch {
            stream.close(io);
            continue;
        };
    }
}

fn handleConnection(io: std.Io, allocator: std.mem.Allocator, db: *storage.Database, stream: std.Io.net.Stream) std.Io.Cancelable!void {
    var read_buf: [8192]u8 = undefined;
    var stream_reader = std.Io.net.Stream.reader(stream, io, &read_buf);
    var write_buf: [8192]u8 = undefined;
    var stream_writer = std.Io.net.Stream.writer(stream, io, &write_buf);

    const reader = &stream_reader.interface;
    const writer = &stream_writer.interface;

    while (true) {
        const args = readRespCommand(reader, allocator) catch |err| {
            if (err == error.EndOfStream) break;
            resp.writeError(writer, "ERR protocol error") catch {};
            writer.flush() catch {};
            continue;
        };
        defer {
            for (args) |a| allocator.free(a);
            allocator.free(args);
        }

        const resp_args = allocator.alloc(resp.RespValue, args.len) catch continue;
        defer allocator.free(resp_args);
        for (args, resp_args) |a, *r| {
            r.* = .{ .bulk_string = a };
        }

        const result = command.execute(db, allocator, resp_args);
        writeResult(writer, allocator, result) catch {};
        freeResult(allocator, result);
        writer.flush() catch {};
    }
    stream.close(io);
}

fn readRespCommand(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]const []const u8 {
    const first_line = try reader.takeDelimiterInclusive('\n');
    const line = stripCR(first_line);

    if (line.len == 0) return error.InvalidProtocol;

    if (line[0] == '*') {
        const count = std.fmt.parseInt(usize, line[1..], 10) catch return error.InvalidProtocol;
        var args = try allocator.alloc([]const u8, count);
        var filled: usize = 0;
        errdefer {
            for (args[0..filled]) |a| allocator.free(a);
            allocator.free(args);
        }

        for (0..count) |i| {
            const header = try reader.takeDelimiterInclusive('\n');
            const h = stripCR(header);

            if (h.len == 0 or h[0] != '$') return error.InvalidProtocol;
            const len = std.fmt.parseInt(usize, h[1..], 10) catch return error.InvalidProtocol;

            if (len == 0) {
                args[i] = try allocator.dupe(u8, "");
                _ = reader.takeDelimiterInclusive('\n') catch return error.InvalidProtocol;
            } else {
                const bulk_data = try reader.readAlloc(allocator, len);
                args[i] = bulk_data;
                _ = reader.takeDelimiterInclusive('\n') catch return error.InvalidProtocol;
            }
            filled += 1;
        }
        return args;
    } else {
        var parts: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (parts.items) |a| allocator.free(a);
            parts.deinit(allocator);
        }
        var iter = std.mem.splitSequence(u8, line, " ");
        while (iter.next()) |part| {
            if (part.len > 0) {
                try parts.append(allocator, try allocator.dupe(u8, part));
            }
        }
        if (parts.items.len == 0) return error.InvalidProtocol;
        return parts.toOwnedSlice(allocator);
    }
}

fn stripCR(data: []u8) []u8 {
    var s = data;
    if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}

fn writeResult(writer: *std.Io.Writer, allocator: std.mem.Allocator, result: command.CommandResult) !void {
    switch (result) {
        .ok => {
            try resp.writeSimpleString(writer, "OK");
        },
        .simple_string => |s| {
            try resp.writeSimpleString(writer, s);
        },
        .error_msg => |s| {
            try resp.writeError(writer, s);
        },
        .bulk_string => |maybe_val| {
            if (maybe_val) |val| {
                try resp.writeBulkString(writer, val);
            } else {
                try writer.writeAll("$-1\r\n");
            }
        },
        .owned_string => |val| {
            try resp.writeBulkString(writer, val);
        },
        .integer => |n| {
            try resp.writeInteger(writer, n);
        },
        .nil => {
            try writer.writeAll("$-1\r\n");
        },
        .null_array => {
            try writer.writeAll("*-1\r\n");
        },
        .array => |maybe_items| {
            if (maybe_items) |items| {
                try writer.print("*{d}\r\n", .{items.len});
                for (items) |item| {
                    try writeResult(writer, allocator, item);
                }
            } else {
                try writer.writeAll("*-1\r\n");
            }
        },
    }
}

fn freeResult(allocator: std.mem.Allocator, result: command.CommandResult) void {
    switch (result) {
        .ok, .simple_string, .error_msg, .bulk_string, .integer, .nil, .null_array => {},
        .owned_string => |val| {
            allocator.free(val);
        },
        .array => |maybe_items| {
            if (maybe_items) |items| {
                for (items) |item| {
                    freeResult(allocator, item);
                }
                allocator.free(items);
            }
        },
    }
}
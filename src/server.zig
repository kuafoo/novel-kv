// NovelKV - 专用小说章节文本 KV 存储系统
// TCP 服务模块：监听连接、RESP 协议解析、命令分发与响应序列化
const std = @import("std");
const storage = @import("storage.zig");
const resp = @import("resp.zig");
const command = @import("command.zig");
const replication = @import("replication.zig");
const log = @import("log.zig");
const tls = @import("tls");
const tls_adapter = @import("tls_adapter.zig");

/// 启动 TCP 服务，接受客户端连接并为每个连接启动并发处理协程。
/// shutdown_flag 为 true 时停止接受新连接并退出。
/// 副本模式下同时启动 Replicator 协程连接主节点。
pub fn serve(io: std.Io, allocator: std.mem.Allocator, db: *storage.Database, host: []const u8, port: u16, shutdown_flag: *std.atomic.Value(bool)) !void {
    const address = try std.Io.net.IpAddress.parse(host, port);
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    log.info("Listening on {s}:{d}", .{ host, port });

    var group: std.Io.Group = .init;

    // 副本模式：启动 Replicator 协程
    if (db.is_replica) {
        if (db.repl_config) |config| {
            group.concurrent(io, replication.runReplicator, .{
                io, allocator, db, config, shutdown_flag,
            }) catch {
                log.err("Failed to start replicator", .{});
            };
        }
    }

    while (!shutdown_flag.load(.acquire)) {
        const stream = tcp_server.accept(io) catch |err| {
            if (shutdown_flag.load(.acquire)) break;
            log.warn("Accept error: {}", .{err});
            continue;
        };
        group.concurrent(io, handleConnection, .{ io, allocator, db, stream, port }) catch {
            stream.close(io);
            continue;
        };
    }
    log.info("Server stopped accepting connections", .{});
}

/// 处理单个客户端连接：根据是否启用 TLS 选择加密或明文通道，
/// 然后循环读取 RESP 命令，执行后写回响应。
fn handleConnection(io: std.Io, allocator: std.mem.Allocator, db: *storage.Database, stream: std.Io.net.Stream, port: u16) std.Io.Cancelable!void {
    if (db.tls_auth) |*auth| {
        // TLS 模式：serverFromStream 在栈上创建 Connection（含内部 TCP 缓冲区）
        var rng_impl: std.Random.IoSource = .{ .io = io };
        var tls_conn = tls.serverFromStream(io, stream, .{
            .auth = auth,
            .rng = rng_impl.interface(),
            .now = std.Io.Clock.real.now(io),
        }) catch {
            log.warn("TLS handshake failed", .{});
            stream.close(io);
            return;
        };

        // TlsStream 持有 Connection 指针，桥接为 Reader/Writer 接口
        var tls_stream = tls_adapter.TlsStream.wrap(&tls_conn, stream);
        handleConnectionInner(io, allocator, db, tls_stream.reader(), tls_stream.writer(), stream, port) catch {};
        tls_stream.close(io);
    } else {
        var read_buf: [65536]u8 = undefined;
        var stream_reader = std.Io.net.Stream.reader(stream, io, &read_buf);
        var write_buf: [65536]u8 = undefined;
        var stream_writer = std.Io.net.Stream.writer(stream, io, &write_buf);
        handleConnectionInner(io, allocator, db, &stream_reader.interface, &stream_writer.interface, stream, port) catch {};
        stream.close(io);
    }
}

fn handleConnectionInner(io: std.Io, allocator: std.mem.Allocator, db: *storage.Database, reader: *std.Io.Reader, writer: *std.Io.Writer, stream: std.Io.net.Stream, port: u16) std.Io.Cancelable!void {
    _ = db.total_connections.fetchAdd(1, .monotonic);
    _ = db.current_connections.fetchAdd(1, .monotonic);
    defer _ = db.current_connections.fetchSub(1, .monotonic);

    var client = command.ClientState{ .io = io, .port = port };

    while (true) {
        const args = readRespCommand(reader, allocator) catch |err| {
            if (err == error.EndOfStream) break;
            drainLine(reader) catch break;
            resp.writeError(writer, "ERR protocol error") catch {};
            writer.flush() catch {};
            continue;
        };
        defer {
            for (args) |a| allocator.free(a);
            allocator.free(args);
        }

        // 将原始字节参数包装为 RespValue 以传入命令处理层
        const resp_args = allocator.alloc(resp.RespValue, args.len) catch continue;
        defer allocator.free(resp_args);
        for (args, resp_args) |a, *r| {
            r.* = .{ .bulk_string = a };
        }

        const result = command.execute(db, allocator, resp_args, &client);
        writeResult(writer, allocator, result) catch {};
        freeResult(allocator, result);
        writer.flush() catch {};

        // 副本 PSYNC 后：进入全量同步 + 流式广播
        if (client.needs_fullsync) {
            replication.handleReplicaStream(io, db, reader, writer, stream, &client);
            break;
        }

        if (client.should_quit) break;
    }
}

/// 从 RESP 流中读取一条完整命令，支持 Array（*N\r\n$len\r\ndata\r\n）和 Inline 两种格式。
/// 返回的每个参数都是独立分配的堆内存，由调用方释放。
fn readRespCommand(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]const []const u8 {
    const first_line = try reader.takeDelimiterInclusive('\n');
    const line = stripCR(first_line);

    if (line.len == 0) return error.InvalidProtocol;

    if (line[0] == '*') {
        // RESP Array 格式：*<count>\r\n$<len>\r\n<data>\r\n ...
        const count = std.fmt.parseInt(usize, line[1..], 10) catch return error.InvalidProtocol;
        if (count > 1_000_000) return error.InvalidProtocol;
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
            if (len > 512 * 1024 * 1024) return error.InvalidProtocol;

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
        // Inline 命令格式：以空格分隔的纯文本命令（兼容 redis-cli 单行输入）
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

/// 去除行尾的 \r\n 分隔符
fn stripCR(data: []u8) []u8 {
    var s = data;
    if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}

/// 跳过当前行剩余内容（协议错误恢复用）
fn drainLine(reader: *std.Io.Reader) !void {
    _ = reader.takeDelimiterInclusive('\n') catch return error.EndOfStream;
}

/// 将命令执行结果序列化为 RESP 协议格式写入客户端
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
        .owned_string => |maybe_val| {
            if (maybe_val) |val| {
                try resp.writeBulkString(writer, val);
            } else {
                try writer.writeAll("$-1\r\n");
            }
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

/// 释放 CommandResult 中所有堆分配的内存
fn freeResult(allocator: std.mem.Allocator, result: command.CommandResult) void {
    switch (result) {
        .ok, .simple_string, .error_msg, .integer, .nil, .null_array => {},
        .owned_string => |maybe_val| {
            if (maybe_val) |val| {
                allocator.free(val);
            }
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

// NovelKV - HTTP 只读章节接口
// 签名 URL 验证 + 令牌桶限流 + CORS 支持
const std = @import("std");
const storage = @import("storage.zig");
const log = @import("log.zig");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const flate = std.compress.flate;

// Zstd C API (linked via libzstd.a)
extern fn ZSTD_compress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, srcSize: usize, compressionLevel: c_int) usize;
extern fn ZSTD_compressBound(srcSize: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;

const AcceptEncoding = enum { none, gzip, zstd };
const min_compress_size: usize = 256;

pub const HttpConfig = struct {
    port: u16,
    secret: []const u8,
    sign_ttl: u64 = 3600,
    host: []const u8 = "0.0.0.0",
    rate_limit_burst: f64 = 30,
    rate_limit_refill: f64 = 10,
};

// ============================================================
// 令牌桶限流器
// ============================================================

const RateLimiter = struct {
    const Bucket = struct {
        tokens: f64,
        last_refill_ms: i64,
    };

    const idle_cleanup_ms: i64 = 60_000;

    max_tokens: f64,
    refill_per_sec: f64,
    buckets: std.HashMap([46]u8, Bucket, ArrayHashContext, std.hash_map.default_max_load_percentage),

    const ArrayHashContext = struct {
        pub fn hash(_: @This(), key: [46]u8) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(key[0..]);
            return hasher.final();
        }
        pub fn eql(_: @This(), a: [46]u8, b: [46]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    pub fn init(allocator: std.mem.Allocator, burst: f64, refill: f64) RateLimiter {
        return .{
            .max_tokens = burst,
            .refill_per_sec = refill,
            .buckets = std.HashMap([46]u8, Bucket, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.buckets.deinit();
    }

    // 协程模型下单线程访问，无需 mutex
    pub fn allow(self: *RateLimiter, ip: [46]u8, now_ms: i64) bool {
        if (self.buckets.getPtr(ip)) |bucket| {
            const elapsed_ms = now_ms - bucket.last_refill_ms;
            if (elapsed_ms > 0) {
                const refill = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0 * self.refill_per_sec;
                bucket.tokens = @min(bucket.tokens + refill, self.max_tokens);
                bucket.last_refill_ms = now_ms;
            }
            if (bucket.tokens >= 1.0) {
                bucket.tokens -= 1.0;
                return true;
            }
            return false;
        }
        const entry = self.buckets.getOrPut(ip) catch return true;
        if (entry.found_existing) return true;
        entry.value_ptr.* = .{
            .tokens = self.max_tokens - 1.0,
            .last_refill_ms = now_ms,
        };
        return true;
    }

    pub fn cleanup(self: *RateLimiter, now_ms: i64) void {
        var it = self.buckets.iterator();
        var to_remove = std.ArrayList([46]u8).initCapacity(self.buckets.allocator, 16) catch return;
        defer to_remove.deinit(self.buckets.allocator);
        while (it.next()) |entry| {
            if (now_ms - entry.value_ptr.last_refill_ms > idle_cleanup_ms) {
                to_remove.appendAssumeCapacity(entry.key_ptr.*);
            }
        }
        for (to_remove.items) |key| {
            _ = self.buckets.remove(key);
        }
    }
};

// ============================================================
// HTTP 服务主入口
// ============================================================

pub fn serve(io: std.Io, allocator: std.mem.Allocator, db: *storage.Database, config: HttpConfig, shutdown_flag: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    const address = std.Io.net.IpAddress.parse(config.host, config.port) catch |err| {
        log.err("HTTP: failed to parse address: {}", .{err});
        return;
    };
    var tcp_server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        log.err("HTTP: failed to listen: {}", .{err});
        return;
    };
    defer tcp_server.deinit(io);

    log.info("HTTP chapter API on {s}:{d} (sign TTL: {d}s, burst: {d:.0}, refill: {d:.0}/s)", .{ config.host, config.port, config.sign_ttl, config.rate_limit_burst, config.rate_limit_refill });

    var rate_limiter = RateLimiter.init(allocator, config.rate_limit_burst, config.rate_limit_refill);
    defer rate_limiter.deinit();

    var group: std.Io.Group = .init;

    // 限流器定期清理协程
    group.concurrent(io, rateLimiterCleanup, .{ io, &rate_limiter, shutdown_flag }) catch {};

    while (!shutdown_flag.load(.acquire)) {
        const stream = tcp_server.accept(io) catch |err| {
            if (shutdown_flag.load(.acquire)) break;
            log.warn("HTTP accept error: {}", .{err});
            continue;
        };
        group.concurrent(io, handleConnection, .{ io, allocator, db, config, &rate_limiter, stream }) catch {
            stream.close(io);
            continue;
        };
    }
    log.info("HTTP server stopped", .{});
}

fn rateLimiterCleanup(io: std.Io, rate_limiter: *RateLimiter, shutdown_flag: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    while (!shutdown_flag.load(.acquire)) {
        io.sleep(std.Io.Duration.fromSeconds(30), .real) catch {};
        if (shutdown_flag.load(.acquire)) break;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
        const now_ms = ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
        rate_limiter.cleanup(@intCast(now_ms));
    }
}

// ============================================================
// 连接处理
// ============================================================

fn handleConnection(io: std.Io, allocator: std.mem.Allocator, db: *storage.Database, config: HttpConfig, rate_limiter: *RateLimiter, stream: std.Io.net.Stream) std.Io.Cancelable!void {
    _ = db.total_connections.fetchAdd(1, .monotonic);
    _ = db.current_connections.fetchAdd(1, .monotonic);
    defer _ = db.current_connections.fetchSub(1, .monotonic);

    const client_ip = getClientIp(stream);

    // 限流检查
    {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
        const now_ms = ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
        if (!rate_limiter.allow(client_ip, @intCast(now_ms))) {
            var write_buf: [4096]u8 = undefined;
            var stream_writer = std.Io.net.Stream.writer(stream, io, &write_buf);
            writeErrorResponse(&stream_writer.interface, 429, "Too Many Requests", false, true) catch {};
            stream_writer.interface.flush() catch {};
            stream.close(io);
            return;
        }
    }

    var read_buf: [65536]u8 = undefined;
    var stream_reader = std.Io.net.Stream.reader(stream, io, &read_buf);
    var write_buf: [65536]u8 = undefined;
    var stream_writer = std.Io.net.Stream.writer(stream, io, &write_buf);

    var keep_alive = true;
    while (keep_alive) {
        // 读取请求行
        const request_line = stream_reader.interface.takeDelimiterInclusive('\n') catch {
            break;
        };
        const line = stripCR(request_line);
        if (line.len == 0) break;

        // 解析请求行: METHOD PATH HTTP/1.x
        var line_iter = std.mem.splitSequence(u8, line, " ");
        const method = line_iter.next() orelse break;
        const raw_path = line_iter.next() orelse break;

        // 读取 headers（限制总量 8KB）
        var connection_close = false;
        var accept_encoding: AcceptEncoding = .none;
        var total_header_size: usize = 0;
        while (true) {
            const hdr_line = stream_reader.interface.takeDelimiterInclusive('\n') catch break;
            const hdr = stripCR(hdr_line);
            total_header_size += hdr.len;
            if (total_header_size > 8192) break;
            if (hdr.len == 0) break;
            if (std.mem.startsWith(u8, hdr, "Connection:")) {
                const val = std.mem.trim(u8, hdr["Connection:".len..], " \t");
                var buf: [16]u8 = undefined;
                if (val.len <= buf.len) {
                    const lower = std.ascii.lowerString(&buf, val);
                    if (std.mem.eql(u8, lower, "close")) {
                        connection_close = true;
                    }
                }
            } else if (std.mem.startsWith(u8, hdr, "Accept-Encoding:")) {
                const val = std.mem.trim(u8, hdr["Accept-Encoding:".len..], " \t");
                accept_encoding = parseAcceptEncoding(val);
            }
        }

        handleRequest(allocator, db, config, method, raw_path, &stream_writer.interface, accept_encoding) catch {};

        if (connection_close) keep_alive = false;
    }

    stream_writer.interface.flush() catch {};
    stream.close(io);
}

// ============================================================
// 请求处理
// ============================================================

fn handleRequest(allocator: std.mem.Allocator, db: *storage.Database, config: HttpConfig, method: []const u8, raw_path: []const u8, writer: *std.Io.Writer, encoding: AcceptEncoding) !void {
    // CORS 预检
    if (std.mem.eql(u8, method, "OPTIONS")) {
        try writeCorsPreflight(writer);
        try writer.flush();
        return;
    }

    // 仅允许 GET
    if (!std.mem.eql(u8, method, "GET")) {
        try writeErrorResponse(writer, 405, "Method Not Allowed", true, false);
        try writer.flush();
        return;
    }

    // 解析路径和查询参数
    var path_and_query = std.mem.splitSequence(u8, raw_path, "?");
    const path = path_and_query.next() orelse raw_path;
    const query_str = path_and_query.next() orelse "";

    // 路径必须以 /chapter/ 开头
    if (!std.mem.startsWith(u8, path, "/chapter/")) {
        try writeErrorResponse(writer, 404, "Not Found", true, false);
        try writer.flush();
        return;
    }

    const encoded_key = path["/chapter/".len..];
    if (encoded_key.len == 0) {
        try writeErrorResponse(writer, 400, "Bad Request", true, false);
        try writer.flush();
        return;
    }

    // URL percent-decode 并验证 key
    const chapterkey = percentDecode(allocator, encoded_key) catch {
        try writeErrorResponse(writer, 400, "Bad Request", true, false);
        try writer.flush();
        return;
    };
    defer allocator.free(chapterkey);

    if (!validateChapterKey(chapterkey)) {
        try writeErrorResponse(writer, 400, "Bad Request", true, false);
        try writer.flush();
        return;
    }

    // 解析查询参数
    const params = parseQueryString(query_str);

    // 签名验证
    if (params.sign == null or params.t == null) {
        try writeErrorResponse(writer, 403, "Forbidden", true, false);
        try writer.flush();
        return;
    }

    // 时间戳验证
    const t_val = std.fmt.parseInt(u64, params.t.?, 10) catch {
        try writeErrorResponse(writer, 403, "Forbidden", true, false);
        try writer.flush();
        return;
    };
    {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
        const now: u64 = @intCast(ts.sec);
        const diff: i64 = @as(i64, @intCast(now)) - @as(i64, @intCast(t_val));
        if (@abs(diff) > @as(i64, @intCast(config.sign_ttl))) {
            try writeErrorResponse(writer, 403, "Forbidden", true, false);
            try writer.flush();
            return;
        }
    }

    // HMAC 签名验证
    if (!verifySignature(chapterkey, params.t.?, params.sign.?, config.secret)) {
        try writeErrorResponse(writer, 403, "Forbidden", true, false);
        try writer.flush();
        return;
    }

    // 数据库读取（db0）
    const val = db.get(chapterkey, 0) catch {
        try writeErrorResponse(writer, 500, "Internal Server Error", true, false);
        try writer.flush();
        return;
    };

    if (val) |v| {
        if (encoding != .none and v.len >= min_compress_size) {
            if (compressBody(allocator, v, encoding)) |compressed| {
                defer allocator.free(compressed);
                if (compressed.len < v.len) {
                    try writeResponse(writer, 200, "OK", "text/plain; charset=utf-8", compressed, true, encoding);
                    try writer.flush();
                    storage.freeValue(v);
                    return;
                }
            } else |_| {}
        }
        try writeResponse(writer, 200, "OK", "text/plain; charset=utf-8", v, true, .none);
        try writer.flush();
        storage.freeValue(v);
    } else {
        try writeErrorResponse(writer, 404, "Not Found", true, false);
        try writer.flush();
    }
}

// ============================================================
// 签名验证
// ============================================================

fn verifySignature(chapterkey: []const u8, t_str: []const u8, provided_sign: []const u8, secret: []const u8) bool {
    // hex-decode 提供的签名
    if (provided_sign.len != 64) return false;
    var decoded: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&decoded, provided_sign) catch return false;

    // message = chapterkey ++ t_str
    var msg_buf: [2048]u8 = undefined;
    if (chapterkey.len + t_str.len > msg_buf.len) return false;
    @memcpy(msg_buf[0..chapterkey.len], chapterkey);
    @memcpy(msg_buf[chapterkey.len .. chapterkey.len + t_str.len], t_str);
    const message = msg_buf[0 .. chapterkey.len + t_str.len];

    // 计算 HMAC-SHA256
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, message, secret);

    // 常量时间比较
    return std.crypto.timing_safe.eql([32]u8, mac, decoded);
}

// ============================================================
// Key 验证
// ============================================================

fn validateChapterKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 1024) return false;
    for (key) |c| {
        if (c == 0) return false;
        if (c < 0x20 or c == 0x7F) return false;
        if (c == '/') return false;
    }
    if (std.mem.containsAtLeast(u8, key, 1, "..")) return false;
    return true;
}

// ============================================================
// URL 解析工具
// ============================================================

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const byte = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch {
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try result.append(allocator, byte);
            i += 3;
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

const QueryParams = struct {
    sign: ?[]const u8 = null,
    t: ?[]const u8 = null,
};

fn parseQueryString(query: []const u8) QueryParams {
    var params: QueryParams = .{};
    if (query.len == 0) return params;
    var iter = std.mem.splitSequence(u8, query, "&");
    while (iter.next()) |pair| {
        const eq_idx = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq_idx];
        const val = pair[eq_idx + 1 ..];
        if (std.mem.eql(u8, key, "sign")) {
            params.sign = val;
        } else if (std.mem.eql(u8, key, "t")) {
            params.t = val;
        }
    }
    return params;
}

// ============================================================
// HTTP 响应
// ============================================================

fn writeResponse(writer: *std.Io.Writer, status: u16, status_text: []const u8, content_type: []const u8, body: []const u8, cors: bool, encoding: AcceptEncoding) !void {
    try writer.print("HTTP/1.1 {d} {s}\r\n", .{ status, status_text });
    try writer.print("Content-Type: {s}\r\n", .{content_type});
    if (encoding != .none) {
        try writer.print("Content-Encoding: {s}\r\n", .{@tagName(encoding)});
        try writer.writeAll("Vary: Accept-Encoding\r\n");
    }
    try writer.print("Content-Length: {d}\r\n", .{body.len});
    if (cors) {
        try writer.writeAll("Access-Control-Allow-Origin: *\r\n");
        try writer.writeAll("Access-Control-Allow-Methods: GET\r\n");
    }
    try writer.writeAll("Connection: keep-alive\r\n");
    try writer.writeAll("\r\n");
    try writer.writeAll(body);
}

fn writeErrorResponse(writer: *std.Io.Writer, status: u16, status_text: []const u8, cors: bool, close_conn: bool) !void {
    const body_len = std.fmt.count("{d} {s}", .{ status, status_text });
    try writer.print("HTTP/1.1 {d} {s}\r\n", .{ status, status_text });
    try writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
    try writer.print("Content-Length: {d}\r\n", .{body_len});
    if (cors) {
        try writer.writeAll("Access-Control-Allow-Origin: *\r\n");
        try writer.writeAll("Access-Control-Allow-Methods: GET\r\n");
    }
    if (close_conn) {
        try writer.writeAll("Connection: close\r\n");
    } else {
        try writer.writeAll("Connection: keep-alive\r\n");
    }
    try writer.writeAll("\r\n");
    try writer.print("{d} {s}", .{ status, status_text });
}

fn writeCorsPreflight(writer: *std.Io.Writer) !void {
    try writer.writeAll("HTTP/1.1 204 No Content\r\n");
    try writer.writeAll("Access-Control-Allow-Origin: *\r\n");
    try writer.writeAll("Access-Control-Allow-Methods: GET\r\n");
    try writer.writeAll("Access-Control-Max-Age: 86400\r\n");
    try writer.writeAll("Connection: keep-alive\r\n");
    try writer.writeAll("\r\n");
}

// ============================================================
// 工具函数
// ============================================================

fn getClientIp(stream: std.Io.net.Stream) [46]u8 {
    var result: [46]u8 = [_]u8{0} ** 46;
    var addr: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(stream.socket.handle, @ptrCast(@alignCast(&addr)), &addr_len) catch return result;
    const family: std.posix.sa_family_t = @atomicLoad(std.posix.sa_family_t, &addr.family, .unordered);
    if (family == std.posix.AF.INET) {
        const sin: *std.posix.sockaddr.in = @ptrCast(@alignCast(&addr));
        const ip = std.mem.nativeToBig(u32, sin.addr);
        const a: u8 = @truncate(ip >> 24);
        const b: u8 = @truncate(ip >> 16);
        const c: u8 = @truncate(ip >> 8);
        const d: u8 = @truncate(ip);
        _ = std.fmt.bufPrint(&result, "{d}.{d}.{d}.{d}", .{ a, b, c, d }) catch {};
    } else if (family == std.posix.AF.INET6) {
        const sin6: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(&addr));
        const ip = sin6.addr;
        _ = std.fmt.bufPrint(&result, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
            ip[0], ip[1], ip[2], ip[3], ip[4], ip[5], ip[6], ip[7],
            ip[8], ip[9], ip[10], ip[11], ip[12], ip[13], ip[14], ip[15],
        }) catch {};
    }
    return result;
}

fn stripCR(data: []u8) []u8 {
    var s = data;
    if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}

// ============================================================
// 压缩支持 (gzip + zstd)
// ============================================================

fn parseAcceptEncoding(header: []const u8) AcceptEncoding {
    var have_gzip = false;
    var have_zstd = false;
    var iter = std.mem.splitSequence(u8, header, ",");
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        // strip quality value: "gzip;q=1.0" → "gzip"
        const semi = std.mem.indexOfScalar(u8, trimmed, ';');
        const enc = if (semi) |i| trimmed[0..i] else trimmed;
        var buf: [16]u8 = undefined;
        if (enc.len <= buf.len) {
            const lower = std.ascii.lowerString(&buf, enc);
            if (std.mem.eql(u8, lower, "gzip") or std.mem.eql(u8, lower, "deflate")) {
                have_gzip = true;
            } else if (std.mem.eql(u8, lower, "zstd")) {
                have_zstd = true;
            } else if (std.mem.eql(u8, lower, "*")) {
                have_gzip = true;
                have_zstd = true;
            }
        }
    }
    if (have_zstd) return .zstd;
    if (have_gzip) return .gzip;
    return .none;
}

fn compressBody(allocator: std.mem.Allocator, data: []const u8, encoding: AcceptEncoding) ![]u8 {
    return switch (encoding) {
        .gzip => try gzipCompress(allocator, data),
        .zstd => try zstdCompress(allocator, data),
        .none => unreachable,
    };
}

fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var alloc_writer = try std.Io.Writer.Allocating.initCapacity(allocator, data.len / 2 + 64);
    errdefer {
        const buf = alloc_writer.writer.buffer;
        if (buf.len > 0) allocator.rawFree(buf, alloc_writer.alignment, @returnAddress());
    }

    var work_buf: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(
        &alloc_writer.writer,
        &work_buf,
        .gzip,
        flate.Compress.Options.level_6,
    );
    try compressor.writer.writeAll(data);
    try compressor.finish();

    return try alloc_writer.toOwnedSlice();
}

fn zstdCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const bound = ZSTD_compressBound(data.len);
    const out_buf = try allocator.alloc(u8, bound);
    errdefer allocator.free(out_buf);

    const result = ZSTD_compress(out_buf.ptr, bound, data.ptr, data.len, 3);
    if (ZSTD_isError(result) != 0) return error.CompressionFailed;

    if (allocator.realloc(out_buf, result)) |resized| {
        return resized;
    } else |_| {
        return out_buf[0..result];
    }
}

// NovelKV - 主从复制模块
// 参考 Redis 6.0 简化设计：应用层命令复制，最终一致性
// 主端：Oplog 环形缓冲 + 副本广播；副本端：握手 → 全量同步 → 流式接收
const std = @import("std");
const storage = @import("storage.zig");
const resp = @import("resp.zig");
const command = @import("command.zig");
const log = @import("log.zig");
const tls = @import("tls");
const tls_adapter = @import("tls_adapter.zig");

pub const ReplicaState = enum {
    disconnected,
    connecting,
    handshake,
    fullsync,
    synced,
};

// 需要复制到副本的写命令集合
const write_command_set = std.StaticStringMap(void).initComptime(.{
    .{ "set", {} },
    .{ "del", {} },
    .{ "unlink", {} },
    .{ "mset", {} },
    .{ "append", {} },
    .{ "setnx", {} },
    .{ "getset", {} },
    .{ "setrange", {} },
    .{ "incr", {} },
    .{ "incrby", {} },
    .{ "decr", {} },
    .{ "decrby", {} },
    .{ "flushdb", {} },
    .{ "flushall", {} },
    .{ "hset", {} },
    .{ "hdel", {} },
});

pub fn isWriteCommand(cmd: []const u8) bool {
    return write_command_set.has(cmd);
}

/// 将 RespValue 数组编码为 RESP 字节流（用于 oplog 存储和广播）
pub fn encodeRespCommand(allocator: std.mem.Allocator, args: []const resp.RespValue) ![]u8 {
    // 计算上界大小
    var size: usize = 32;
    for (args) |arg| {
        size += 32;
        switch (arg) {
            .bulk_string => |s| {
                if (s) |v| size += v.len;
            },
            .simple_string => |s| size += s.len,
            .error_msg => |s| size += s.len,
            else => {},
        }
    }
    var buf = try allocator.alloc(u8, size);
    var pos: usize = 0;

    const writeRaw = struct {
        fn f(b: []u8, p: *usize, data: []const u8) void {
            @memcpy(b[p.*..][0..data.len], data);
            p.* += data.len;
        }
    }.f;

    // Array header: *N\r\n
    pos += (std.fmt.bufPrint(buf[pos..], "*{d}\r\n", .{args.len}) catch return error.OutOfMemory).len;

    for (args) |arg| {
        switch (arg) {
            .bulk_string => |maybe_s| {
                if (maybe_s) |s| {
                    pos += (std.fmt.bufPrint(buf[pos..], "${d}\r\n", .{s.len}) catch return error.OutOfMemory).len;
                    writeRaw(buf, &pos, s);
                    writeRaw(buf, &pos, "\r\n");
                } else {
                    writeRaw(buf, &pos, "$-1\r\n");
                }
            },
            .simple_string => |s| {
                writeRaw(buf, &pos, "+");
                writeRaw(buf, &pos, s);
                writeRaw(buf, &pos, "\r\n");
            },
            .error_msg => |s| {
                writeRaw(buf, &pos, "-");
                writeRaw(buf, &pos, s);
                writeRaw(buf, &pos, "\r\n");
            },
            .integer => |n| {
                pos += (std.fmt.bufPrint(buf[pos..], ":{d}\r\n", .{n}) catch return error.OutOfMemory).len;
            },
            .array => {
                writeRaw(buf, &pos, "*-1\r\n");
            },
        }
    }

    // 缩减到实际使用大小
    return allocator.realloc(buf, pos) catch buf[0..pos];
}

// ---- Oplog 环形缓冲区 ----

const OplogEntry = struct {
    seq: u64,
    data: []const u8,
};

pub const OPLOG_CAPACITY: usize = 1024;

pub const Oplog = struct {
    entries: [OPLOG_CAPACITY]?OplogEntry,
    head: usize = 0,
    count: usize = 0,

    pub fn init() Oplog {
        return .{ .entries = @splat(null) };
    }

    pub fn push(self: *Oplog, allocator: std.mem.Allocator, seq: u64, data: []const u8) void {
        if (self.entries[self.head]) |old| {
            allocator.free(old.data);
        }
        self.entries[self.head] = .{ .seq = seq, .data = data };
        self.head = (self.head + 1) % OPLOG_CAPACITY;
        if (self.count < OPLOG_CAPACITY) self.count += 1;
    }

    /// 回放 seq > since_seq 的所有条目到 writer
    pub fn replaySince(self: *Oplog, writer: *std.Io.Writer, since_seq: u64) !void {
        if (self.count == 0) return;
        const start = if (self.count < OPLOG_CAPACITY) 0 else self.head;
        for (0..self.count) |i| {
            const idx = (start + i) % OPLOG_CAPACITY;
            if (self.entries[idx]) |entry| {
                if (entry.seq > since_seq) {
                    try writer.writeAll(entry.data);
                }
            }
        }
    }

    pub fn deinit(self: *Oplog, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            if (entry.*) |e| {
                allocator.free(e.data);
                entry.* = null;
            }
        }
    }
};

// ---- 主端副本连接跟踪 ----

pub const ReplicaConn = struct {
    writer: *std.Io.Writer,
    stream: std.Io.net.Stream,
    replica_port: u16,
    last_seq: u64 = 0,
    state: ReplicaState = .handshake,
    active: bool = true,
};

pub const ReplicaList = struct {
    conns: std.ArrayList(*ReplicaConn),
    mutex: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ReplicaList {
        return .{ .conns = std.ArrayList(*ReplicaConn).empty, .allocator = allocator };
    }

    pub fn deinit(self: *ReplicaList) void {
        self.conns.deinit(self.allocator);
    }

    pub fn add(self: *ReplicaList, io: std.Io, conn: *ReplicaConn) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.conns.append(self.allocator, conn) catch {};
    }

    pub fn remove(self: *ReplicaList, io: std.Io, conn: *ReplicaConn) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.conns.items, 0..) |c, i| {
            if (c == conn) {
                _ = self.conns.orderedRemove(i);
                break;
            }
        }
        conn.active = false;
    }

    pub fn count(self: *ReplicaList, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.conns.items.len;
    }
};

// ---- 主端复制状态 ----

pub const MasterState = struct {
    oplog: Oplog,
    replicas: ReplicaList,
    current_seq: std.atomic.Value(u64),
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) MasterState {
        return .{
            .oplog = Oplog.init(),
            .replicas = ReplicaList.init(allocator),
            .current_seq = std.atomic.Value(u64).init(0),
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *MasterState) void {
        self.oplog.deinit(self.allocator);
        self.replicas.deinit();
    }

    /// 记录写命令到 oplog 并广播给所有已连接副本。
    /// db_index 用于在非 db0 时插入 SELECT 命令，保证副本在正确的数据库上执行。
    pub fn recordAndBroadcast(self: *MasterState, args: []const resp.RespValue, db_index: usize) void {
        const encoded = encodeRespCommand(self.allocator, args) catch return;
        const seq = self.current_seq.fetchAdd(1, .monotonic) + 1;

        // 如果不是 db0，先编码 SELECT 命令
        var select_encoded: ?[]const u8 = null;
        if (db_index > 0) {
            const idx_str = std.fmt.allocPrint(self.allocator, "{d}", .{db_index}) catch null;
            if (idx_str) |s| {
                defer self.allocator.free(s);
                select_encoded = std.fmt.allocPrint(self.allocator, "*2\r\n$6\r\nSELECT\r\n${d}\r\n{s}\r\n", .{ s.len, s }) catch null;
            }
        }

        self.replicas.mutex.lockUncancelable(self.io);
        // encoded 的所有权转移给 oplog（由 oplog 负责释放）
        // encoded 的所有权转移给 oplog（由 oplog 负责释放）
        self.oplog.push(self.allocator, seq, encoded);

        for (self.replicas.conns.items) |replica| {
            if (replica.active and replica.state == .synced) {
                if (select_encoded) |se| {
                    replica.writer.writeAll(se) catch {
                        replica.active = false;
                        continue;
                    };
                }
                replica.writer.writeAll(encoded) catch {
                    log.warn("Write to replica port {d} failed, marking disconnected", .{replica.replica_port});
                    replica.active = false;
                    continue;
                };
                replica.writer.flush() catch {
                    replica.active = false;
                };
                replica.last_seq = seq;
            }
        }
        self.replicas.mutex.unlock(self.io);

        // select_encoded 是临时分配的，由 recordAndBroadcast 负责释放
        if (select_encoded) |se| self.allocator.free(se);
    }

    /// 全量同步：使用 Snapshot 遍历所有 CF，以 RESP SET 命令流式发送给副本
    pub fn performFullSync(self: *MasterState, db: *storage.Database, writer: *std.Io.Writer, replica: *ReplicaConn) !void {
        replica.state = .fullsync;

        // 记录同步起始 seq，用于后续回放增量
        const sync_start_seq = self.current_seq.load(.monotonic);

        // 第一遍：统计总 key 数
        var total_count: u64 = 0;
        for (0..storage.MAX_DATABASES) |cf_idx| {
            const keys = db.scanKeys(db.allocator, "", cf_idx, std.math.maxInt(usize)) catch &.{};
            total_count += keys.len;
            for (keys) |k| db.allocator.free(k);
            db.allocator.free(keys);
        }

        // 发送 DUMPSTART
        writer.print("+DUMPSTART {d} {d}\r\n", .{ total_count, sync_start_seq }) catch return error.WriteFailed;
        writer.flush() catch return error.WriteFailed;

        // 第二遍：逐 CF 发送 SET 命令
        for (0..storage.MAX_DATABASES) |cf_idx| {
            const pairs = db.scanKeyValues(db.allocator, "", cf_idx, std.math.maxInt(usize)) catch &.{};
            defer {
                for (pairs) |p| {
                    db.allocator.free(p.key);
                    db.allocator.free(p.value);
                }
                db.allocator.free(pairs);
            }

            if (pairs.len == 0) continue;

            // 有数据时才发送 SELECT 切换数据库
            if (cf_idx > 0) {
                writer.writeAll("*2\r\n$6\r\nSELECT\r\n") catch return error.WriteFailed;
                const idx_str = std.fmt.allocPrint(self.allocator, "{d}", .{cf_idx}) catch return error.WriteFailed;
                defer self.allocator.free(idx_str);
                writer.print("${d}\r\n{s}\r\n", .{ idx_str.len, idx_str }) catch return error.WriteFailed;
            }

            for (pairs) |p| {
                writer.writeAll("*3\r\n$3\r\nSET\r\n") catch return error.WriteFailed;
                writer.print("${d}\r\n", .{p.key.len}) catch return error.WriteFailed;
                writer.writeAll(p.key) catch return error.WriteFailed;
                writer.writeAll("\r\n") catch return error.WriteFailed;
                writer.print("${d}\r\n", .{p.value.len}) catch return error.WriteFailed;
                writer.writeAll(p.value) catch return error.WriteFailed;
                writer.writeAll("\r\n") catch return error.WriteFailed;
            }
            writer.flush() catch return error.WriteFailed;
        }

        // 加锁：发送 DUMPEND + 回放增量 + 注册副本，保证不遗漏写命令
        self.replicas.mutex.lockUncancelable(self.io);
        writer.writeAll("+DUMPEND\r\n") catch {
            self.replicas.mutex.unlock(self.io);
            return error.WriteFailed;
        };
        // 回放同步期间产生的写命令
        self.oplog.replaySince(writer, sync_start_seq) catch {};
        writer.flush() catch {
            self.replicas.mutex.unlock(self.io);
            return error.WriteFailed;
        };

        replica.state = .synced;
        replica.last_seq = self.current_seq.load(.monotonic);
        self.replicas.conns.append(self.allocator, replica) catch {};
        self.replicas.mutex.unlock(self.io);

        log.info("Full sync completed for replica port {d} ({d} keys)", .{ replica.replica_port, total_count });
    }
};

// ---- 主端：处理副本连接流 ----

/// 在 handleConnection 中 PSYNC 后调用：执行全量同步，注册副本，进入保活循环
pub fn handleReplicaStream(
    io: std.Io,
    db: *storage.Database,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    stream: std.Io.net.Stream,
    client: *command.ClientState,
) void {
    const repl = db.repl orelse {
        log.err("Replication not initialized but replica connected", .{});
        return;
    };

    var replica_conn: ReplicaConn = .{
        .writer = writer,
        .stream = stream,
        .replica_port = client.replica_port,
    };

    // 执行全量同步
    repl.performFullSync(db, writer, &replica_conn) catch {
        log.err("Full sync failed for replica port {d}", .{client.replica_port});
        return;
    };

    // 保活循环：只读取副本发来的数据（PING 等），不回写
    // 写命令广播由 recordAndBroadcast 通过 replica_conn.writer 写入
    while (!client.should_quit) {
        _ = reader.takeDelimiterInclusive('\n') catch {
            log.info("Replica port {d} disconnected", .{client.replica_port});
            break;
        };
    }

    // 清理：从副本列表移除
    repl.replicas.remove(io, &replica_conn);
    log.info("Replica port {d} removed from replica list", .{client.replica_port});
}

// ---- 副本端 ----

pub const ReplicaConfig = struct {
    master_host: []const u8,
    master_port: u16,
    masterauth: ?[]const u8 = null,
    local_port: u16 = 6379,
};

/// 副本端主循环：连接 → 握手 → 全量同步 → 流式接收，断线自动重连
pub fn runReplicator(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *storage.Database,
    config: ReplicaConfig,
    shutdown_flag: *std.atomic.Value(bool),
) void {
    log.info("Replicator started, connecting to master {s}:{d}", .{ config.master_host, config.master_port });

    while (!shutdown_flag.load(.acquire)) {
        // 连接主节点
        const address = std.Io.net.IpAddress.parse(config.master_host, config.master_port) catch {
            log.warn("Cannot resolve master {s}:{d}, retrying in 5s...", .{ config.master_host, config.master_port });
            std.Io.sleep(io, .fromSeconds(5), .awake) catch {};
            continue;
        };

        var read_buf: [65536]u8 = undefined;
        var write_buf: [65536]u8 = undefined;

        const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch {
            log.warn("Cannot connect to master {s}:{d}, retrying in 5s...", .{ config.master_host, config.master_port });
            std.Io.sleep(io, .fromSeconds(5), .awake) catch {};
            continue;
        };

        // TLS 模式：包装连接
        const use_tls = db.tls_config != null and db.tls_config.?.replica_tls;

        if (use_tls) {
            var rng_impl: std.Random.IoSource = .{ .io = io };

            // Determine TLS verification strategy before connecting
            var tls_conn = blk: {
                // If CA file specified, use it for verification
                if (db.tls_config) |tc| {
                    if (tc.ca_file) |ca_path| {
                        const ca = tls.config.cert.fromFilePathAbsolute(allocator, io, ca_path) catch {
                            log.warn("Failed to load CA certificate: {s}", .{ca_path});
                            break :blk null;
                        };
                        break :blk tls.clientFromStream(io, stream, .{
                            .host = config.master_host,
                            .root_ca = ca,
                            .rng = rng_impl.interface(),
                            .now = std.Io.Clock.real.now(io),
                        }) catch null;
                    }
                }
                // No CA file: skip verification (self-signed certs)
                break :blk tls.clientFromStream(io, stream, .{
                    .host = config.master_host,
                    .root_ca = .empty,
                    .insecure_skip_verify = true,
                    .rng = rng_impl.interface(),
                    .now = std.Io.Clock.real.now(io),
                }) catch null;
            };

            if (tls_conn) |*conn| {
                var tls_stream = tls_adapter.TlsStream.wrap(conn, stream);

                log.info("Connected to master {s}:{d} (TLS)", .{ config.master_host, config.master_port });

                const reader = tls_stream.reader();
                const writer = tls_stream.writer();

                if (doHandshake(reader, writer, config)) {
                    if (doFullSyncAndStream(db, allocator, reader, config, shutdown_flag)) {
                        tls_stream.close(io);
                        return;
                    }
                }

                tls_stream.close(io);
            } else {
                log.warn("TLS connection to master failed, retrying in 5s...", .{});
                stream.close(io);
                std.Io.sleep(io, .fromSeconds(5), .awake) catch {};
                continue;
            }
        } else {
            var stream_reader = std.Io.net.Stream.reader(stream, io, &read_buf);
            var stream_writer = std.Io.net.Stream.writer(stream, io, &write_buf);
            const reader = &stream_reader.interface;
            const writer = &stream_writer.interface;

            log.info("Connected to master {s}:{d}", .{ config.master_host, config.master_port });

            if (doHandshake(reader, writer, config)) {
                if (doFullSyncAndStream(db, allocator, reader, config, shutdown_flag)) {
                    stream.close(io);
                    return;
                }
            }

            stream.close(io);
        }

        // 连接断开，清理并重连
        log.warn("Lost connection to master, reconnecting in 5s...", .{});
        db.is_replica_connected.store(false, .release);
        std.Io.sleep(io, .fromSeconds(5), .awake) catch {};
    }
}

/// 握手阶段：PING → AUTH → REPLCONF → PSYNC
fn doHandshake(reader: *std.Io.Reader, writer: *std.Io.Writer, config: ReplicaConfig) bool {
    // PING
    writer.writeAll("*1\r\n$4\r\nPING\r\n") catch return false;
    writer.flush() catch return false;
    const pong = reader.takeDelimiterInclusive('\n') catch return false;
    if (pong.len < 1) return false;
    // Accept +PONG or -NOAUTH (when master requires auth, we'll AUTH next)
    if (pong[0] != '+' and !(pong[0] == '-' and config.masterauth != null)) {
        log.err("Handshake: expected +PONG, got {s}", .{pong});
        return false;
    }

    // AUTH（可选）
    if (config.masterauth) |pass| {
        writer.print("*2\r\n$4\r\nAUTH\r\n${d}\r\n{s}\r\n", .{ pass.len, pass }) catch return false;
        writer.flush() catch return false;
        const auth_resp = reader.takeDelimiterInclusive('\n') catch return false;
        if (auth_resp.len < 1 or auth_resp[0] != '+') {
            log.err("Handshake: AUTH failed", .{});
            return false;
        }
    }

    // REPLCONF listening-port
    const port_str = std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{config.local_port}) catch "0";
    defer std.heap.page_allocator.free(port_str);
    writer.print("*3\r\n$8\r\nREPLCONF\r\n$14\r\nlistening-port\r\n${d}\r\n{s}\r\n", .{ port_str.len, port_str }) catch return false;
    writer.flush() catch return false;
    const replconf_resp = reader.takeDelimiterInclusive('\n') catch return false;
    if (replconf_resp.len < 1 or replconf_resp[0] != '+') {
        log.err("Handshake: REPLCONF failed", .{});
        return false;
    }

    // PSYNC
    writer.writeAll("*3\r\n$5\r\nPSYNC\r\n$1\r\n?\r\n$1\r\n0\r\n") catch return false;
    writer.flush() catch return false;

    // 读取 DUMPSTART 响应
    const dumpstart = reader.takeDelimiterInclusive('\n') catch return false;
    if (dumpstart.len < 1 or dumpstart[0] != '+') {
        log.err("Handshake: expected +DUMPSTART, got {s}", .{dumpstart});
        return false;
    }
    // +DUMPSTART <count> <seq>\r\n
    log.info("Handshake completed, starting full sync", .{});

    return true;
}

/// 全量同步 + 流式接收循环
fn doFullSyncAndStream(
    db: *storage.Database,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    config: ReplicaConfig,
    shutdown_flag: *std.atomic.Value(bool),
) bool {
    // 接收全量同步数据：逐条 RESP 命令，直到收到 +DUMPEND
    var current_db: usize = 0;
    var synced_count: u64 = 0;

    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return false;
        const stripped = stripCR(line);

        if (stripped.len == 0) continue;

        // +DUMPEND 表示全量同步完成
        if (stripped[0] == '+' and std.mem.eql(u8, stripped, "+DUMPEND")) {
            log.info("Full sync completed ({d} commands applied)", .{synced_count});
            break;
        }

        // +DUMPSTART 已在握手阶段消费，忽略意外出现的情况
        if (stripped[0] == '+') continue;

        // RESP 命令：解析并执行
        if (stripped[0] == '*') {
            const cmd_args = parseRespCommand(reader, allocator, stripped) catch continue;
            defer {
                for (cmd_args) |a| allocator.free(a);
                allocator.free(cmd_args);
            }

            if (cmd_args.len == 0) continue;

            // SELECT 命令：切换当前数据库
            var buf_cmd: [16]u8 = undefined;
            const cmd_lower = std.ascii.lowerString(&buf_cmd, cmd_args[0]);
            if (std.mem.eql(u8, cmd_lower, "select")) {
                if (cmd_args.len > 1) {
                    current_db = std.fmt.parseInt(usize, cmd_args[1], 10) catch current_db;
                }
                continue;
            }

            // 构造 RespValue 参数并执行
            const resp_args = allocator.alloc(resp.RespValue, cmd_args.len) catch continue;
            defer allocator.free(resp_args);
            for (cmd_args, resp_args) |a, *r| {
                r.* = .{ .bulk_string = a };
            }

            var client = command.ClientState{
                .io = undefined,
                .port = config.local_port,
                .is_replication_apply = true,
                .db_index = current_db,
            };
            const result = command.execute(db, allocator, resp_args, &client);
            freeCommandResult(allocator, result);
            synced_count += 1;
        }
    }

    db.is_replica_connected.store(true, .release);
    log.info("Entering streaming replication mode", .{});

    // 流式接收循环：持续接收主节点广播的写命令
    while (!shutdown_flag.load(.acquire)) {
        const line = reader.takeDelimiterInclusive('\n') catch return false;
        const stripped = stripCR(line);

        if (stripped.len == 0) continue;
        if (stripped[0] == '+') continue; // 忽略简单字符串

        if (stripped[0] == '*') {
            const cmd_args = parseRespCommand(reader, allocator, stripped) catch continue;
            defer {
                for (cmd_args) |a| allocator.free(a);
                allocator.free(cmd_args);
            }

            if (cmd_args.len == 0) continue;

            var buf_cmd: [16]u8 = undefined;
            const cmd_lower = std.ascii.lowerString(&buf_cmd, cmd_args[0]);
            if (std.mem.eql(u8, cmd_lower, "select")) {
                if (cmd_args.len > 1) {
                    current_db = std.fmt.parseInt(usize, cmd_args[1], 10) catch current_db;
                }
                continue;
            }

            const resp_args = allocator.alloc(resp.RespValue, cmd_args.len) catch continue;
            defer allocator.free(resp_args);
            for (cmd_args, resp_args) |a, *r| {
                r.* = .{ .bulk_string = a };
            }

            var client = command.ClientState{
                .io = undefined,
                .port = config.local_port,
                .is_replication_apply = true,
                .db_index = current_db,
            };
            const result = command.execute(db, allocator, resp_args, &client);
            freeCommandResult(allocator, result);
        }
    }

    return true;
}

/// 解析 RESP 命令：从已读取的 *N\r\n 行开始，读取后续 bulk string
fn parseRespCommand(reader: *std.Io.Reader, allocator: std.mem.Allocator, first_line: []const u8) ![]const []const u8 {
    const count = std.fmt.parseInt(usize, first_line[1..], 10) catch return error.InvalidProtocol;
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
}

fn stripCR(data: []u8) []u8 {
    var s = data;
    if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}

fn freeCommandResult(allocator: std.mem.Allocator, result: command.CommandResult) void {
    switch (result) {
        .ok, .simple_string, .error_msg, .integer, .nil, .null_array => {},
        .owned_string => |maybe_val| {
            if (maybe_val) |val| allocator.free(val);
        },
        .array => |maybe_items| {
            if (maybe_items) |items| {
                for (items) |item| freeCommandResult(allocator, item);
                allocator.free(items);
            }
        },
        .map_pairs => |maybe_pairs| {
            if (maybe_pairs) |pairs| {
                for (pairs) |p| {
                    allocator.free(p.k);
                    allocator.free(p.v);
                }
                allocator.free(pairs);
            }
        },
    }
}

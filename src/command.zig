// NovelKV - 专用小说章节文本 KV 存储系统
// 命令处理模块：RESP 命令分发与执行，兼容 Redis 部分必要协议
const std = @import("std");
const storage = @import("storage.zig");
const resp = @import("resp.zig");
const replication = @import("replication.zig");
const log = @import("log.zig");

/// 每个客户端连接的独立状态
pub const ClientState = struct {
    db_index: usize = 0,
    should_quit: bool = false,
    io: std.Io = undefined,
    port: u16 = 0,
    authenticated: bool = false,
    is_replica_conn: bool = false,
    needs_fullsync: bool = false,
    replica_port: u16 = 0,
    is_replication_apply: bool = false,
};

/// 命令执行结果，携带类型标签以便 RESP 层正确序列化。
/// owned_string 和 array 中的数据需要调用方通过 freeResult 释放。
pub const CommandResult = union(enum) {
    ok: void,
    owned_string: ?[]const u8,
    integer: i64,
    simple_string: []const u8,
    error_msg: []const u8,
    nil: void,
    null_array: void,
    array: ?[]const CommandResult,
};

const CmdFn = *const fn (*storage.Database, std.mem.Allocator, []resp.RespValue, *ClientState) CommandResult;

// 命令注册表：命令名 → 处理函数。保持与 Redis SDK/客户端的兼容性。
const cmd_table = std.StaticStringMap(CmdFn).initComptime(.{
    .{ "ping", &cmdPing },
    .{ "get", &cmdGet },
    .{ "set", &cmdSet },
    .{ "del", &cmdDel },
    .{ "unlink", &cmdDel },
    .{ "exists", &cmdExists },
    .{ "mget", &cmdMGet },
    .{ "mset", &cmdMSet },
    .{ "strlen", &cmdStrlen },
    .{ "append", &cmdAppend },
    .{ "incr", &cmdIncr },
    .{ "incrby", &cmdIncrby },
    .{ "decr", &cmdDecr },
    .{ "decrby", &cmdDecrby },
    .{ "getrange", &cmdGetRange },
    .{ "setrange", &cmdSetRange },
    .{ "command", &cmdCommand },
    .{ "select", &cmdSelect },
    .{ "quit", &cmdQuit },
    .{ "info", &cmdInfo },
    .{ "config", &cmdConfig },
    .{ "dbsize", &cmdDbsize },
    .{ "flushdb", &cmdFlushdb },
    .{ "flushall", &cmdFlushall },
    .{ "type", &cmdType },
    .{ "object", &cmdObject },
    .{ "ttl", &cmdTtl },
    .{ "pttl", &cmdTtl },
    .{ "persist", &cmdPersist },
    .{ "expire", &cmdExpire },
    .{ "pexpire", &cmdExpire },
    .{ "setnx", &cmdSetNx },
    .{ "getset", &cmdGetSet },
    .{ "echo", &cmdEcho },
    .{ "save", &cmdSave },
    .{ "bgsave", &cmdBgsave },
    .{ "auth", &cmdAuth },
    .{ "scan", &cmdScan },
    .{ "replconf", &cmdReplconf },
    .{ "psync", &cmdPsync },
});

/// 命令执行入口：查找命令处理函数，依次检查禁用列表和认证状态。
pub fn execute(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    if (args.len == 0) return CommandResult{ .error_msg = "ERR empty command" };

    const command = getStringArg(args, 0) orelse "";
    const cmd = std.ascii.allocLowerString(allocator, command) catch {
        return CommandResult{ .error_msg = "ERR out of memory" };
    };
    defer allocator.free(cmd);

    const handler = cmd_table.get(cmd) orelse return CommandResult{ .error_msg = "ERR unknown command" };

    if (db.isCommandDisabled(cmd)) {
        return CommandResult{ .error_msg = "ERR unknown command" };
    }

    // 设置了密码时，除 AUTH/QUIT 外的命令必须先通过认证
    if (db.password) |_| {
        if (!client.authenticated and
            !std.mem.eql(u8, cmd, "auth") and
            !std.mem.eql(u8, cmd, "quit"))
        {
            return CommandResult{ .error_msg = "NOAUTH Authentication required" };
        }
    }

    // 副本模式：拒绝写命令（复制回放除外）
    if (db.is_replica and replication.isWriteCommand(cmd) and !client.is_replication_apply) {
        return CommandResult{ .error_msg = "READONLY You can't write against a read only replica" };
    }

    const result = handler(db, allocator, args, client);

    // 主端：写命令记录到 oplog 并广播给副本
    if (!db.is_replica and db.repl != null and replication.isWriteCommand(cmd)) {
        db.repl.?.recordAndBroadcast(args, client.db_index);
    }

    return result;
}

/// 安全获取 bulk_string 类型参数，越界或类型不匹配返回 null
fn getStringArg(args: []resp.RespValue, index: usize) ?[]const u8 {
    if (index >= args.len) return null;
    return switch (args[index]) {
        .bulk_string => |s| s,
        else => null,
    };
}

// ============================================================
// 连接与协议命令
// ============================================================

fn cmdPing(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = client;
    if (args.len > 1) {
        const msg = getStringArg(args, 1) orelse "";
        const duped = allocator.dupe(u8, msg) catch return CommandResult{ .error_msg = "ERR out of memory" };
        return CommandResult{ .owned_string = duped };
    }
    return CommandResult{ .simple_string = "PONG" };
}

fn cmdEcho(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = client;
    const msg = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'echo' command" };
    const duped = allocator.dupe(u8, msg) catch return CommandResult{ .error_msg = "ERR out of memory" };
    return CommandResult{ .owned_string = duped };
}

fn cmdSelect(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = allocator;
    const index_str = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'select' command" };
    const index = std.fmt.parseInt(usize, index_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer or out of range" };
    if (index >= storage.MAX_DATABASES) return CommandResult{ .error_msg = "ERR DB index is out of range" };
    client.db_index = index;
    return CommandResult{ .simple_string = "OK" };
}

fn cmdQuit(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = args;
    _ = allocator;
    client.should_quit = true;
    return CommandResult{ .simple_string = "OK" };
}

fn cmdAuth(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = allocator;
    const password = db.password orelse return CommandResult{ .error_msg = "ERR Client sent AUTH, but no password is set" };
    const arg = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'auth' command" };
    if (std.mem.eql(u8, arg, password)) {
        client.authenticated = true;
        return CommandResult{ .simple_string = "OK" };
    }
    return CommandResult{ .error_msg = "ERR invalid password" };
}

// ============================================================
// 基础读写命令
// ============================================================

fn cmdGet(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'get' command" };
    const val = db.get(key, client.db_index) catch return CommandResult{ .error_msg = "ERR read failed" };
    if (val) |v| {
        // RocksDB 返回的值需要拷贝后释放，owned_string 由 freeResult 释放
        const duped = allocator.dupe(u8, v) catch {
            storage.freeValue(v);
            return CommandResult{ .error_msg = "ERR out of memory" };
        };
        storage.freeValue(v);
        return CommandResult{ .owned_string = duped };
    }
    return CommandResult{ .nil = {} };
}

fn cmdSet(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = allocator;
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'set' command" };
    const value = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'set' command" };

    // 解析 NX/XX 及 TTL 相关选项（TTL 选项静默跳过，不实际生效）
    var nx: bool = false;
    var xx: bool = false;
    var i: usize = 3;
    while (i < args.len) {
        const opt = getStringArg(args, i) orelse break;
        var buf: [16]u8 = undefined;
        const opt_lower = std.ascii.lowerString(&buf, opt);

        if (std.mem.eql(u8, opt_lower, "nx")) {
            nx = true;
            i += 1;
        } else if (std.mem.eql(u8, opt_lower, "xx")) {
            xx = true;
            i += 1;
        } else if (std.mem.eql(u8, opt_lower, "ex") or std.mem.eql(u8, opt_lower, "px") or std.mem.eql(u8, opt_lower, "exat") or std.mem.eql(u8, opt_lower, "pxat") or std.mem.eql(u8, opt_lower, "keepttl")) {
            i += 1;
            if (std.mem.eql(u8, opt_lower, "ex") or std.mem.eql(u8, opt_lower, "px") or std.mem.eql(u8, opt_lower, "exat") or std.mem.eql(u8, opt_lower, "pxat")) {
                i += 1; // 跳过 TTL 数值参数
            }
        } else if (std.mem.eql(u8, opt_lower, "get")) {
            i += 1;
        } else {
            return CommandResult{ .error_msg = "ERR syntax error" };
        }
    }

    if (nx and xx) return CommandResult{ .error_msg = "ERR syntax error" };

    // NX/XX 是复合操作（读后写），需要写锁保证原子性
    if (nx or xx) {
        db.wlock(client.io);
        defer db.wunlock(client.io);

        const existing = db.get(key, client.db_index) catch return CommandResult{ .error_msg = "ERR read failed" };
        if (existing) |v| {
            storage.freeValue(v);
            if (nx) return CommandResult{ .nil = {} };
        } else {
            if (xx) return CommandResult{ .nil = {} };
        }
    }

    db.put(key, value, client.db_index) catch return CommandResult{ .error_msg = "ERR write failed" };
    return CommandResult{ .simple_string = "OK" };
}

fn cmdDel(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = allocator;
    if (args.len < 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'del' command" };
    var count: i64 = 0;
    for (1..args.len) |i| {
        const key = getStringArg(args, i) orelse continue;
        const existing = db.get(key, client.db_index) catch continue;
        if (existing) |v| {
            storage.freeValue(v);
            db.delete(key, client.db_index) catch continue;
            count += 1;
        } else {
            db.delete(key, client.db_index) catch {};
        }
    }
    return CommandResult{ .integer = count };
}

fn cmdExists(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = allocator;
    if (args.len < 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'exists' command" };
    var count: i64 = 0;
    for (1..args.len) |i| {
        const key = getStringArg(args, i) orelse continue;
        const val = db.get(key, client.db_index) catch continue;
        if (val) |v| {
            storage.freeValue(v);
            count += 1;
        }
    }
    return CommandResult{ .integer = count };
}

fn cmdMGet(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    if (args.len < 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'mget' command" };
    const n = args.len - 1;

    // 收集 key 列表
    const keys = allocator.alloc([]const u8, n) catch return CommandResult{ .error_msg = "ERR out of memory" };
    defer allocator.free(keys);
    for (1..args.len, 0..) |arg_i, k_i| {
        keys[k_i] = getStringArg(args, arg_i) orelse "";
    }

    // 使用 Multi-Get 批量 I/O
    const values = db.multiGet(keys, client.db_index) catch return CommandResult{ .error_msg = "ERR read failed" };

    const results = allocator.alloc(CommandResult, n) catch return CommandResult{ .error_msg = "ERR out of memory" };
    for (0..n) |i| {
        if (values[i]) |v| {
            const duped = allocator.dupe(u8, v) catch {
                storage.freeValue(v);
                results[i] = CommandResult{ .nil = {} };
                continue;
            };
            storage.freeValue(v);
            results[i] = CommandResult{ .owned_string = duped };
        } else {
            results[i] = CommandResult{ .nil = {} };
        }
    }
    allocator.free(values);

    return CommandResult{ .array = results };
}

fn cmdMSet(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'mset' command" };
    const pair_count = (args.len - 1) / 2;
    const pairs = allocator.alloc(storage.KeyValue, pair_count) catch return CommandResult{ .error_msg = "ERR out of memory" };
    defer allocator.free(pairs);

    for (0..pair_count) |i| {
        pairs[i] = .{
            .key = getStringArg(args, 1 + i * 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'mset' command" },
            .value = getStringArg(args, 2 + i * 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'mset' command" },
        };
    }
    // 使用 WriteBatch 原子写入，保证多 key 一致性
    db.atomicPut(pairs, client.db_index) catch return CommandResult{ .error_msg = "ERR write failed" };
    return CommandResult{ .simple_string = "OK" };
}

fn cmdStrlen(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = allocator;
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'strlen' command" };
    const val = db.get(key, client.db_index) catch return CommandResult{ .integer = 0 };
    if (val) |v| {
        const len: i64 = @intCast(v.len);
        storage.freeValue(v);
        return CommandResult{ .integer = len };
    }
    return CommandResult{ .integer = 0 };
}

fn cmdSetNx(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = allocator;
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setnx' command" };
    const value = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setnx' command" };

    db.wlock(client.io);
    defer db.wunlock(client.io);

    const existing = db.get(key, client.db_index) catch return CommandResult{ .error_msg = "ERR read failed" };
    if (existing) |v| {
        storage.freeValue(v);
        return CommandResult{ .integer = 0 };
    }
    db.put(key, value, client.db_index) catch return CommandResult{ .error_msg = "ERR write failed" };
    return CommandResult{ .integer = 1 };
}

fn cmdGetSet(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getset' command" };
    const value = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getset' command" };

    db.wlock(client.io);
    defer db.wunlock(client.io);

    const old = db.get(key, client.db_index) catch return CommandResult{ .nil = {} };
    db.put(key, value, client.db_index) catch {
        if (old) |v| storage.freeValue(v);
        return CommandResult{ .error_msg = "ERR write failed" };
    };
    if (old) |v| {
        const duped = allocator.dupe(u8, v) catch {
            storage.freeValue(v);
            return CommandResult{ .nil = {} };
        };
        storage.freeValue(v);
        return CommandResult{ .owned_string = duped };
    }
    return CommandResult{ .nil = {} };
}

// ============================================================
// 字符串操作命令
// ============================================================

fn cmdAppend(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = allocator;
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'append' command" };
    const value = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'append' command" };

    // 使用 Merge Operator 直接追加，无需读-改-写加锁
    db.merge(key, value, client.db_index) catch return CommandResult{ .error_msg = "ERR write failed" };

    // 读取追加后的总长度作为返回值
    const updated = db.get(key, client.db_index) catch return CommandResult{ .simple_string = "OK" };
    if (updated) |v| {
        const len: i64 = @intCast(v.len);
        storage.freeValue(v);
        return CommandResult{ .integer = len };
    }
    return CommandResult{ .integer = @intCast(value.len) };
}

fn cmdGetRange(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getrange' command" };
    const start_str = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getrange' command" };
    const end_str = getStringArg(args, 3) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getrange' command" };

    const start = std.fmt.parseInt(i64, start_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer" };
    const end = std.fmt.parseInt(i64, end_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer" };

    const val = db.get(key, client.db_index) catch return blk: {
        const empty = allocator.dupe(u8, "") catch return CommandResult{ .error_msg = "ERR out of memory" };
        break :blk CommandResult{ .owned_string = empty };
    };
    if (val) |v| {
        // 支持负数索引（从末尾计数），与 Redis 行为一致
        const s: usize = if (start < 0) @intCast(@max(@as(i64, @intCast(v.len)) + start, 0)) else @intCast(@min(start, @as(i64, @intCast(v.len))));
        const e: usize = if (end < 0) @intCast(@max(@as(i64, @intCast(v.len)) + end, 0)) else @intCast(@min(end, @as(i64, @intCast(v.len)) - 1));
        if (s > e or s >= v.len) {
            storage.freeValue(v);
            const empty = allocator.dupe(u8, "") catch return CommandResult{ .error_msg = "ERR out of memory" };
            return CommandResult{ .owned_string = empty };
        }
        const slice = v[s .. e + 1];
        const duped = allocator.dupe(u8, slice) catch {
            storage.freeValue(v);
            return CommandResult{ .error_msg = "ERR out of memory" };
        };
        storage.freeValue(v);
        return CommandResult{ .owned_string = duped };
    }
    const empty = allocator.dupe(u8, "") catch return CommandResult{ .error_msg = "ERR out of memory" };
    return CommandResult{ .owned_string = empty };
}

fn cmdSetRange(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setrange' command" };
    const offset_str = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setrange' command" };
    const value = getStringArg(args, 3) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setrange' command" };

    const offset = std.fmt.parseInt(usize, offset_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer" };

    db.wlock(client.io);
    defer db.wunlock(client.io);

    const existing = db.get(key, client.db_index) catch {
        const new_len = offset + value.len;
        const buf = allocator.alloc(u8, new_len) catch return CommandResult{ .error_msg = "ERR out of memory" };
        @memset(buf[0..offset], 0);
        @memcpy(buf[offset .. offset + value.len], value);
        db.put(key, buf, client.db_index) catch {
            allocator.free(buf);
            return CommandResult{ .error_msg = "ERR write failed" };
        };
        allocator.free(buf);
        return CommandResult{ .integer = @intCast(new_len) };
    };
    if (existing) |v| {
        const new_len = @max(v.len, offset + value.len);
        const buf = allocator.alloc(u8, new_len) catch {
            storage.freeValue(v);
            return CommandResult{ .error_msg = "ERR out of memory" };
        };
        @memcpy(buf[0..v.len], v);
        if (offset > v.len) @memset(buf[v.len..offset], 0);
        @memcpy(buf[offset .. offset + value.len], value);
        storage.freeValue(v);
        db.put(key, buf, client.db_index) catch {
            allocator.free(buf);
            return CommandResult{ .error_msg = "ERR write failed" };
        };
        allocator.free(buf);
        return CommandResult{ .integer = @intCast(new_len) };
    } else {
        const new_len = offset + value.len;
        const buf = allocator.alloc(u8, new_len) catch return CommandResult{ .error_msg = "ERR out of memory" };
        @memset(buf[0..offset], 0);
        @memcpy(buf[offset .. offset + value.len], value);
        db.put(key, buf, client.db_index) catch {
            allocator.free(buf);
            return CommandResult{ .error_msg = "ERR write failed" };
        };
        allocator.free(buf);
        return CommandResult{ .integer = @intCast(new_len) };
    }
}

// ============================================================
// 数值操作命令
// ============================================================

fn cmdIncr(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    if (args.len != 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'incr' command" };
    return doIncr(db, allocator, args, client, true, 1);
}

fn cmdIncrby(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    if (args.len != 3) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'incrby' command" };
    const delta_str = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR value is not an integer" };
    const delta = std.fmt.parseInt(i64, delta_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer" };
    return doIncr(db, allocator, args, client, true, delta);
}

fn cmdDecr(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    if (args.len != 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'decr' command" };
    return doIncr(db, allocator, args, client, false, 1);
}

fn cmdDecrby(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    if (args.len != 3) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'decrby' command" };
    const delta_str = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR value is not an integer" };
    const delta = std.fmt.parseInt(i64, delta_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer" };
    return doIncr(db, allocator, args, client, false, delta);
}

/// INCR/DECR/INCRBY/DECRBY 的统一实现。写锁保证读-改-写原子性。
/// key 不存在时初始化为 0 再执行加减。
fn doIncr(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState, is_incr: bool, delta: i64) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments" };

    const effective_delta = if (is_incr) delta else -delta;

    db.wlock(client.io);
    defer db.wunlock(client.io);

    const existing = db.get(key, client.db_index) catch return CommandResult{ .error_msg = "ERR read failed" };
    if (existing) |v| {
        const current = std.fmt.parseInt(i64, v, 10) catch {
            storage.freeValue(v);
            return CommandResult{ .error_msg = "ERR value is not an integer" };
        };
        storage.freeValue(v);
        const new_val = std.math.add(i64, current, effective_delta) catch return CommandResult{ .error_msg = "ERR value is not an integer or out of range" };
        const buf = std.fmt.allocPrint(allocator, "{d}", .{new_val}) catch return CommandResult{ .error_msg = "ERR out of memory" };
        db.put(key, buf, client.db_index) catch {
            allocator.free(buf);
            return CommandResult{ .error_msg = "ERR write failed" };
        };
        allocator.free(buf);
        return CommandResult{ .integer = new_val };
    } else {
        const new_val = effective_delta;
        const buf = std.fmt.allocPrint(allocator, "{d}", .{new_val}) catch return CommandResult{ .error_msg = "ERR out of memory" };
        db.put(key, buf, client.db_index) catch {
            allocator.free(buf);
            return CommandResult{ .error_msg = "ERR write failed" };
        };
        allocator.free(buf);
        return CommandResult{ .integer = new_val };
    }
}

// ============================================================
// 服务管理与信息命令
// ============================================================

// COMMAND 子命令（docs/count/info）返回空数组，满足客户端初始化握手
fn cmdCommand(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = allocator;
    _ = client;
    if (args.len > 1) {
        const sub = getStringArg(args, 1) orelse "";
        var buf: [16]u8 = undefined;
        if (sub.len > buf.len) return CommandResult{ .simple_string = "OK" };
        const sub_lower = std.ascii.lowerString(&buf, sub);
        if (std.mem.eql(u8, sub_lower, "docs") or std.mem.eql(u8, sub_lower, "count") or std.mem.eql(u8, sub_lower, "info")) {
            return CommandResult{ .null_array = {} };
        }
    }
    return CommandResult{ .simple_string = "OK" };
}

fn cmdInfo(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    const pid = std.posix.system.getpid();
    const role = if (db.is_replica) "replica" else "master";

    // 复制信息
    var repl_info: []const u8 = "";
    if (db.is_replica) {
        const connected = db.is_replica_connected.load(.acquire);
        repl_info = std.fmt.allocPrint(allocator,
            "\r\n# Replication\r\nrole:{s}\r\nmaster_link_status:{s}\r\n",
            .{ role, if (connected) "up" else "down" },
        ) catch "";
    } else if (db.repl) |repl| {
        const replica_count = repl.replicas.count(client.io);
        repl_info = std.fmt.allocPrint(allocator,
            "\r\n# Replication\r\nrole:{s}\r\nconnected_replicas:{d}\r\n",
            .{ role, replica_count },
        ) catch "";
    } else {
        repl_info = std.fmt.allocPrint(allocator,
            "\r\n# Replication\r\nrole:{s}\r\nconnected_replicas:0\r\n",
            .{role},
        ) catch "";
    }
    defer allocator.free(repl_info);

    if (args.len > 1) {
        const section = getStringArg(args, 1) orelse "";
        if (std.mem.eql(u8, section, "server")) {
            const info = std.fmt.allocPrint(allocator, "# Server\r\nnovelkv_version:1.0.0\r\nos:Linux\r\narch_bits:64\r\ntcp_port:{d}\r\nprocess_id:{d}\r\n{s}", .{ client.port, pid, repl_info }) catch return CommandResult{ .error_msg = "ERR out of memory" };
            return CommandResult{ .owned_string = info };
        }
        if (std.mem.eql(u8, section, "stats")) {
            const cache = db.getCacheStats();
            const cf_stats = db.getCFStats(client.db_index);
            const key_count = db.estimateKeyCount(client.db_index);
            const info = std.fmt.allocPrint(allocator,
                "# Stats\r\ndb{d}_keys:{d}\r\ndb{d}_sst_files:{d}\r\ndb{d}_sst_size_bytes:{d}\r\nblock_cache_usage:{d}\r\nblock_cache_capacity:{d}\r\n{s}",
                .{ client.db_index, key_count, client.db_index, cf_stats.live_sst_files, client.db_index, cf_stats.live_sst_size, cache.usage, cache.capacity, repl_info },
            ) catch return CommandResult{ .error_msg = "ERR out of memory" };
            return CommandResult{ .owned_string = info };
        }
        if (std.mem.eql(u8, section, "replication")) {
            const info = std.fmt.allocPrint(allocator, "# Replication\r\nrole:{s}\r\n{s}", .{ role, repl_info }) catch return CommandResult{ .error_msg = "ERR out of memory" };
            return CommandResult{ .owned_string = info };
        }
    }
    const cache = db.getCacheStats();
    const cf_stats = db.getCFStats(client.db_index);
    const key_count = db.estimateKeyCount(client.db_index);
    const info = std.fmt.allocPrint(allocator,
        "# NovelKV\r\nnovelkv_version:1.0.0\r\nengine:rocksdb+Zstd+bloom\r\nos:Linux\r\narch_bits:64\r\ntcp_port:{d}\r\nprocess_id:{d}\r\n\r\n# Stats(db{d})\r\nkeys:{d}\r\nsst_files:{d}\r\nsst_size_bytes:{d}\r\nblock_cache_usage:{d}\r\nblock_cache_capacity:{d}\r\n{s}",
        .{ client.port, pid, client.db_index, key_count, cf_stats.live_sst_files, cf_stats.live_sst_size, cache.usage, cache.capacity, repl_info },
    ) catch return CommandResult{ .error_msg = "ERR out of memory" };
    return CommandResult{ .owned_string = info };
}

fn cmdConfig(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = allocator;
    _ = client;
    if (args.len < 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'config' command" };
    const sub = getStringArg(args, 1) orelse "";
    var buf: [16]u8 = undefined;
    if (sub.len > buf.len) return CommandResult{ .error_msg = "ERR unknown subcommand" };
    const sub_lower = std.ascii.lowerString(&buf, sub);
    if (std.mem.eql(u8, sub_lower, "get")) {
        return CommandResult{ .null_array = {} };
    }
    return CommandResult{ .error_msg = "ERR unknown subcommand" };
}

fn cmdDbsize(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = args;
    _ = allocator;
    const count = db.estimateKeyCount(client.db_index);
    return CommandResult{ .integer = @intCast(count) };
}

fn cmdFlushdb(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = args;
    _ = allocator;
    db.wlock(client.io);
    defer db.wunlock(client.io);
    db.flushDatabase(client.db_index) catch return CommandResult{ .error_msg = "ERR flush failed" };
    return CommandResult{ .simple_string = "OK" };
}

fn cmdFlushall(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = args;
    _ = allocator;
    db.wlock(client.io);
    defer db.wunlock(client.io);
    // 遍历全部 16 个数据库逐一清空
    for (0..storage.MAX_DATABASES) |i| {
        db.flushDatabase(i) catch {
            log.err("Failed to flush database {d}", .{i});
        };
    }
    return CommandResult{ .simple_string = "OK" };
}

// ============================================================
// 类型与 TTL 命令（兼容性保留，TTL 相关为空壳实现）
// ============================================================

fn cmdType(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = allocator;
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'type' command" };
    const val = db.get(key, client.db_index) catch return CommandResult{ .simple_string = "none" };
    if (val) |v| {
        storage.freeValue(v);
        return CommandResult{ .simple_string = "string" };
    }
    return CommandResult{ .simple_string = "none" };
}

fn cmdObject(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = args;
    _ = allocator;
    _ = client;
    return CommandResult{ .integer = 0 };
}

// NovelKV 不支持 Key 过期，TTL/PTTL 始终返回 -1（表示无过期）
fn cmdTtl(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = args;
    _ = allocator;
    _ = client;
    return CommandResult{ .integer = -1 };
}

fn cmdPersist(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = args;
    _ = allocator;
    _ = client;
    return CommandResult{ .integer = 0 };
}

fn cmdExpire(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = args;
    _ = allocator;
    _ = client;
    return CommandResult{ .integer = 0 };
}

// ============================================================
// 备份命令
// ============================================================

/// SAVE：同步备份，使用写锁保证一致性
fn cmdSave(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    const dir_arg = getStringArg(args, 1) orelse "./backups/latest";

    _ = std.posix.system.mkdir("backups", 0o755);

    const checkpoint_dir_buf = allocator.allocSentinel(u8, dir_arg.len, 0) catch return CommandResult{ .error_msg = "ERR out of memory" };
    @memcpy(checkpoint_dir_buf[0..dir_arg.len], dir_arg);
    const checkpoint_dir: [:0]u8 = checkpoint_dir_buf;
    defer allocator.free(checkpoint_dir_buf);

    db.wlock(client.io);
    defer db.wunlock(client.io);

    // 清理旧备份目录（Checkpoint 要求目标目录不存在）
    {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        std.Io.Dir.cwd().deleteTree(io, dir_arg) catch {};
    }

    db.createCheckpointWithSnapshot(checkpoint_dir) catch {
        return CommandResult{ .error_msg = "ERR save failed" };
    };
    const msg = std.fmt.allocPrint(allocator, "Checkpoint created: {s}", .{checkpoint_dir}) catch return CommandResult{ .simple_string = "OK" };
    return CommandResult{ .owned_string = msg };
}

/// BGSAVE：使用 Snapshot 一致性备份，不阻塞读写。
fn cmdBgsave(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = client;
    const dir_arg = getStringArg(args, 1) orelse "./backups/latest";

    _ = std.posix.system.mkdir("backups", 0o755);

    const checkpoint_dir_buf = allocator.allocSentinel(u8, dir_arg.len, 0) catch return CommandResult{ .error_msg = "ERR out of memory" };
    @memcpy(checkpoint_dir_buf[0..dir_arg.len], dir_arg);
    const checkpoint_dir: [:0]u8 = checkpoint_dir_buf;
    defer allocator.free(checkpoint_dir_buf);

    // 清理旧备份目录
    {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        std.Io.Dir.cwd().deleteTree(io, dir_arg) catch {};
    }

    // Snapshot 提供一致性视图，无需写锁
    const snapshot = db.createSnapshot();
    defer db.releaseSnapshot(snapshot);

    db.createCheckpointWithSnapshot(checkpoint_dir) catch {
        return CommandResult{ .error_msg = "ERR bgsave failed" };
    };
    const msg = std.fmt.allocPrint(allocator, "Checkpoint created: {s}", .{checkpoint_dir}) catch return CommandResult{ .simple_string = "OK" };
    return CommandResult{ .owned_string = msg };
}

/// SCAN：基于游标的渐进式 key 扫描，支持 MATCH 前缀过滤和 COUNT 限制。
/// 格式：SCAN <cursor> [MATCH <pattern>] [COUNT <count>]
fn cmdScan(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = args;
    // 当前简化实现：每次返回一批 key，cursor 固定返回 "0" 表示结束
    const keys = db.scanKeys(allocator, "", client.db_index, 100) catch
        return CommandResult{ .error_msg = "ERR scan failed" };

    if (keys.len == 0) {
        const result_items = allocator.alloc(CommandResult, 2) catch return CommandResult{ .error_msg = "ERR out of memory" };
        result_items[0] = CommandResult{ .owned_string = allocator.dupe(u8, "0") catch return CommandResult{ .error_msg = "ERR out of memory" } };
        result_items[1] = CommandResult{ .array = allocator.alloc(CommandResult, 0) catch &.{} };
        return CommandResult{ .array = result_items };
    }

    // 将 keys 转为 CommandResult 数组
    const key_results = allocator.alloc(CommandResult, keys.len) catch return CommandResult{ .error_msg = "ERR out of memory" };
    for (keys, 0..) |k, i| {
        key_results[i] = CommandResult{ .owned_string = k };
    }
    allocator.free(keys);

    // SCAN 回复格式：[cursor, [key1, key2, ...]]
    const result_items = allocator.alloc(CommandResult, 2) catch return CommandResult{ .error_msg = "ERR out of memory" };
    result_items[0] = CommandResult{ .owned_string = allocator.dupe(u8, "0") catch return CommandResult{ .error_msg = "ERR out of memory" } };
    result_items[1] = CommandResult{ .array = key_results };
    return CommandResult{ .array = result_items };
}

// ============================================================
// 复制协议命令
// ============================================================

/// REPLCONF：副本握手阶段设置参数
fn cmdReplconf(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = allocator;
    if (args.len < 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'replconf' command" };

    const sub = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR unknown subcommand" };
    var buf: [32]u8 = undefined;
    if (sub.len > buf.len) return CommandResult{ .error_msg = "ERR unknown subcommand" };
    const sub_lower = std.ascii.lowerString(&buf, sub);

    if (std.mem.eql(u8, sub_lower, "listening-port")) {
        const port_str = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR syntax error" };
        client.replica_port = std.fmt.parseInt(u16, port_str, 10) catch return CommandResult{ .error_msg = "ERR invalid port" };
        client.is_replica_conn = true;
        return CommandResult{ .simple_string = "OK" };
    }

    // 其他 REPLCONF 子命令静默接受（ack, capa 等）
    return CommandResult{ .simple_string = "OK" };
}

/// PSYNC：副本请求全量同步
fn cmdPsync(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, client: *ClientState) CommandResult {
    _ = db;
    _ = allocator;
    _ = args;
    // 标记此连接需要全量同步，由 server.zig 的 handleConnection 检测并处理
    client.is_replica_conn = true;
    client.needs_fullsync = true;
    // 返回占位响应，实际全量同步在 handleReplicaStream 中进行
    return CommandResult{ .simple_string = "CONTINUE" };
}

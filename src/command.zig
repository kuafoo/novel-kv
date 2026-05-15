const std = @import("std");
const storage = @import("storage.zig");
const resp = @import("resp.zig");

pub const CommandResult = union(enum) {
    ok: void,
    bulk_string: ?[]const u8,
    owned_string: []const u8,
    integer: i64,
    simple_string: []const u8,
    error_msg: []const u8,
    nil: void,
    null_array: void,
    array: ?[]const CommandResult,
};

pub fn execute(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue) CommandResult {
    if (args.len == 0) return CommandResult{ .error_msg = "ERR empty command" };

    const command = getStringArg(args, 0) orelse "";
    const cmd = std.ascii.allocLowerString(allocator, command) catch {
        return CommandResult{ .error_msg = "ERR out of memory" };
    };
    defer allocator.free(cmd);

    if (std.mem.eql(u8, cmd, "ping")) {
        return cmdPing(args);
    } else if (std.mem.eql(u8, cmd, "get")) {
        return cmdGet(db, allocator, args);
    } else if (std.mem.eql(u8, cmd, "set")) {
        return cmdSet(db, allocator, args);
    } else if (std.mem.eql(u8, cmd, "del") or std.mem.eql(u8, cmd, "unlink")) {
        return cmdDel(db, args);
    } else if (std.mem.eql(u8, cmd, "exists")) {
        return cmdExists(db, args);
    } else if (std.mem.eql(u8, cmd, "mget")) {
        return cmdMGet(db, allocator, args);
    } else if (std.mem.eql(u8, cmd, "mset")) {
        return cmdMSet(db, args);
    } else if (std.mem.eql(u8, cmd, "strlen")) {
        return cmdStrlen(db, args);
    } else if (std.mem.eql(u8, cmd, "append")) {
        return cmdAppend(db, allocator, args);
    } else if (std.mem.eql(u8, cmd, "incr") or std.mem.eql(u8, cmd, "incrby")) {
        return cmdIncr(db, allocator, args, true);
    } else if (std.mem.eql(u8, cmd, "decr") or std.mem.eql(u8, cmd, "decrby")) {
        return cmdIncr(db, allocator, args, false);
    } else if (std.mem.eql(u8, cmd, "getrange")) {
        return cmdGetRange(db, allocator, args);
    } else if (std.mem.eql(u8, cmd, "setrange")) {
        return cmdSetRange(db, allocator, args);
    } else if (std.mem.eql(u8, cmd, "command")) {
        return cmdCommand(args);
    } else if (std.mem.eql(u8, cmd, "select")) {
        return CommandResult{ .simple_string = "OK" };
    } else if (std.mem.eql(u8, cmd, "quit")) {
        return CommandResult{ .simple_string = "OK" };
    } else if (std.mem.eql(u8, cmd, "info")) {
        return cmdInfo(args);
    } else if (std.mem.eql(u8, cmd, "config")) {
        return cmdConfig(args);
    } else if (std.mem.eql(u8, cmd, "dbsize")) {
        return CommandResult{ .integer = 0 };
    } else if (std.mem.eql(u8, cmd, "flushdb") or std.mem.eql(u8, cmd, "flushall")) {
        return CommandResult{ .simple_string = "OK" };
    } else if (std.mem.eql(u8, cmd, "type")) {
        return CommandResult{ .simple_string = "string" };
    } else if (std.mem.eql(u8, cmd, "object")) {
        return CommandResult{ .integer = 0 };
    } else if (std.mem.eql(u8, cmd, "ttl") or std.mem.eql(u8, cmd, "pttl")) {
        return CommandResult{ .integer = -1 };
    } else if (std.mem.eql(u8, cmd, "persist")) {
        return CommandResult{ .integer = 0 };
    } else if (std.mem.eql(u8, cmd, "expire") or std.mem.eql(u8, cmd, "pexpire")) {
        return CommandResult{ .integer = 0 };
    } else if (std.mem.eql(u8, cmd, "setnx")) {
        return cmdSetNx(db, args);
    } else if (std.mem.eql(u8, cmd, "getset")) {
        return cmdGetSet(db, allocator, args);
    } else if (std.mem.eql(u8, cmd, "echo")) {
        return cmdEcho(args);
    } else {
        return CommandResult{ .error_msg = "ERR unknown command" };
    }
}

fn getStringArg(args: []resp.RespValue, index: usize) ?[]const u8 {
    if (index >= args.len) return null;
    return switch (args[index]) {
        .bulk_string => |s| s,
        else => null,
    };
}

fn cmdPing(args: []resp.RespValue) CommandResult {
    if (args.len > 1) {
        const msg = getStringArg(args, 1) orelse "";
        return CommandResult{ .simple_string = msg };
    }
    return CommandResult{ .simple_string = "PONG" };
}

fn cmdGet(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'get' command" };
    const val = db.get(key);
    if (val) |v| {
        const duped = allocator.dupe(u8, v) catch {
            db.freeValue(v);
            return CommandResult{ .error_msg = "ERR out of memory" };
        };
        db.freeValue(v);
        return CommandResult{ .owned_string = duped };
    }
    return CommandResult{ .nil = {} };
}

fn cmdSet(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'set' command" };
    const value = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'set' command" };

    var nx: bool = false;
    var xx: bool = false;
    var i: usize = 3;
    while (i < args.len) {
        const opt = getStringArg(args, i) orelse break;
        const opt_lower = std.ascii.allocLowerString(allocator, opt) catch break;
        defer allocator.free(opt_lower);

        if (std.mem.eql(u8, opt_lower, "nx")) {
            nx = true;
            i += 1;
        } else if (std.mem.eql(u8, opt_lower, "xx")) {
            xx = true;
            i += 1;
        } else if (std.mem.eql(u8, opt_lower, "ex") or std.mem.eql(u8, opt_lower, "px") or std.mem.eql(u8, opt_lower, "exat") or std.mem.eql(u8, opt_lower, "pxat") or std.mem.eql(u8, opt_lower, "keepttl")) {
            i += 1;
            if (std.mem.eql(u8, opt_lower, "ex") or std.mem.eql(u8, opt_lower, "px") or std.mem.eql(u8, opt_lower, "exat") or std.mem.eql(u8, opt_lower, "pxat")) {
                i += 1;
            }
        } else if (std.mem.eql(u8, opt_lower, "get")) {
            i += 1;
        } else {
            return CommandResult{ .error_msg = "ERR syntax error" };
        }
    }

    if (nx and xx) return CommandResult{ .error_msg = "ERR syntax error" };

    if (nx) {
        const existing = db.get(key);
        if (existing) |v| {
            db.freeValue(v);
            return CommandResult{ .nil = {} };
        }
    }
    if (xx) {
        const existing = db.get(key);
        if (existing == null) return CommandResult{ .nil = {} };
    }

    db.put(key, value) catch return CommandResult{ .error_msg = "ERR write failed" };
    return CommandResult{ .simple_string = "OK" };
}

fn cmdDel(db: *storage.Database, args: []resp.RespValue) CommandResult {
    if (args.len < 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'del' command" };
    var count: i64 = 0;
    for (1..args.len) |i| {
        const key = getStringArg(args, i) orelse continue;
        const existing = db.get(key);
        if (existing) |v| {
            db.freeValue(v);
            db.delete(key) catch continue;
            count += 1;
        } else {
            db.delete(key) catch {};
        }
    }
    return CommandResult{ .integer = count };
}

fn cmdExists(db: *storage.Database, args: []resp.RespValue) CommandResult {
    if (args.len < 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'exists' command" };
    var count: i64 = 0;
    for (1..args.len) |i| {
        const key = getStringArg(args, i) orelse continue;
        const val = db.get(key);
        if (val) |v| {
            db.freeValue(v);
            count += 1;
        }
    }
    return CommandResult{ .integer = count };
}

fn cmdMGet(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue) CommandResult {
    if (args.len < 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'mget' command" };
    const results = allocator.alloc(CommandResult, args.len - 1) catch return CommandResult{ .error_msg = "ERR out of memory" };
    for (1..args.len) |i| {
        const key = getStringArg(args, i) orelse {
            results[i - 1] = CommandResult{ .nil = {} };
            continue;
        };
        const val = db.get(key);
        if (val) |v| {
            const duped = allocator.dupe(u8, v) catch {
                db.freeValue(v);
                results[i - 1] = CommandResult{ .nil = {} };
                continue;
            };
            db.freeValue(v);
            results[i - 1] = CommandResult{ .owned_string = duped };
        } else {
            results[i - 1] = CommandResult{ .nil = {} };
        }
    }
    return CommandResult{ .array = results };
}

fn cmdMSet(db: *storage.Database, args: []resp.RespValue) CommandResult {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'mset' command" };
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const key = getStringArg(args, i) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'mset' command" };
        const value = getStringArg(args, i + 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'mset' command" };
        db.put(key, value) catch return CommandResult{ .error_msg = "ERR write failed" };
    }
    return CommandResult{ .simple_string = "OK" };
}

fn cmdStrlen(db: *storage.Database, args: []resp.RespValue) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'strlen' command" };
    const val = db.get(key);
    if (val) |v| {
        const len: i64 = @intCast(v.len);
        db.freeValue(v);
        return CommandResult{ .integer = len };
    }
    return CommandResult{ .integer = 0 };
}

fn cmdAppend(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'append' command" };
    const value = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'append' command" };

    const existing = db.get(key);
    if (existing) |v| {
        const new_len = v.len + value.len;
        const buf = allocator.alloc(u8, new_len) catch return CommandResult{ .error_msg = "ERR out of memory" };
        @memcpy(buf[0..v.len], v);
        @memcpy(buf[v.len..], value);
        db.freeValue(v);
        db.put(key, buf) catch {
            allocator.free(buf);
            return CommandResult{ .error_msg = "ERR write failed" };
        };
        allocator.free(buf);
        return CommandResult{ .integer = @intCast(new_len) };
    } else {
        db.put(key, value) catch return CommandResult{ .error_msg = "ERR write failed" };
        return CommandResult{ .integer = @intCast(value.len) };
    }
}

fn cmdIncr(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue, is_incr: bool) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'incr' command" };

    const delta: i64 = if (args.len > 2) blk: {
        const delta_str = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR value is not an integer" };
        break :blk std.fmt.parseInt(i64, delta_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer" };
    } else 1;

    const effective_delta = if (is_incr) delta else -delta;

    const existing = db.get(key);
    if (existing) |v| {
        const current = std.fmt.parseInt(i64, v, 10) catch {
            db.freeValue(v);
            return CommandResult{ .error_msg = "ERR value is not an integer" };
        };
        db.freeValue(v);
        const new_val = current + effective_delta;
        const buf = std.fmt.allocPrint(allocator, "{d}", .{new_val}) catch return CommandResult{ .error_msg = "ERR out of memory" };
        db.put(key, buf) catch {
            allocator.free(buf);
            return CommandResult{ .error_msg = "ERR write failed" };
        };
        allocator.free(buf);
        return CommandResult{ .integer = new_val };
    } else {
        const new_val = effective_delta;
        const buf = std.fmt.allocPrint(allocator, "{d}", .{new_val}) catch return CommandResult{ .error_msg = "ERR out of memory" };
        db.put(key, buf) catch {
            allocator.free(buf);
            return CommandResult{ .error_msg = "ERR write failed" };
        };
        allocator.free(buf);
        return CommandResult{ .integer = new_val };
    }
}

fn cmdGetRange(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getrange' command" };
    const start_str = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getrange' command" };
    const end_str = getStringArg(args, 3) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getrange' command" };

    const start = std.fmt.parseInt(i64, start_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer" };
    const end = std.fmt.parseInt(i64, end_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer" };

    const val = db.get(key);
    if (val) |v| {
        const s: usize = if (start < 0) @intCast(@max(@as(i64, @intCast(v.len)) + start, 0)) else @intCast(@min(start, @as(i64, @intCast(v.len))));
        const e: usize = if (end < 0) @intCast(@max(@as(i64, @intCast(v.len)) + end, 0)) else @intCast(@min(end, @as(i64, @intCast(v.len)) - 1));
        if (s > e or s >= v.len) {
            db.freeValue(v);
            return CommandResult{ .bulk_string = "" };
        }
        const slice = v[s .. e + 1];
        const duped = allocator.dupe(u8, slice) catch {
            db.freeValue(v);
            return CommandResult{ .error_msg = "ERR out of memory" };
        };
        db.freeValue(v);
        return CommandResult{ .bulk_string = duped };
    }
    return CommandResult{ .bulk_string = "" };
}

fn cmdSetRange(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setrange' command" };
    const offset_str = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setrange' command" };
    const value = getStringArg(args, 3) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setrange' command" };

    const offset = std.fmt.parseInt(usize, offset_str, 10) catch return CommandResult{ .error_msg = "ERR value is not an integer" };

    const existing = db.get(key);
    if (existing) |v| {
        const new_len = @max(v.len, offset + value.len);
        const buf = allocator.alloc(u8, new_len) catch return CommandResult{ .error_msg = "ERR out of memory" };
        @memcpy(buf[0..v.len], v);
        if (offset > v.len) @memset(buf[v.len..offset], 0);
        @memcpy(buf[offset .. offset + value.len], value);
        db.freeValue(v);
        db.put(key, buf) catch {
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
        db.put(key, buf) catch {
            allocator.free(buf);
            return CommandResult{ .error_msg = "ERR write failed" };
        };
        allocator.free(buf);
        return CommandResult{ .integer = @intCast(new_len) };
    }
}

fn cmdCommand(args: []resp.RespValue) CommandResult {
    if (args.len > 1) {
        const sub = getStringArg(args, 1) orelse "";
        const sub_lower = std.mem.eql(u8, sub, "DOCS") or std.mem.eql(u8, sub, "docs") or std.mem.eql(u8, sub, "COUNT") or std.mem.eql(u8, sub, "count") or std.mem.eql(u8, sub, "INFO") or std.mem.eql(u8, sub, "info");
        if (sub_lower) {
            // COMMAND DOCS / COMMAND COUNT / COMMAND INFO — return empty array for compatibility
            return CommandResult{ .null_array = {} };
        }
    }
    return CommandResult{ .simple_string = "OK" };
}

fn cmdInfo(args: []resp.RespValue) CommandResult {
    const info = "# NovelKV\r\nredis_version:7.0.0-novelkv\r\nredis_mode:standalone\r\nos:Linux\r\narch_bits:64\r\ntcp_port:6379\r\nprocess_id:1\r\n";
    if (args.len > 1) {
        const section = getStringArg(args, 1) orelse "";
        if (std.mem.eql(u8, section, "server")) {
            return CommandResult{ .bulk_string = "# Server\r\nredis_version:7.0.0-novelkv\r\nos:Linux\r\narch_bits:64\r\ntcp_port:6379\r\n" };
        }
    }
    return CommandResult{ .bulk_string = info };
}

fn cmdConfig(args: []resp.RespValue) CommandResult {
    if (args.len < 2) return CommandResult{ .error_msg = "ERR wrong number of arguments for 'config' command" };
    const sub = getStringArg(args, 1) orelse "";
    if (std.mem.eql(u8, sub, "GET")) {
        return CommandResult{ .null_array = {} };
    }
    return CommandResult{ .error_msg = "ERR unknown subcommand" };
}

fn cmdSetNx(db: *storage.Database, args: []resp.RespValue) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setnx' command" };
    const value = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'setnx' command" };
    const existing = db.get(key);
    if (existing) |v| {
        db.freeValue(v);
        return CommandResult{ .integer = 0 };
    }
    db.put(key, value) catch return CommandResult{ .error_msg = "ERR write failed" };
    return CommandResult{ .integer = 1 };
}

fn cmdGetSet(db: *storage.Database, allocator: std.mem.Allocator, args: []resp.RespValue) CommandResult {
    const key = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getset' command" };
    const value = getStringArg(args, 2) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'getset' command" };
    const old = db.get(key);
    db.put(key, value) catch return CommandResult{ .error_msg = "ERR write failed" };
    if (old) |v| {
        const duped = allocator.dupe(u8, v) catch {
            db.freeValue(v);
            return CommandResult{ .nil = {} };
        };
        db.freeValue(v);
        return CommandResult{ .owned_string = duped };
    }
    return CommandResult{ .nil = {} };
}

fn cmdEcho(args: []resp.RespValue) CommandResult {
    const msg = getStringArg(args, 1) orelse return CommandResult{ .error_msg = "ERR wrong number of arguments for 'echo' command" };
    return CommandResult{ .bulk_string = msg };
}
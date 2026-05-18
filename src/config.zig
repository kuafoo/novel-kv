// NovelKV - Redis conf 风格配置文件解析器
// 格式：每行一个 key value，# 开头为注释，空行忽略
// 值支持 yes/no（布尔）、纯数字、带单位大小（kb/mb/gb）、引号字符串
const std = @import("std");
const log = @import("log.zig");

pub const Config = struct {
    // Server
    host: ?[]const u8 = null,
    port: ?u16 = null,
    data: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    requirepass: ?[]const u8 = null,
    disable_dangerous: ?bool = null,
    disable_commands: ?[]const u8 = null,

    // TLS
    tls_cert: ?[]const u8 = null,
    tls_key: ?[]const u8 = null,
    tls_ca: ?[]const u8 = null,
    tls_replica: ?bool = null,

    // Replication
    replicaof_host: ?[]const u8 = null,
    replicaof_port: ?u16 = null,
    masterauth: ?[]const u8 = null,

    // HTTP
    http_port: ?u16 = null,
    http_secret: ?[]const u8 = null,
    http_sign_ttl: ?u64 = null,
    http_rate_burst: ?f64 = null,
    http_rate_refill: ?f64 = null,

    // Storage
    write_buffer_size: ?usize = null,
    max_write_buffer_number: ?c_int = null,
    block_size: ?usize = null,
    compression_level: ?c_int = null,
    bloom_bits_per_key: ?f64 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        const fields = .{
            "host",           "data",         "log_level",
            "requirepass",    "disable_commands",
            "tls_cert",       "tls_key",      "tls_ca",
            "replicaof_host", "masterauth",    "http_secret",
        };
        inline for (fields) |field_name| {
            if (@field(self, field_name)) |v| {
                // dupeZ allocates len+1 (with sentinel), free the full allocation
                allocator.free(v.ptr[0 .. v.len + 1]);
            }
        }
    }
};

/// 从文件解析配置，返回带默认值填充的 Config。
/// 未出现的字段保持 null（由调用方决定默认值）。
pub fn parseFromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Config {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
        log.err("Failed to open config file '{s}': {}", .{ path, err });
        return err;
    };
    defer allocator.free(content);

    return parseContent(allocator, content);
}

fn parseContent(allocator: std.mem.Allocator, content: []const u8) !Config {
    var cfg = Config{};
    var line_iter = std.mem.splitSequence(u8, content, "\n");
    var line_num: usize = 0;

    while (line_iter.next()) |raw_line| {
        line_num += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // key 是第一个单词，value 是剩余部分
        var parts = std.mem.splitSequence(u8, line, " ");
        const key = parts.next() orelse continue;
        const value = std.mem.trim(u8, parts.rest(), " \t");

        if (value.len == 0) {
            log.warn("Config line {d}: empty value for '{s}', ignored", .{ line_num, key });
            continue;
        }

        applyValue(allocator, &cfg, key, value, line_num) catch |err| {
            log.warn("Config line {d}: invalid value for '{s}': {}", .{ line_num, key, err });
        };
    }

    return cfg;
}

fn applyValue(allocator: std.mem.Allocator, cfg: *Config, key: []const u8, raw_value: []const u8, line_num: usize) !void {
    // 去除引号
    const value = if (raw_value.len >= 2 and raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"')
        raw_value[1 .. raw_value.len - 1]
    else
        raw_value;

    // Server
    if (eql(key, "host")) {
        cfg.host = try allocator.dupeZ(u8, value);
    } else if (eql(key, "port")) {
        cfg.port = try std.fmt.parseInt(u16, value, 10);
    } else if (eql(key, "data")) {
        cfg.data = try allocator.dupeZ(u8, value);
    } else if (eql(key, "log-level")) {
        cfg.log_level = try allocator.dupeZ(u8, value);
    } else if (eql(key, "requirepass")) {
        cfg.requirepass = try allocator.dupeZ(u8, value);
    } else if (eql(key, "disable-dangerous")) {
        cfg.disable_dangerous = parseBool(value);
    } else if (eql(key, "disable-commands")) {
        cfg.disable_commands = try allocator.dupeZ(u8, value);
    }
    // TLS
    else if (eql(key, "tls-cert")) {
        cfg.tls_cert = try allocator.dupeZ(u8, value);
    } else if (eql(key, "tls-key")) {
        cfg.tls_key = try allocator.dupeZ(u8, value);
    } else if (eql(key, "tls-ca")) {
        cfg.tls_ca = try allocator.dupeZ(u8, value);
    } else if (eql(key, "tls-replica")) {
        cfg.tls_replica = parseBool(value);
    }
    // Replication
    else if (eql(key, "replicaof")) {
        // replicaof host port
        var parts = std.mem.splitSequence(u8, value, " ");
        const host_part = parts.next() orelse return error.InvalidValue;
        const port_part = parts.next() orelse return error.InvalidValue;
        cfg.replicaof_host = try allocator.dupe(u8, host_part);
        cfg.replicaof_port = std.fmt.parseInt(u16, port_part, 10) catch return error.InvalidValue;
    } else if (eql(key, "masterauth")) {
        cfg.masterauth = try allocator.dupeZ(u8, value);
    }
    // HTTP
    else if (eql(key, "http-port")) {
        cfg.http_port = try std.fmt.parseInt(u16, value, 10);
    } else if (eql(key, "http-secret")) {
        cfg.http_secret = try allocator.dupeZ(u8, value);
    } else if (eql(key, "http-sign-ttl")) {
        cfg.http_sign_ttl = try std.fmt.parseInt(u64, value, 10);
    } else if (eql(key, "http-rate-burst")) {
        cfg.http_rate_burst = try std.fmt.parseFloat(f64, value);
    } else if (eql(key, "http-rate-refill")) {
        cfg.http_rate_refill = try std.fmt.parseFloat(f64, value);
    }
    // Storage
    else if (eql(key, "write-buffer-size")) {
        cfg.write_buffer_size = try parseSize(value);
    } else if (eql(key, "max-write-buffer-number")) {
        cfg.max_write_buffer_number = try std.fmt.parseInt(c_int, value, 10);
    } else if (eql(key, "block-size")) {
        cfg.block_size = try parseSize(value);
    } else if (eql(key, "compression-level")) {
        cfg.compression_level = try std.fmt.parseInt(c_int, value, 10);
    } else if (eql(key, "bloom-bits")) {
        cfg.bloom_bits_per_key = try std.fmt.parseFloat(f64, value);
    } else {
        log.warn("Config line {d}: unknown key '{s}', ignored", .{ line_num, key });
    }
}

/// 解析布尔值：yes/true/on → true，no/false/off → false
fn parseBool(s: []const u8) ?bool {
    if (eql(s, "yes") or eql(s, "true") or eql(s, "on")) return true;
    if (eql(s, "no") or eql(s, "false") or eql(s, "off")) return false;
    return null;
}

/// 解析带单位的大小值：64mb、128kb、1gb、4096（裸字节数）
fn parseSize(s: []const u8) !usize {
    if (endsWithIgnoreCase(s, "gb")) {
        const num = try std.fmt.parseFloat(f64, s[0 .. s.len - 2]);
        return @intFromFloat(num * 1024.0 * 1024.0 * 1024.0);
    }
    if (endsWithIgnoreCase(s, "mb")) {
        const num = try std.fmt.parseFloat(f64, s[0 .. s.len - 2]);
        return @intFromFloat(num * 1024.0 * 1024.0);
    }
    if (endsWithIgnoreCase(s, "kb")) {
        const num = try std.fmt.parseFloat(f64, s[0 .. s.len - 2]);
        return @intFromFloat(num * 1024.0);
    }
    return std.fmt.parseInt(usize, s, 10);
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    const ending = haystack[haystack.len - needle.len ..];
    for (ending, needle) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

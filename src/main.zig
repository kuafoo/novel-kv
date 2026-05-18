// NovelKV - 专用小说章节文本 KV 存储系统
// 入口模块：配置文件加载、CLI 参数覆盖、信号处理、服务启动
const std = @import("std");
const resp = @import("resp.zig");
const server = @import("server.zig");
const command = @import("command.zig");
const storage = @import("storage.zig");
const replication = @import("replication.zig");
const log = @import("log.zig");
const http_server = @import("http_server.zig");
const config_mod = @import("config.zig");
const tls = @import("tls");

// flushdb/flushall 默认禁用，需 --enable-dangerous 显式启用
const dangerous_commands = [_][]const u8{ "flushdb", "flushall" };

var shutdown_requested: std.atomic.Value(bool) = .init(false);

fn sigtermHandler(sig: std.os.linux.SIG) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    // 先扫描 --config 参数，优先加载配置文件
    var config_path: ?[]const u8 = null;
    {
        var peek = std.process.Args.Iterator.init(init.minimal.args);
        _ = peek.skip();
        while (peek.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
                config_path = peek.next();
                break;
            }
        }
    }

    // 加载配置文件（可选）
    var file_cfg: ?config_mod.Config = null;
    if (config_path) |path| {
        const cfg = config_mod.parseFromFile(io, allocator, path) catch {
            log.err("Failed to load config file: {s}", .{path});
            return error.InvalidConfig;
        };
        file_cfg = cfg;
        log.info("Loaded config from: {s}", .{path});
    }

    // === CLI 参数（仅启动相关，其余走配置文件）===
    var host: [:0]const u8 = val(file_cfg, .host, "0.0.0.0");
    var port: u16 = valInt(file_cfg, .port, @as(u16, 6379));
    var data_path: [:0]const u8 = val(file_cfg, .data, "./data");
    var enable_http = false;
    var enable_tls = false;
    var enable_dangerous = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-H")) {
            if (args.next()) |v| host = v;
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |v| port = std.fmt.parseInt(u16, v, 10) catch {
                log.err("Invalid port: {s}", .{v});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--data") or std.mem.eql(u8, arg, "-d")) {
            if (args.next()) |v| data_path = v;
        } else if (std.mem.eql(u8, arg, "--enable-http")) {
            enable_http = true;
        } else if (std.mem.eql(u8, arg, "--enable-tls")) {
            enable_tls = true;
        } else if (std.mem.eql(u8, arg, "--enable-dangerous")) {
            enable_dangerous = true;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            _ = args.next(); // already handled above
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        }
    }

    // === 从配置文件读取功能参数 ===
    const log_level = if (file_cfg) |c| c.log_level else null;
    const requirepass = if (file_cfg) |c| c.requirepass else null;
    const replicaof_host = if (file_cfg) |c| @constCast(c.replicaof_host) else null;
    const replicaof_port = if (file_cfg) |c| c.replicaof_port else null;
    const masterauth = if (file_cfg) |c| c.masterauth else null;
    const tls_cert = if (file_cfg) |c| c.tls_cert else null;
    const tls_key = if (file_cfg) |c| c.tls_key else null;
    const tls_ca = if (file_cfg) |c| c.tls_ca else null;
    const tls_replica = valBool(file_cfg, .tls_replica, false);
    const http_port = if (file_cfg) |c| c.http_port else null;
    const http_secret = if (file_cfg) |c| c.http_secret else null;
    const http_sign_ttl: u64 = valInt(file_cfg, .http_sign_ttl, @as(u64, 3600));
    const http_rate_burst: f64 = valFloat(file_cfg, .http_rate_burst, 30);
    const http_rate_refill: f64 = valFloat(file_cfg, .http_rate_refill, 10);

    // 功能开关校验
    if (enable_http and (http_port == null or http_secret == null)) {
        log.err("--enable-http requires http-port and http-secret in config file", .{});
        return error.InvalidArgument;
    }
    if (enable_tls and (tls_cert == null or tls_key == null)) {
        log.err("--enable-tls requires tls-cert and tls-key in config file", .{});
        return error.InvalidArgument;
    }

    // 禁用命令列表：默认禁用 dangerous_commands，--enable-dangerous 解除
    var disabled_commands_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (disabled_commands_list.items) |cmd| allocator.free(cmd);
        disabled_commands_list.deinit(allocator);
    }

    if (!enable_dangerous) {
        for (&dangerous_commands) |cmd| {
            const duped = allocator.dupe(u8, cmd) catch continue;
            disabled_commands_list.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
        }
    }

    // 配置文件中的 disable_commands 追加
    if (file_cfg) |c| {
        if (c.disable_commands) |cmds| {
            var iter = std.mem.splitSequence(u8, cmds, ",");
            while (iter.next()) |cmd| {
                const trimmed = std.mem.trim(u8, cmd, " \t");
                if (trimmed.len == 0) continue;
                // 去重
                var found = false;
                for (disabled_commands_list.items) |existing| {
                    if (std.mem.eql(u8, existing, trimmed)) {
                        found = true;
                        break;
                    }
                }
                if (found) continue;
                const lowered = std.ascii.allocLowerString(allocator, trimmed) catch continue;
                disabled_commands_list.append(allocator, lowered) catch {
                    allocator.free(lowered);
                    continue;
                };
            }
        }
    }

    if (disabled_commands_list.items.len > 0) {
        log.info("Disabled commands: {d} command(s)", .{disabled_commands_list.items.len});
        for (disabled_commands_list.items) |cmd| {
            log.info("  - {s}", .{cmd});
        }
    }

    // log-level
    if (log_level) |ll| {
        if (parseLogLevel(ll)) |level| {
            log.setLevel(level);
        } else {
            log.warn("Invalid log level in config: {s}", .{ll});
        }
    }

    log.info("Starting NovelKV on {s}:{d}", .{ host, port });
    log.info("Data directory: {s}", .{data_path});
    if (requirepass) |_| log.info("Authentication required", .{});
    if (enable_dangerous) log.info("Dangerous commands ENABLED (flushdb, flushall)", .{});

    // TLS 初始化
    var tls_auth: ?tls.config.CertKeyPair = null;
    defer {
        if (tls_auth) |*a| a.deinit(allocator);
    }
    var tls_cfg: ?storage.TlsConfig = null;

    if (enable_tls) {
        tls_auth = tls.config.CertKeyPair.fromFilePathAbsolute(allocator, io, tls_cert.?, tls_key.?) catch |err| {
            log.err("Failed to load TLS certificate: {}", .{err});
            return err;
        };
        log.info("TLS enabled: cert={s}", .{tls_cert.?});
        tls_cfg = .{
            .cert_file = tls_cert.?,
            .key_file = tls_key.?,
            .ca_file = tls_ca,
            .replica_tls = tls_replica,
        };
    }

    // 构建存储配置
    var db_config = storage.DbConfig{};
    if (file_cfg) |c| {
        if (c.write_buffer_size) |v| db_config.write_buffer_size = v;
        if (c.max_write_buffer_number) |v| db_config.max_write_buffer_number = v;
        if (c.block_size) |v| db_config.block_size = v;
        if (c.compression_level) |v| db_config.compression_level = v;
        if (c.bloom_bits_per_key) |v| db_config.bloom_bits_per_key = v;
    }

    var db = storage.Database.open(allocator, .{
        .path = data_path,
        .disabled_commands = disabled_commands_list.items,
        .password = requirepass,
        .tls_config = tls_cfg,
        .db_config = db_config,
    }) catch |e| {
        log.err("Failed to open database: {}", .{e});
        return e;
    };
    defer db.close();

    if (tls_auth) |auth| {
        db.tls_auth = auth;
        db.tls_config = tls_cfg;
    }

    // 复制模式初始化
    if (replicaof_host) |master_host| {
        const master_port = replicaof_port orelse 6379;
        db.is_replica = true;
        db.repl_config = .{
            .master_host = master_host,
            .master_port = master_port,
            .masterauth = masterauth,
            .local_port = port,
        };
        log.info("Replica mode: replicating from {s}:{d}", .{ master_host, master_port });
    } else {
        const master_state = allocator.create(replication.MasterState) catch {
            log.err("Failed to initialize replication state", .{});
            return error.OutOfMemory;
        };
        master_state.* = replication.MasterState.init(allocator, io);
        db.repl = master_state;
        log.info("Master mode: replication enabled", .{});
    }

    const sigterm_action = std.os.linux.Sigaction{
        .handler = .{ .handler = sigtermHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &sigterm_action, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &sigterm_action, null);

    var group: std.Io.Group = .init;

    group.concurrent(io, serveResp, .{
        io, allocator, &db, host, port, &shutdown_requested,
    }) catch {
        log.err("Failed to start RESP server", .{});
        return error.StartupFailed;
    };

    if (enable_http) {
        const http_cfg = http_server.HttpConfig{
            .port = http_port.?,
            .secret = http_secret.?,
            .sign_ttl = http_sign_ttl,
            .host = host,
            .rate_limit_burst = http_rate_burst,
            .rate_limit_refill = http_rate_refill,
        };
        group.concurrent(io, http_server.serve, .{
            io, allocator, &db, http_cfg, &shutdown_requested,
        }) catch {
            log.err("Failed to start HTTP server", .{});
            return error.StartupFailed;
        };
    }

    group.await(io) catch {};
}

fn serveResp(io: std.Io, allocator: std.mem.Allocator, db: *storage.Database, host: []const u8, port: u16, shutdown_flag: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    server.serve(io, allocator, db, host, port, shutdown_flag) catch |e| {
        if (!shutdown_flag.load(.acquire)) {
            log.err("RESP server error: {}", .{e});
        }
    };
}

fn val(c: ?config_mod.Config, comptime field: std.meta.FieldEnum(config_mod.Config), default: [:0]const u8) [:0]const u8 {
    if (c) |cfg| {
        if (@field(cfg, @tagName(field))) |v| {
            const ptr: [*]const u8 = v.ptr;
            return ptr[0..v.len :0];
        }
    }
    return default;
}

fn valInt(c: ?config_mod.Config, comptime field: std.meta.FieldEnum(config_mod.Config), default: anytype) @TypeOf(default) {
    if (c) |cfg| {
        if (@field(cfg, @tagName(field))) |v| return v;
    }
    return default;
}

fn valBool(c: ?config_mod.Config, comptime field: std.meta.FieldEnum(config_mod.Config), default: bool) bool {
    if (c) |cfg| {
        if (@field(cfg, @tagName(field))) |v| return v;
    }
    return default;
}

fn valFloat(c: ?config_mod.Config, comptime field: std.meta.FieldEnum(config_mod.Config), default: f64) f64 {
    if (c) |cfg| {
        if (@field(cfg, @tagName(field))) |v| return v;
    }
    return default;
}

fn printUsage() void {
    std.debug.print(
        \\NovelKV - 专用小说章节文本 KV 存储系统
        \\
        \\Usage: novelkv [OPTIONS]
        \\
        \\Options:
        \\  -c, --config <PATH>        Load configuration file (required for most features)
        \\  -H, --host <HOST>          Listen address (default: 0.0.0.0)
        \\  -p, --port <PORT>          Listen port (default: 6379)
        \\  -d, --data <PATH>          Data directory (default: ./data)
        \\  --enable-http              Enable HTTP chapter API (requires http-port/secret in config)
        \\  --enable-tls               Enable TLS encryption (requires tls-cert/key in config)
        \\  --enable-dangerous         Enable dangerous commands (flushdb, flushall, disabled by default)
        \\  --help                     Show this help
        \\
        \\All tuning parameters are set via config file:
        \\  host, port, data, log-level, requirepass
        \\  tls-cert, tls-key, tls-ca, tls-replica
        \\  replicaof, masterauth
        \\  http-port, http-secret, http-sign-ttl, http-rate-burst, http-rate-refill
        \\  write-buffer-size, block-size, compression-level, bloom-bits
        \\
    , .{});
}

fn parseLogLevel(s: []const u8) ?log.Level {
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "error")) return .err;
    return null;
}

test {
    _ = resp;
    _ = command;
    _ = storage;
    _ = http_server;
    _ = config_mod;
}

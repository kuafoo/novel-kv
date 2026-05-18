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

// --disable-dangerous 一键禁用的命令列表
const dangerous_commands = [_][]const u8{ "flushdb", "flushall" };

// SIGTERM/SIGINT 全局标志，通知服务循环优雅退出
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

    // CLI 参数覆盖配置文件
    var host: [:0]const u8 = val(file_cfg, .host, "0.0.0.0");
    var port: u16 = valInt(file_cfg, .port, @as(u16, 6379));
    var data_path: [:0]const u8 = val(file_cfg, .data, "./data");
    var log_level: ?[]const u8 = null;
    var disable_dangerous = valBool(file_cfg, .disable_dangerous, false);
    var disabled_commands_list: std.ArrayList([]const u8) = .empty;
    var requirepass: ?[]const u8 = if (file_cfg) |c| c.requirepass else null;
    var replicaof_host: ?[]const u8 = if (file_cfg) |c| @constCast(c.replicaof_host) else null;
    var replicaof_port: ?u16 = if (file_cfg) |c| c.replicaof_port else null;
    var masterauth: ?[]const u8 = if (file_cfg) |c| c.masterauth else null;
    var tls_cert: ?[]const u8 = if (file_cfg) |c| c.tls_cert else null;
    var tls_key: ?[]const u8 = if (file_cfg) |c| c.tls_key else null;
    var tls_ca: ?[]const u8 = if (file_cfg) |c| c.tls_ca else null;
    var tls_replica = valBool(file_cfg, .tls_replica, false);
    var http_port: ?u16 = if (file_cfg) |c| c.http_port else null;
    var http_secret: ?[]const u8 = if (file_cfg) |c| c.http_secret else null;
    var http_sign_ttl: u64 = valInt(file_cfg, .http_sign_ttl, @as(u64, 3600));
    const http_rate_burst: f64 = valFloat(file_cfg, .http_rate_burst, 30);
    const http_rate_refill: f64 = valFloat(file_cfg, .http_rate_refill, 10);

    // 配置文件中的 disable_commands
    if (file_cfg) |c| {
        if (c.disable_commands) |cmds| {
            var iter = std.mem.splitSequence(u8, cmds, ",");
            while (iter.next()) |cmd| {
                const trimmed = std.mem.trim(u8, cmd, " \t");
                if (trimmed.len == 0) continue;
                const lowered = std.ascii.allocLowerString(allocator, trimmed) catch continue;
                disabled_commands_list.append(allocator, lowered) catch {
                    allocator.free(lowered);
                    continue;
                };
            }
        }
    }

    defer {
        for (disabled_commands_list.items) |cmd| allocator.free(cmd);
        disabled_commands_list.deinit(allocator);
    }

    // CLI 参数覆盖配置文件
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-H")) {
            if (args.next()) |val_| host = val_;
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |val_| port = std.fmt.parseInt(u16, val_, 10) catch {
                log.err("Invalid port: {s}", .{val_});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--data") or std.mem.eql(u8, arg, "-d")) {
            if (args.next()) |val_| data_path = val_;
        } else if (std.mem.eql(u8, arg, "--log-level") or std.mem.eql(u8, arg, "-l")) {
            if (args.next()) |val_| log_level = val_;
        } else if (std.mem.eql(u8, arg, "--disable-dangerous")) {
            disable_dangerous = true;
        } else if (std.mem.eql(u8, arg, "--disable-commands")) {
            if (args.next()) |val_| {
                var iter = std.mem.splitSequence(u8, val_, ",");
                while (iter.next()) |cmd| {
                    const trimmed = std.mem.trim(u8, cmd, " \t");
                    if (trimmed.len == 0) continue;
                    const lowered = std.ascii.allocLowerString(allocator, trimmed) catch continue;
                    disabled_commands_list.append(allocator, lowered) catch {
                        allocator.free(lowered);
                        continue;
                    };
                }
            }
        } else if (std.mem.eql(u8, arg, "--requirepass") or std.mem.eql(u8, arg, "-a")) {
            if (args.next()) |val_| requirepass = val_;
        } else if (std.mem.eql(u8, arg, "--replicaof")) {
            if (args.next()) |val_| {
                replicaof_host = val_;
                if (args.next()) |port_str| {
                    replicaof_port = std.fmt.parseInt(u16, port_str, 10) catch {
                        log.err("Invalid replicaof port: {s}", .{port_str});
                        return error.InvalidArgument;
                    };
                } else {
                    log.err("--replicaof requires <host> <port>", .{});
                    return error.InvalidArgument;
                }
            }
        } else if (std.mem.eql(u8, arg, "--masterauth")) {
            if (args.next()) |val_| masterauth = val_;
        } else if (std.mem.eql(u8, arg, "--tls-cert")) {
            if (args.next()) |val_| tls_cert = val_;
        } else if (std.mem.eql(u8, arg, "--tls-key")) {
            if (args.next()) |val_| tls_key = val_;
        } else if (std.mem.eql(u8, arg, "--tls-ca")) {
            if (args.next()) |val_| tls_ca = val_;
        } else if (std.mem.eql(u8, arg, "--tls-replica")) {
            tls_replica = true;
        } else if (std.mem.eql(u8, arg, "--http-port")) {
            if (args.next()) |val_| http_port = std.fmt.parseInt(u16, val_, 10) catch {
                log.err("Invalid HTTP port: {s}", .{val_});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--http-secret")) {
            if (args.next()) |val_| http_secret = val_;
        } else if (std.mem.eql(u8, arg, "--http-sign-ttl")) {
            if (args.next()) |val_| http_sign_ttl = std.fmt.parseInt(u64, val_, 10) catch {
                log.err("Invalid HTTP sign TTL: {s}", .{val_});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            _ = args.next(); // already handled above
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        }
    }

    // log-level 从配置文件或 CLI
    if (log_level) |ll| {
        const level = parseLogLevel(ll) orelse {
            log.err("Invalid log level: {s}. Use: debug, info, warn, error", .{ll});
            return error.InvalidArgument;
        };
        log.setLevel(level);
    } else if (file_cfg) |c| {
        if (c.log_level) |ll| {
            if (parseLogLevel(ll)) |level| {
                log.setLevel(level);
            } else {
                log.warn("Invalid log level in config: {s}", .{ll});
            }
        }
    }

    // --disable-dangerous 将 flushdb/flushall 追加到禁用列表（去重）
    if (disable_dangerous) {
        for (&dangerous_commands) |cmd| {
            var found = false;
            for (disabled_commands_list.items) |existing| {
                if (std.mem.eql(u8, existing, cmd)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const duped = allocator.dupe(u8, cmd) catch continue;
                disabled_commands_list.append(allocator, duped) catch {
                    allocator.free(duped);
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

    log.info("Starting NovelKV on {s}:{d}", .{ host, port });
    log.info("Data directory: {s}", .{data_path});
    if (requirepass) |_| log.info("Authentication required", .{});

    // TLS 初始化
    var tls_auth: ?tls.config.CertKeyPair = null;
    defer {
        if (tls_auth) |*a| a.deinit(allocator);
    }

    var tls_cfg: ?storage.TlsConfig = null;

    if (tls_cert != null and tls_key != null) {
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
    } else if (tls_cert != null or tls_key != null) {
        log.err("Both --tls-cert and --tls-key are required for TLS", .{});
        return error.InvalidArgument;
    }

    // HTTP 接口校验
    if (http_port != null and http_secret == null) {
        log.err("--http-secret is required when --http-port is set", .{});
        return error.InvalidArgument;
    }
    if (http_secret != null and http_port == null) {
        log.err("--http-port is required when --http-secret is set", .{});
        return error.InvalidArgument;
    }

    // 构建存储配置（配置文件中的 storage 参数覆盖）
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

    // 数据库打开后设置 TLS 状态
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
        // 主节点：初始化 MasterState
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

    if (http_port) |hp| {
        const http_cfg = http_server.HttpConfig{
            .port = hp,
            .secret = http_secret.?,
            .sign_ttl = http_sign_ttl,
            .host = host,
            .rate_limit_burst = http_rate_burst,
            .rate_limit_refill = http_rate_refill,
        };
        log.info("HTTP chapter API enabled: {s}:{d} (sign TTL: {d}s, burst: {d:.0}, refill: {d:.0}/s)", .{ host, hp, http_sign_ttl, http_rate_burst, http_rate_refill });
        group.concurrent(io, http_server.serve, .{
            io, allocator, &db, http_cfg, &shutdown_requested,
        }) catch {
            log.err("Failed to start HTTP server", .{});
            return error.StartupFailed;
        };
    }

    // 阻塞等待所有服务退出
    group.await(io) catch {};
}

/// RESP 服务协程入口，包装 server.serve 使其返回 Cancelable!void
fn serveResp(io: std.Io, allocator: std.mem.Allocator, db: *storage.Database, host: []const u8, port: u16, shutdown_flag: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    server.serve(io, allocator, db, host, port, shutdown_flag) catch |e| {
        if (!shutdown_flag.load(.acquire)) {
            log.err("RESP server error: {}", .{e});
        }
    };
}

// 配置值辅助函数：从 file_cfg 读取字段，null 时返回默认值
fn val(c: ?config_mod.Config, comptime field: std.meta.FieldEnum(config_mod.Config), default: [:0]const u8) [:0]const u8 {
    if (c) |cfg| {
        if (@field(cfg, @tagName(field))) |v| {
            // 配置文件中的 []const u8 可以安全转为 [:0]const u8（它们以 null 结尾分配）
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
        \\  -c, --config <PATH>        Load configuration file (Redis conf style)
        \\  -H, --host <HOST>          Listen address (default: 0.0.0.0)
        \\  -p, --port <PORT>          Listen port (default: 6379)
        \\  -d, --data <PATH>          Data directory (default: ./data)
        \\  -l, --log-level <LEVEL>    Log level: debug, info, warn, error (default: info)
        \\  --disable-dangerous        Disable dangerous commands (flushdb, flushall)
        \\  --disable-commands <LIST>  Comma-separated list of commands to disable
        \\  -a, --requirepass <PASS>   Require client authentication
        \\  --replicaof <HOST> <PORT>  Replicate from master (replica mode)
        \\  --masterauth <PASS>        Master authentication password
        \\  --tls-cert <PATH>          TLS certificate file (enables TLS)
        \\  --tls-key <PATH>           TLS private key file (required with --tls-cert)
        \\  --tls-ca <PATH>            CA certificate for client/replica verification
        \\  --tls-replica              Use TLS for replica-to-master connection
        \\  --http-port <PORT>         Enable HTTP chapter API on this port
        \\  --http-secret <SECRET>     HMAC-SHA256 secret key (required with --http-port)
        \\  --http-sign-ttl <SECONDS>  Signed URL TTL in seconds (default: 3600)
        \\  --help                     Show this help
        \\
        \\Config file format (Redis conf style, # for comments):
        \\  host 0.0.0.0
        \\  port 6379
        \\  data ./data
        \\  log-level info
        \\  requirepass mysecret
        \\  disable-dangerous yes
        \\  http-port 8080
        \\  http-secret mysecret
        \\  http-sign-ttl 3600
        \\  http-rate-burst 30
        \\  http-rate-refill 10
        \\  write-buffer-size 64mb
        \\  block-size 128kb
        \\  compression-level 9
        \\  bloom-bits 10
        \\
        \\CLI arguments override config file values.
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

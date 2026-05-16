// NovelKV - 专用小说章节文本 KV 存储系统
// 入口模块：命令行参数解析、信号处理、数据库与服务启动
const std = @import("std");
const resp = @import("resp.zig");
const server = @import("server.zig");
const command = @import("command.zig");
const storage = @import("storage.zig");
const replication = @import("replication.zig");
const log = @import("log.zig");
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

    var host: [:0]const u8 = "0.0.0.0";
    var port: u16 = 6379;
    var data_path: [:0]const u8 = "./data";
    var disable_dangerous = false;
    var disabled_commands_list: std.ArrayList([]const u8) = .empty;
    var requirepass: ?[]const u8 = null;
    var replicaof_host: ?[]const u8 = null;
    var replicaof_port: ?u16 = null;
    var masterauth: ?[]const u8 = null;
    var tls_cert: ?[]const u8 = null;
    var tls_key: ?[]const u8 = null;
    var tls_ca: ?[]const u8 = null;
    var tls_replica = false;
    defer {
        for (disabled_commands_list.items) |cmd| allocator.free(cmd);
        disabled_commands_list.deinit(allocator);
    }

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-H")) {
            if (args.next()) |val| {
                host = val;
            }
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |val| {
                port = std.fmt.parseInt(u16, val, 10) catch {
                    log.err("Invalid port: {s}", .{val});
                    return error.InvalidArgument;
                };
            }
        } else if (std.mem.eql(u8, arg, "--data") or std.mem.eql(u8, arg, "-d")) {
            if (args.next()) |val| {
                data_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--log-level") or std.mem.eql(u8, arg, "-l")) {
            if (args.next()) |val| {
                const level = parseLogLevel(val) orelse {
                    log.err("Invalid log level: {s}. Use: debug, info, warn, error", .{val});
                    return error.InvalidArgument;
                };
                log.setLevel(level);
            }
        } else if (std.mem.eql(u8, arg, "--disable-dangerous")) {
            disable_dangerous = true;
        } else if (std.mem.eql(u8, arg, "--disable-commands")) {
            if (args.next()) |val| {
                var iter = std.mem.splitSequence(u8, val, ",");
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
            if (args.next()) |val| {
                requirepass = val;
            }
        } else if (std.mem.eql(u8, arg, "--replicaof")) {
            if (args.next()) |val| {
                replicaof_host = val;
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
            if (args.next()) |val| {
                masterauth = val;
            }
        } else if (std.mem.eql(u8, arg, "--tls-cert")) {
            if (args.next()) |val| {
                tls_cert = val;
            }
        } else if (std.mem.eql(u8, arg, "--tls-key")) {
            if (args.next()) |val| {
                tls_key = val;
            }
        } else if (std.mem.eql(u8, arg, "--tls-ca")) {
            if (args.next()) |val| {
                tls_ca = val;
            }
        } else if (std.mem.eql(u8, arg, "--tls-replica")) {
            tls_replica = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
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

    var db = storage.Database.open(allocator, .{
        .path = data_path,
        .disabled_commands = disabled_commands_list.items,
        .password = requirepass,
        .tls_config = tls_cfg,
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

    server.serve(io, allocator, &db, host, port, &shutdown_requested) catch |e| {
        if (shutdown_requested.load(.acquire)) {
            log.info("Shutting down gracefully...", .{});
        } else {
            log.err("Server error: {}", .{e});
            return e;
        }
    };
}

fn printUsage() void {
    std.debug.print(
        \\NovelKV - 专用小说章节文本 KV 存储系统
        \\
        \\Usage: novelkv [OPTIONS]
        \\
        \\Options:
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
        \\  --help                     Show this help
        \\
        \\Examples:
        \\  novelkv
        \\  novelkv --requirepass mysecret
        \\  novelkv --tls-cert cert.pem --tls-key key.pem
        \\  novelkv --port 16380 --replicaof 127.0.0.1 16379 --tls-replica
        \\
        \\Compatible with Redis protocol (RESP). Use redis-cli or any Redis client to connect.
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
}

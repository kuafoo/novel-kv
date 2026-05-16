// NovelKV - 专用小说章节文本 KV 存储系统
// 存储引擎模块：RocksDB 封装、Column Family 管理、RwLock 并发控制
// Bloom Filter / Block Cache / Iterator / Snapshot / Multi-Get / Merge Operator / Statistics
const std = @import("std");
const rocksdb = @import("rocksdb");
const log = @import("log.zig");
const replication = @import("replication.zig");
const tls = @import("tls");

/// 最大数据库数量，对应 RocksDB Column Family 数量（db0..db15）
pub const MAX_DATABASES: usize = 16;

/// 键值对，用于批量写入接口
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const Config = struct {
    path: [:0]const u8,
    compression_level: c_int = 9,
    dict_size: c_int = 256 * 1024,
    zstd_train_bytes: c_int = 10_000_000,
    block_size: usize = 128 * 1024,
    write_buffer_size: usize = 64 * 1024 * 1024,
    max_write_buffer_number: c_int = 2,
    disabled_commands: []const []const u8 = &.{},
    password: ?[]const u8 = null,
    /// Block Cache 容量（字节），默认 256MB
    cache_size: usize = 256 * 1024 * 1024,
    /// Bloom Filter 每个_key 的位数，默认 10（约 1% 误判率）
    bloom_bits_per_key: f64 = 10.0,
    /// TLS 配置（非 null 表示启用 TLS）
    tls_config: ?TlsConfig = null,
};

pub const TlsConfig = struct {
    cert_file: []const u8,
    key_file: []const u8,
    ca_file: ?[]const u8 = null,
    /// 副本连接主节点时是否使用 TLS
    replica_tls: bool = false,
};

pub const Database = struct {
    db: *rocksdb.rocksdb_t,
    allocator: std.mem.Allocator,
    cf_handles: [MAX_DATABASES]*rocksdb.rocksdb_column_family_handle_t,
    rwlock: std.Io.RwLock,
    read_options: *rocksdb.rocksdb_readoptions_t,
    write_options: *rocksdb.rocksdb_writeoptions_t,
    disabled_commands: []const []const u8,
    password: ?[]const u8,
    filter_policy: ?*rocksdb.rocksdb_filterpolicy_t,
    block_cache: ?*rocksdb.rocksdb_cache_t,
    /// 主端复制状态（仅主节点有值）
    repl: ?*replication.MasterState = null,
    /// 是否为副本模式
    is_replica: bool = false,
    /// 副本是否已连接到主节点（副本端标志）
    is_replica_connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 副本配置（仅副本模式有值）
    repl_config: ?replication.ReplicaConfig = null,
    /// TLS 证书密钥对（启动时加载，所有 TLS 连接共享）
    tls_auth: ?tls.config.CertKeyPair = null,
    /// TLS 配置
    tls_config: ?TlsConfig = null,

    /// 打开或创建数据库。首次启动时自动创建 16 个 Column Family。
    /// 配置 Bloom Filter、Block Cache、Compaction 调优、Statistics 等引擎参数。
    pub fn open(allocator: std.mem.Allocator, config: Config) !Database {
        var err: [*c]u8 = null;

        const options = rocksdb.rocksdb_options_create();
        defer rocksdb.rocksdb_options_destroy(options);

        rocksdb.rocksdb_options_set_create_if_missing(options, 1);

        // ---- 压缩配置：Zstd 字典压缩，针对小说文本优化压缩比 ----
        rocksdb.rocksdb_options_set_compression(options, 7); // 7 = kZSTD
        rocksdb.rocksdb_options_set_compression_options(options, 0, config.compression_level, 0, config.dict_size);
        rocksdb.rocksdb_options_set_compression_options_zstd_max_train_bytes(options, config.zstd_train_bytes);
        rocksdb.rocksdb_options_set_compression_options_use_zstd_dict_trainer(options, 1);

        // ---- Block-Based Table 配置：Bloom Filter + Block Cache ----
        const block_opts = rocksdb.rocksdb_block_based_options_create();
        defer rocksdb.rocksdb_block_based_options_destroy(block_opts);
        rocksdb.rocksdb_block_based_options_set_block_size(block_opts, config.block_size);

        // Bloom Filter：减少不存在的 key 的磁盘 I/O
        const filter_policy = rocksdb.rocksdb_filterpolicy_create_bloom(config.bloom_bits_per_key);
        rocksdb.rocksdb_block_based_options_set_filter_policy(block_opts, filter_policy);

        // LRU Block Cache：缓存热数据 block，避免重复磁盘读取
        const block_cache = rocksdb.rocksdb_cache_create_lru(config.cache_size);
        rocksdb.rocksdb_block_based_options_set_block_cache(block_opts, block_cache);
        // 将索引和 filter block 也缓存，避免每次查询都读索引
        rocksdb.rocksdb_block_based_options_set_cache_index_and_filter_blocks(block_opts, 1);
        // L0 的 index/filter block 常驻缓存（L0 文件数量少，开销低）
        rocksdb.rocksdb_block_based_options_set_pin_l0_filter_and_index_blocks_in_cache(block_opts, 1);

        rocksdb.rocksdb_options_set_block_based_table_factory(options, block_opts);

        // ---- Write Buffer 配置 ----
        rocksdb.rocksdb_options_set_write_buffer_size(options, config.write_buffer_size);
        rocksdb.rocksdb_options_set_max_write_buffer_number(options, config.max_write_buffer_number);

        // ---- Compaction 调优（写一次读多次的小说存储场景）----
        rocksdb.rocksdb_options_set_max_background_jobs(options, 4);
        rocksdb.rocksdb_options_set_level0_file_num_compaction_trigger(options, 4);
        rocksdb.rocksdb_options_set_level0_slowdown_writes_trigger(options, 20);
        rocksdb.rocksdb_options_set_level0_stop_writes_trigger(options, 36);

        // ---- Statistics：收集性能指标，供 INFO 命令展示 ----
        // except_histogram_or_timers = 1，收集 ticker 计数器，开销极低
        rocksdb.rocksdb_options_set_statistics_level(options, 1);
        rocksdb.rocksdb_options_set_stats_persist_period_sec(options, 600);

        // ---- Merge Operator：字符串追加（用于 APPEND 命令）----
        const merge_op = rocksdb.rocksdb_mergeoperator_create(
            null,
            // destructor
            struct {
                fn f(ctx: ?*anyopaque) callconv(.c) void {
                    _ = ctx;
                }
            }.f,
            // full_merge: existing + operands 拼接
            struct {
                fn f(ctx: ?*anyopaque, key: [*c]const u8, klen: usize, existing: [*c]const u8, elen: usize, operands: [*c]const [*c]const u8, op_lens: [*c]const usize, nops: c_int, success: [*c]u8, out_len: [*c]usize) callconv(.c) [*c]u8 {
                    _ = ctx;
                    _ = key;
                    _ = klen;
                    var total: usize = if (elen > 0) elen else 0;
                    for (0..@intCast(nops)) |i| total += op_lens[i];
                    const buf = std.c.malloc(total) orelse {
                        success.* = 0;
                        return null;
                    };
                    var offset: usize = 0;
                    if (elen > 0) {
                        @memcpy(@as([*]u8, @ptrCast(@alignCast(buf)))[0..elen], existing[0..elen]);
                        offset = elen;
                    }
                    for (0..@intCast(nops)) |i| {
                        @memcpy(@as([*]u8, @ptrCast(@alignCast(buf)))[offset .. offset + op_lens[i]], operands[i][0..op_lens[i]]);
                        offset += op_lens[i];
                    }
                    out_len.* = total;
                    success.* = 1;
                    return @ptrCast(@alignCast(buf));
                }
            }.f,
            // partial_merge: 交给 full_merge 处理
            struct {
                fn f(ctx: ?*anyopaque, key: [*c]const u8, klen: usize, operands: [*c]const [*c]const u8, op_lens: [*c]const usize, nops: c_int, success: [*c]u8, out_len: [*c]usize) callconv(.c) [*c]u8 {
                    _ = ctx;
                    _ = key;
                    _ = klen;
                    var total: usize = 0;
                    for (0..@intCast(nops)) |i| total += op_lens[i];
                    const buf = std.c.malloc(total) orelse {
                        success.* = 0;
                        return null;
                    };
                    var offset: usize = 0;
                    for (0..@intCast(nops)) |i| {
                        @memcpy(@as([*]u8, @ptrCast(@alignCast(buf)))[offset .. offset + op_lens[i]], operands[i][0..op_lens[i]]);
                        offset += op_lens[i];
                    }
                    out_len.* = total;
                    success.* = 1;
                    return @ptrCast(@alignCast(buf));
                }
            }.f,
            // delete_value
            struct {
                fn f(ctx: ?*anyopaque, val: [*c]const u8, vlen: usize) callconv(.c) void {
                    _ = ctx;
                    _ = val;
                    _ = vlen;
                }
            }.f,
            // name
            struct {
                fn f(ctx: ?*anyopaque) callconv(.c) [*c]const u8 {
                    _ = ctx;
                    return "novelkv-append";
                }
            }.f,
        );
        rocksdb.rocksdb_options_set_merge_operator(options, merge_op);

        // CF 命名：db0 使用 RocksDB 默认 "default"，db1..db15 命名为 "db1".."db15"
        var name_bufs: [MAX_DATABASES - 1][8:0]u8 = undefined;
        var cf_names: [MAX_DATABASES][*:0]const u8 = undefined;
        cf_names[0] = "default";
        for (1..MAX_DATABASES) |i| {
            cf_names[i] = std.fmt.bufPrintSentinel(&name_bufs[i - 1], "db{d}", .{i}, 0) catch unreachable;
        }

        // 首先尝试带全部 CF 打开（已有数据库的情况）
        const opts_const: *const rocksdb.rocksdb_options_t = options orelse return error.OpenFailed;
        var cf_opts: [MAX_DATABASES]?*const rocksdb.rocksdb_options_t = @splat(opts_const);

        err = null;
        var handles: [MAX_DATABASES]?*rocksdb.rocksdb_column_family_handle_t = @splat(null);
        const maybe_db = rocksdb.rocksdb_open_column_families(
            options,
            config.path.ptr,
            @intCast(MAX_DATABASES),
            &cf_names,
            &cf_opts,
            &handles,
            &err,
        );
        if (err) |e| rocksdb.rocksdb_free(e);

        if (maybe_db == null) {
            err = null;
            const init_db = rocksdb.rocksdb_open(options, config.path.ptr, &err) orelse {
                if (err) |e| {
                    log.err("Failed to open database: {s}", .{e});
                    rocksdb.rocksdb_free(e);
                }
                return error.OpenFailed;
            };
            for (1..MAX_DATABASES) |i| {
                err = null;
                const handle = rocksdb.rocksdb_create_column_family(init_db, options, cf_names[i], &err);
                if (handle) |h| rocksdb.rocksdb_column_family_handle_destroy(h);
                if (err) |e| rocksdb.rocksdb_free(e);
            }
            rocksdb.rocksdb_close(init_db);

            err = null;
            handles = @splat(null);
            const db = rocksdb.rocksdb_open_column_families(
                options,
                config.path.ptr,
                @intCast(MAX_DATABASES),
                &cf_names,
                &cf_opts,
                &handles,
                &err,
            ) orelse {
                if (err) |e| {
                    log.err("Failed to open database with column families: {s}", .{e});
                    rocksdb.rocksdb_free(e);
                }
                return error.OpenFailed;
            };

            var cf_handles: [MAX_DATABASES]*rocksdb.rocksdb_column_family_handle_t = undefined;
            for (0..MAX_DATABASES) |i| {
                cf_handles[i] = handles[i] orelse {
                    log.err("Missing column family handle for db{d}", .{i});
                    for (0..i) |j| rocksdb.rocksdb_column_family_handle_destroy(cf_handles[j]);
                    rocksdb.rocksdb_close(db);
                    return error.OpenFailed;
                };
            }

            const read_options = rocksdb.rocksdb_readoptions_create() orelse return error.OpenFailed;
            const write_options = rocksdb.rocksdb_writeoptions_create() orelse return error.OpenFailed;

            log.info("Database created: {s} ({d} column families)", .{ config.path, MAX_DATABASES });
            return Database{
                .db = db,
                .allocator = allocator,
                .cf_handles = cf_handles,
                .rwlock = std.Io.RwLock.init,
                .read_options = read_options,
                .write_options = write_options,
                .disabled_commands = config.disabled_commands,
                .password = config.password,
                .filter_policy = filter_policy,
                .block_cache = block_cache,
            };
        }

        const db = maybe_db orelse unreachable;

        var cf_handles: [MAX_DATABASES]*rocksdb.rocksdb_column_family_handle_t = undefined;
        for (0..MAX_DATABASES) |i| {
            cf_handles[i] = handles[i] orelse {
                log.err("Missing column family handle for db{d}", .{i});
                for (0..i) |j| rocksdb.rocksdb_column_family_handle_destroy(cf_handles[j]);
                rocksdb.rocksdb_close(db);
                return error.OpenFailed;
            };
        }

        const read_options = rocksdb.rocksdb_readoptions_create() orelse return error.OpenFailed;
        const write_options = rocksdb.rocksdb_writeoptions_create() orelse return error.OpenFailed;

        log.info("Database opened: {s} ({d} column families)", .{ config.path, MAX_DATABASES });
        return Database{
            .db = db,
            .allocator = allocator,
            .cf_handles = cf_handles,
            .rwlock = std.Io.RwLock.init,
            .read_options = read_options,
            .write_options = write_options,
            .disabled_commands = config.disabled_commands,
            .password = config.password,
            .filter_policy = filter_policy,
            .block_cache = block_cache,
        };
    }

    pub fn close(self: *Database) void {
        for (&self.cf_handles) |*handle| {
            rocksdb.rocksdb_column_family_handle_destroy(handle.*);
        }
        rocksdb.rocksdb_readoptions_destroy(self.read_options);
        rocksdb.rocksdb_writeoptions_destroy(self.write_options);
        if (self.filter_policy) |fp| rocksdb.rocksdb_filterpolicy_destroy(fp);
        if (self.block_cache) |bc| rocksdb.rocksdb_cache_destroy(bc);
        rocksdb.rocksdb_close(self.db);
        log.info("Database closed", .{});
    }

    // ---- RwLock 并发控制 ----

    pub fn rlock(self: *Database, io: std.Io) void {
        self.rwlock.lockSharedUncancelable(io);
    }

    pub fn runlock(self: *Database, io: std.Io) void {
        self.rwlock.unlockShared(io);
    }

    pub fn wlock(self: *Database, io: std.Io) void {
        self.rwlock.lockUncancelable(io);
    }

    pub fn wunlock(self: *Database, io: std.Io) void {
        self.rwlock.unlock(io);
    }

    pub fn isCommandDisabled(self: *Database, cmd: []const u8) bool {
        for (self.disabled_commands) |disabled| {
            if (std.mem.eql(u8, cmd, disabled)) return true;
        }
        return false;
    }

    /// 单 key 读取
    pub fn get(self: *Database, key: []const u8, db_index: usize) error{ReadFailed}!?[]const u8 {
        var err: [*c]u8 = null;
        var value_len: usize = 0;
        const cf = self.cf_handles[db_index];

        const value = rocksdb.rocksdb_get_cf(self.db, self.read_options, cf, key.ptr, key.len, &value_len, &err);

        if (err) |e| {
            log.err("rocksdb_get_cf error: {s}", .{e});
            rocksdb.rocksdb_free(e);
            return error.ReadFailed;
        }

        if (value) |v| {
            return v[0..value_len];
        }
        return null;
    }

    /// 批量多 key 读取（利用 rocksdb_multi_get_cf 合并 I/O）
    pub fn multiGet(self: *Database, keys: []const []const u8, db_index: usize) error{ReadFailed}![]?[]const u8 {
        const cf = self.cf_handles[db_index];
        const n = keys.len;

        const key_ptrs = self.allocator.alloc([*c]const u8, n) catch return error.ReadFailed;
        defer self.allocator.free(key_ptrs);
        const key_lens = self.allocator.alloc(usize, n) catch return error.ReadFailed;
        defer self.allocator.free(key_lens);
        const cf_arr = self.allocator.alloc(?*const rocksdb.rocksdb_column_family_handle_t, n) catch return error.ReadFailed;
        defer self.allocator.free(cf_arr);
        const val_ptrs = self.allocator.alloc([*c]u8, n) catch return error.ReadFailed;
        const val_lens = self.allocator.alloc(usize, n) catch return error.ReadFailed;
        const errs = self.allocator.alloc([*c]u8, n) catch return error.ReadFailed;

        for (keys, 0..) |k, i| {
            key_ptrs[i] = k.ptr;
            key_lens[i] = k.len;
            cf_arr[i] = cf;
            val_ptrs[i] = null;
            val_lens[i] = 0;
            errs[i] = null;
        }

        rocksdb.rocksdb_multi_get_cf(
            self.db,
            self.read_options,
            cf_arr.ptr,
            n,
            key_ptrs.ptr,
            key_lens.ptr,
            val_ptrs.ptr,
            val_lens.ptr,
            errs.ptr,
        );

        const results = self.allocator.alloc(?[]const u8, n) catch return error.ReadFailed;
        for (0..n) |i| {
            if (errs[i] != null) {
                rocksdb.rocksdb_free(errs[i]);
                results[i] = null;
            } else if (val_ptrs[i] != null) {
                results[i] = val_ptrs[i][0..val_lens[i]];
            } else {
                results[i] = null;
            }
        }
        self.allocator.free(val_lens);
        self.allocator.free(errs);
        self.allocator.free(val_ptrs);

        return results;
    }

    pub fn put(self: *Database, key: []const u8, value: []const u8, db_index: usize) !void {
        var err: [*c]u8 = null;
        const cf = self.cf_handles[db_index];

        rocksdb.rocksdb_put_cf(self.db, self.write_options, cf, key.ptr, key.len, value.ptr, value.len, &err);

        if (err) |e| {
            log.err("rocksdb_put_cf error: {s}", .{e});
            rocksdb.rocksdb_free(e);
            return error.WriteFailed;
        }
    }

    /// Merge 操作：将 value 追加到 key 的现有值末尾（由 Merge Operator 处理）
    pub fn merge(self: *Database, key: []const u8, value: []const u8, db_index: usize) !void {
        var err: [*c]u8 = null;
        const cf = self.cf_handles[db_index];

        rocksdb.rocksdb_merge_cf(self.db, self.write_options, cf, key.ptr, key.len, value.ptr, value.len, &err);

        if (err) |e| {
            log.err("rocksdb_merge_cf error: {s}", .{e});
            rocksdb.rocksdb_free(e);
            return error.WriteFailed;
        }
    }

    pub fn delete(self: *Database, key: []const u8, db_index: usize) !void {
        var err: [*c]u8 = null;
        const cf = self.cf_handles[db_index];

        rocksdb.rocksdb_delete_cf(self.db, self.write_options, cf, key.ptr, key.len, &err);

        if (err) |e| {
            log.err("rocksdb_delete_cf error: {s}", .{e});
            rocksdb.rocksdb_free(e);
            return error.DeleteFailed;
        }
    }

    pub fn estimateKeyCount(self: *Database, db_index: usize) u64 {
        var result: u64 = 0;
        const cf = self.cf_handles[db_index];
        const rc = rocksdb.rocksdb_property_int_cf(self.db, cf, "rocksdb.estimate-num-keys", &result);
        _ = rc;
        return result;
    }

    /// 获取 Block Cache 命中率统计
    pub fn getCacheStats(self: *Database) struct { usage: u64, capacity: u64 } {
        var usage: u64 = 0;
        if (self.block_cache) |bc| {
            usage = rocksdb.rocksdb_cache_get_usage(bc);
            var capacity: u64 = 0;
            // rocksdb_cache_get_capacity 不在 C API 中，通过 config 推算
            _ = rocksdb.rocksdb_property_int(self.db, "rocksdb.block-cache-capacity", &capacity);
            return .{ .usage = usage, .capacity = capacity };
        }
        return .{ .usage = 0, .capacity = 0 };
    }

    /// 获取 CF 的 SST 文件数和总大小（字节）
    pub fn getCFStats(self: *Database, db_index: usize) struct { live_sst_files: u64, live_sst_size: u64 } {
        const cf = self.cf_handles[db_index];
        var live_files: u64 = 0;
        _ = rocksdb.rocksdb_property_int_cf(self.db, cf, "rocksdb.num-files-at-level0", &live_files);
        var total_size: u64 = 0;
        const val: [*c]u8 = rocksdb.rocksdb_property_value_cf(self.db, cf, "rocksdb.total-sst-files-size");
        if (val) |v| {
            total_size = std.fmt.parseInt(u64, std.mem.sliceTo(v, 0), 10) catch 0;
            rocksdb.rocksdb_free(v);
        }
        return .{ .live_sst_files = live_files, .live_sst_size = total_size };
    }

    pub fn flushDatabase(self: *Database, db_index: usize) !void {
        if (db_index == 0) {
            const cf = self.cf_handles[0];
            var err: [*c]u8 = null;
            const start_key = "";
            const end_key = "\xff\xff\xff\xff\xff\xff\xff\xff";
            rocksdb.rocksdb_delete_range_cf(self.db, self.write_options, cf, start_key, 0, end_key, end_key.len, &err);
            if (err) |e| {
                log.err("rocksdb_delete_range_cf error for default CF: {s}", .{e});
                rocksdb.rocksdb_free(e);
                return error.WriteFailed;
            }
        } else {
            const cf = self.cf_handles[db_index];

            var name_buf: [8:0]u8 = undefined;
            const cf_name = std.fmt.bufPrintSentinel(&name_buf, "db{d}", .{db_index}, 0) catch unreachable;

            var err: [*c]u8 = null;
            rocksdb.rocksdb_drop_column_family(self.db, cf, &err);
            if (err) |e| {
                log.err("rocksdb_drop_column_family error: {s}", .{e});
                rocksdb.rocksdb_free(e);
                return error.WriteFailed;
            }
            rocksdb.rocksdb_column_family_handle_destroy(cf);

            const cf_options = rocksdb.rocksdb_options_create();
            defer rocksdb.rocksdb_options_destroy(cf_options);
            const new_handle = rocksdb.rocksdb_create_column_family(self.db, cf_options, cf_name, &err);
            if (err) |e| {
                log.err("rocksdb_create_column_family error after drop: {s} — data for db{d} may be lost!", .{ e, db_index });
                rocksdb.rocksdb_free(e);
                return error.WriteFailed;
            }
            self.cf_handles[db_index] = new_handle orelse {
                log.err("rocksdb_create_column_family returned null for db{d} — data may be lost!", .{db_index});
                return error.WriteFailed;
            };
        }
    }

    /// 创建 Snapshot，用于一致性地读取或备份，不阻塞写入。
    pub fn createSnapshot(self: *Database) ?*const rocksdb.rocksdb_snapshot_t {
        return rocksdb.rocksdb_create_snapshot(self.db);
    }

    pub fn releaseSnapshot(self: *Database, snapshot: ?*const rocksdb.rocksdb_snapshot_t) void {
        rocksdb.rocksdb_release_snapshot(self.db, snapshot);
    }

    /// 在 Snapshot 视图下创建 Checkpoint（BGSAVE 不再需要写锁）
    pub fn createCheckpointWithSnapshot(self: *Database, checkpoint_dir: [:0]const u8) !void {
        var err: [*c]u8 = null;
        const checkpoint = rocksdb.rocksdb_checkpoint_object_create(self.db, &err);
        if (err) |e| {
            log.err("rocksdb_checkpoint_object_create error: {s}", .{e});
            rocksdb.rocksdb_free(e);
            return error.WriteFailed;
        }
        defer rocksdb.rocksdb_checkpoint_object_destroy(checkpoint);

        rocksdb.rocksdb_checkpoint_create(checkpoint, checkpoint_dir.ptr, 0, &err);
        if (err) |e| {
            log.err("rocksdb_checkpoint_create error: {s}", .{e});
            rocksdb.rocksdb_free(e);
            return error.WriteFailed;
        }
    }

    /// Iterator 范围扫描：从 prefix 开始，返回最多 limit 个 key。
    /// 调用方负责释放返回的 keys 数组及其中每个元素。
    pub fn scanKeys(self: *Database, allocator: std.mem.Allocator, prefix: []const u8, db_index: usize, limit: usize) ![]const []const u8 {
        const cf = self.cf_handles[db_index];
        const iter = rocksdb.rocksdb_create_iterator_cf(self.db, self.read_options, cf);
        defer rocksdb.rocksdb_iter_destroy(iter);

        if (prefix.len > 0) {
            rocksdb.rocksdb_iter_seek(iter, prefix.ptr, prefix.len);
        } else {
            rocksdb.rocksdb_iter_seek_to_first(iter);
        }

        var keys = std.ArrayList([]const u8).initCapacity(allocator, @min(limit, 256)) catch
            return &.{};

        while (rocksdb.rocksdb_iter_valid(iter) != 0 and keys.items.len < limit) {
            var key_len: usize = 0;
            const key = rocksdb.rocksdb_iter_key(iter, &key_len);
            if (key_len == 0) break;

            // 前缀不匹配时停止（RocksDB 按 key 有序排列）
            if (prefix.len > 0) {
                if (key_len < prefix.len or !std.mem.eql(u8, key[0..prefix.len], prefix)) {
                    break;
                }
            }

            const duped = allocator.dupe(u8, key[0..key_len]) catch break;
            keys.appendAssumeCapacity(duped);
            rocksdb.rocksdb_iter_next(iter);
        }

        return keys.toOwnedSlice(allocator) catch &.{};
    }

    /// Iterator 范围扫描：返回 key-value 对。
    pub fn scanKeyValues(self: *Database, allocator: std.mem.Allocator, prefix: []const u8, db_index: usize, limit: usize) ![]const KeyValue {
        const cf = self.cf_handles[db_index];
        const iter = rocksdb.rocksdb_create_iterator_cf(self.db, self.read_options, cf);
        defer rocksdb.rocksdb_iter_destroy(iter);

        if (prefix.len > 0) {
            rocksdb.rocksdb_iter_seek(iter, prefix.ptr, prefix.len);
        } else {
            rocksdb.rocksdb_iter_seek_to_first(iter);
        }

        var items = std.ArrayList(KeyValue).initCapacity(allocator, @min(limit, 256)) catch
            return &.{};

        while (rocksdb.rocksdb_iter_valid(iter) != 0 and items.items.len < limit) {
            var key_len: usize = 0;
            var val_len: usize = 0;
            const key = rocksdb.rocksdb_iter_key(iter, &key_len);
            const val = rocksdb.rocksdb_iter_value(iter, &val_len);
            if (key_len == 0) break;

            if (prefix.len > 0) {
                if (key_len < prefix.len or !std.mem.eql(u8, key[0..prefix.len], prefix)) {
                    break;
                }
            }

            const duped_key = allocator.dupe(u8, key[0..key_len]) catch break;
            const duped_val = allocator.dupe(u8, val[0..val_len]) catch {
                allocator.free(duped_key);
                break;
            };
            items.appendAssumeCapacity(.{ .key = duped_key, .value = duped_val });
            rocksdb.rocksdb_iter_next(iter);
        }

        return items.toOwnedSlice(allocator) catch &.{};
    }

    pub fn atomicPut(self: *Database, pairs: []const KeyValue, db_index: usize) !void {
        const cf = self.cf_handles[db_index];
        var err: [*c]u8 = null;

        const batch = rocksdb.rocksdb_writebatch_create();
        defer rocksdb.rocksdb_writebatch_destroy(batch);

        for (pairs) |pair| {
            rocksdb.rocksdb_writebatch_put_cf(batch, cf, pair.key.ptr, pair.key.len, pair.value.ptr, pair.value.len);
        }

        rocksdb.rocksdb_write(self.db, self.write_options, batch, &err);
        if (err) |e| {
            log.err("rocksdb_write batch error: {s}", .{e});
            rocksdb.rocksdb_free(e);
            return error.WriteFailed;
        }
    }
};

/// 释放 RocksDB 通过 rocksdb_get_cf 返回的值内存
pub fn freeValue(value: []const u8) void {
    rocksdb.rocksdb_free(@constCast(value.ptr));
}

test "Database open put get delete" {
    const allocator = std.testing.allocator;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/novelkv_test_{d}", .{std.posix.system.getpid()}, 0);

    var db = try Database.open(allocator, .{ .path = path });
    defer {
        db.close();
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
    }

    try db.put("hello", "world", 0);
    const val = try db.get("hello", 0);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("world", val.?);
    freeValue(val.?);

    try db.delete("hello", 0);
    const val2 = try db.get("hello", 0);
    try std.testing.expect(val2 == null);
}

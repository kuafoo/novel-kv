const std = @import("std");
const rocksdb = @import("rocksdb");

const CompressionConfig = struct {
    name: []const u8,
    compression_type: c_int,
    window_bits: c_int = 0,
    level: c_int = 0,
    strategy: c_int = 0,
    max_dict_bytes: c_int = 0,
    zstd_max_train_bytes: c_int = 0,
    use_zstd_dict_trainer: bool = false,
    max_dict_buffer_bytes: u64 = 0,
    bottommost_enabled: bool = false,
    bottommost_level: c_int = 0,
    bottommost_window_bits: c_int = 0,
    bottommost_strategy: c_int = 0,
    bottommost_max_dict_bytes: c_int = 0,
    bottommost_zstd_max_train_bytes: c_int = 0,
    bottommost_use_zstd_dict_trainer: bool = false,
    bottommost_max_dict_buffer_bytes: u64 = 0,
    block_size: usize = 4096,
};

const BenchmarkResult = struct {
    name: []const u8,
    raw_bytes: u64,
    db_bytes: u64,
    ratio: f64,
    write_ms: u64,
    compact_ms: u64,
    chapter_count: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const chapters_dir: []const u8 = "./test-chapters";

    var chapter_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (chapter_files.items) |p| allocator.free(p);
        chapter_files.deinit(allocator);
    }

    var dir = try std.Io.Dir.cwd().openDir(io, chapters_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".txt")) {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ chapters_dir, entry.path });
            try chapter_files.append(allocator, path);
        }
    }

    std.debug.print("Found {d} chapter files\n", .{chapter_files.items.len});

    if (chapter_files.items.len == 0) {
        std.debug.print("No chapter files found in {s}\n", .{chapters_dir});
        return;
    }

    var raw_bytes: u64 = 0;
    for (chapter_files.items) |path| {
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        raw_bytes += stat.size;
    }

    std.debug.print("Raw data size: {d} bytes ({d:.1} MB)\n", .{ raw_bytes, @as(f64, @floatFromInt(raw_bytes)) / 1024.0 / 1024.0 });

    const configs = [_]CompressionConfig{
        // Baseline: no compression
        .{ .name = "no_compression", .compression_type = 0 },
        // Levels 1,3,5,7,9,12,15,19 without dict, default 4KB block
        .{ .name = "zstd_l1_4kb", .compression_type = 7, .level = 1, .block_size = 4096 },
        .{ .name = "zstd_l3_4kb", .compression_type = 7, .level = 3, .block_size = 4096 },
        .{ .name = "zstd_l5_4kb", .compression_type = 7, .level = 5, .block_size = 4096 },
        .{ .name = "zstd_l7_4kb", .compression_type = 7, .level = 7, .block_size = 4096 },
        .{ .name = "zstd_l9_4kb", .compression_type = 7, .level = 9, .block_size = 4096 },
        .{ .name = "zstd_l12_4kb", .compression_type = 7, .level = 12, .block_size = 4096 },
        .{ .name = "zstd_l15_4kb", .compression_type = 7, .level = 15, .block_size = 4096 },
        .{ .name = "zstd_l19_4kb", .compression_type = 7, .level = 19, .block_size = 4096 },
        // Block size sweep: level 9, no dict, 4K/16K/32K/64K/128K/256K
        .{ .name = "zstd_l9_16kb", .compression_type = 7, .level = 9, .block_size = 16 * 1024 },
        .{ .name = "zstd_l9_32kb", .compression_type = 7, .level = 9, .block_size = 32 * 1024 },
        .{ .name = "zstd_l9_64kb", .compression_type = 7, .level = 9, .block_size = 64 * 1024 },
        .{ .name = "zstd_l9_128kb", .compression_type = 7, .level = 9, .block_size = 128 * 1024 },
        .{ .name = "zstd_l9_256kb", .compression_type = 7, .level = 9, .block_size = 256 * 1024 },
        // Dict size sweep: level 9, 128KB block, dict 32K/64K/128K/256K/512K/1M
        .{ .name = "dict32k_l9_128kb", .compression_type = 7, .level = 9, .max_dict_bytes = 32 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 128 * 1024 },
        .{ .name = "dict64k_l9_128kb", .compression_type = 7, .level = 9, .max_dict_bytes = 64 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 128 * 1024 },
        .{ .name = "dict128k_l9_128kb", .compression_type = 7, .level = 9, .max_dict_bytes = 128 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 128 * 1024 },
        .{ .name = "dict256k_l9_128kb", .compression_type = 7, .level = 9, .max_dict_bytes = 256 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 128 * 1024 },
        .{ .name = "dict512k_l9_128kb", .compression_type = 7, .level = 9, .max_dict_bytes = 512 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 128 * 1024 },
        .{ .name = "dict1m_l9_128kb", .compression_type = 7, .level = 9, .max_dict_bytes = 1024 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 128 * 1024 },
        // Best ratio candidates: high level + large dict + large block
        .{ .name = "dict512k_l15_128kb", .compression_type = 7, .level = 15, .max_dict_bytes = 512 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 128 * 1024 },
        .{ .name = "dict512k_l19_128kb", .compression_type = 7, .level = 19, .max_dict_bytes = 512 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 128 * 1024 },
        .{ .name = "dict1m_l15_256kb", .compression_type = 7, .level = 15, .max_dict_bytes = 1024 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 256 * 1024 },
        .{ .name = "dict1m_l19_256kb", .compression_type = 7, .level = 19, .max_dict_bytes = 1024 * 1024, .zstd_max_train_bytes = 10_000_000, .use_zstd_dict_trainer = true, .block_size = 256 * 1024 },
    };

    var results: std.ArrayList(BenchmarkResult) = .empty;
    defer results.deinit(allocator);

    for (&configs) |config| {
        std.debug.print("\n=== Testing: {s} ===\n", .{config.name});

        const db_path = try std.fmt.allocPrintSentinel(allocator, "/tmp/novelkv_bench_{s}", .{config.name}, 0);
        defer allocator.free(db_path);

        std.Io.Dir.cwd().deleteTree(io, db_path) catch {};

        const db = openDbWithConfig(db_path, config) catch |err| {
            std.debug.print("  Failed to open DB: {}\n", .{err});
            continue;
        };

        const write_start = clockMs();
        var chapter_count: u64 = 0;

        for (chapter_files.items, 0..) |path, i| {
            const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10_000_000)) catch continue;
            defer allocator.free(content);

            var key_buf: [64]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "chapter:{d}", .{i});

            putKey(db, key, content) catch continue;
            chapter_count += 1;
        }

        const write_end = clockMs();
        const write_ms = write_end - write_start;

        const compact_start = clockMs();
        rocksdb.rocksdb_compact_range(db, null, 0, null, 0);
        const compact_end = clockMs();
        const compact_ms = compact_end - compact_start;

        const db_bytes = getDirSize(io, db_path);

        const ratio = if (db_bytes > 0) @as(f64, @floatFromInt(raw_bytes)) / @as(f64, @floatFromInt(db_bytes)) else 0;

        std.debug.print("  Chapters: {d}, Raw: {d} bytes, DB: {d} bytes, Ratio: {d:.2}x\n", .{ chapter_count, raw_bytes, db_bytes, ratio });
        std.debug.print("  Write: {d}ms, Compact: {d}ms\n", .{ write_ms, compact_ms });

        try results.append(allocator, .{
            .name = config.name,
            .raw_bytes = raw_bytes,
            .db_bytes = db_bytes,
            .ratio = ratio,
            .write_ms = write_ms,
            .compact_ms = compact_ms,
            .chapter_count = chapter_count,
        });

        rocksdb.rocksdb_close(db);
        std.Io.Dir.cwd().deleteTree(io, db_path) catch {};
    }

    std.debug.print("\n================================================================================\n", .{});
    std.debug.print("COMPRESSION BENCHMARK SUMMARY\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("Raw data: {d} bytes ({d:.1} MB), {d} chapters\n\n", .{ raw_bytes, @as(f64, @floatFromInt(raw_bytes)) / 1024.0 / 1024.0, chapter_files.items.len });

    for (results.items) |r| {
        const db_mb = @as(f64, @floatFromInt(r.db_bytes)) / 1024.0 / 1024.0;
        std.debug.print("{s:<40} DB={d:.1}MB Ratio={d:.2}x Write={d}ms Compact={d}ms\n", .{ r.name, db_mb, r.ratio, r.write_ms, r.compact_ms });
    }
}

fn openDbWithConfig(db_path: [:0]const u8, config: CompressionConfig) !*rocksdb.rocksdb_t {
    var err: [*c]u8 = null;

    const opts = rocksdb.rocksdb_options_create();
    defer rocksdb.rocksdb_options_destroy(opts);

    rocksdb.rocksdb_options_set_create_if_missing(opts, 1);
    rocksdb.rocksdb_options_set_compression(opts, config.compression_type);
    rocksdb.rocksdb_options_set_compression_options(opts, config.window_bits, config.level, config.strategy, config.max_dict_bytes);

    if (config.zstd_max_train_bytes > 0) {
        rocksdb.rocksdb_options_set_compression_options_zstd_max_train_bytes(opts, config.zstd_max_train_bytes);
    }
    if (config.use_zstd_dict_trainer) {
        rocksdb.rocksdb_options_set_compression_options_use_zstd_dict_trainer(opts, 1);
    }
    if (config.max_dict_buffer_bytes > 0) {
        rocksdb.rocksdb_options_set_compression_options_max_dict_buffer_bytes(opts, config.max_dict_buffer_bytes);
    }

    if (config.bottommost_enabled) {
        rocksdb.rocksdb_options_set_bottommost_compression_options(opts, config.bottommost_window_bits, config.bottommost_level, config.bottommost_strategy, config.bottommost_max_dict_bytes, 1);
        if (config.bottommost_zstd_max_train_bytes > 0) {
            rocksdb.rocksdb_options_set_bottommost_compression_options_zstd_max_train_bytes(opts, config.bottommost_zstd_max_train_bytes, 1);
        }
        if (config.bottommost_use_zstd_dict_trainer) {
            rocksdb.rocksdb_options_set_bottommost_compression_options_use_zstd_dict_trainer(opts, 1, 1);
        }
        rocksdb.rocksdb_options_set_bottommost_compression(opts, 7);
    }

    const block_opts = rocksdb.rocksdb_block_based_options_create();
    defer rocksdb.rocksdb_block_based_options_destroy(block_opts);
    rocksdb.rocksdb_block_based_options_set_block_size(block_opts, config.block_size);
    rocksdb.rocksdb_options_set_block_based_table_factory(opts, block_opts);

    rocksdb.rocksdb_options_set_write_buffer_size(opts, 64 * 1024 * 1024);
    rocksdb.rocksdb_options_set_max_write_buffer_number(opts, 2);

    const db = rocksdb.rocksdb_open(opts, db_path.ptr, &err) orelse {
        if (err) |e| {
            std.debug.print("Failed to open DB: {s}\n", .{e});
            rocksdb.rocksdb_free(e);
        }
        return error.OpenFailed;
    };

    return db;
}

fn putKey(db: *rocksdb.rocksdb_t, key: []const u8, value: []const u8) !void {
    var err: [*c]u8 = null;
    const write_opts = rocksdb.rocksdb_writeoptions_create();
    defer rocksdb.rocksdb_writeoptions_destroy(write_opts);

    rocksdb.rocksdb_put(db, write_opts, key.ptr, key.len, value.ptr, value.len, &err);

    if (err) |e| {
        std.debug.print("rocksdb_put error: {s}\n", .{e});
        rocksdb.rocksdb_free(e);
        return error.WriteFailed;
    }
}

fn getDirSize(io: std.Io, path: []const u8) u64 {
    var total: u64 = 0;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            var child_buf: [std.fs.max_path_bytes]u8 = undefined;
            const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ path, entry.name }) catch continue;
            total += getDirSize(io, child_path);
        } else if (entry.kind == .file) {
            const stat = dir.statFile(io, entry.name, .{}) catch continue;
            total += stat.size;
        }
    }
    return total;
}

fn clockMs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}
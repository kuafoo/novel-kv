const std = @import("std");
const rocksdb = @import("rocksdb");

pub const Database = struct {
    db: *rocksdb.rocksdb_t,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Database {
        var err: [*c]u8 = null;

        const options = rocksdb.rocksdb_options_create();
        defer rocksdb.rocksdb_options_destroy(options);

        rocksdb.rocksdb_options_set_create_if_missing(options, 1);
        rocksdb.rocksdb_options_set_compression(options, 7);
        // Zstd dict compression: 512KB dict, level 9, 10MB training, 128KB block
        rocksdb.rocksdb_options_set_compression_options(options, 0, 9, 0, 512 * 1024);
        rocksdb.rocksdb_options_set_compression_options_zstd_max_train_bytes(options, 10_000_000);
        rocksdb.rocksdb_options_set_compression_options_use_zstd_dict_trainer(options, 1);

        const block_opts = rocksdb.rocksdb_block_based_options_create();
        defer rocksdb.rocksdb_block_based_options_destroy(block_opts);
        rocksdb.rocksdb_block_based_options_set_block_size(block_opts, 128 * 1024);
        rocksdb.rocksdb_options_set_block_based_table_factory(options, block_opts);

        const db = rocksdb.rocksdb_open(options, path.ptr, &err) orelse {
            if (err) |e| {
                std.debug.print("Failed to open database: {s}\n", .{e});
                rocksdb.rocksdb_free(e);
            }
            return error.OpenFailed;
        };

        return Database{ .db = db, .allocator = allocator };
    }

    pub fn close(self: *Database) void {
        rocksdb.rocksdb_close(self.db);
    }

    pub fn get(self: *Database, key: []const u8) ?[]const u8 {
        var err: [*c]u8 = null;
        var value_len: usize = 0;

        const read_options = rocksdb.rocksdb_readoptions_create();
        defer rocksdb.rocksdb_readoptions_destroy(read_options);

        const value = rocksdb.rocksdb_get(self.db, read_options, key.ptr, key.len, &value_len, &err);

        if (err) |e| {
            std.debug.print("rocksdb_get error: {s}\n", .{e});
            rocksdb.rocksdb_free(e);
            return null;
        }

        if (value) |v| {
            return v[0..value_len];
        }
        return null;
    }

    pub fn put(self: *Database, key: []const u8, value: []const u8) !void {
        var err: [*c]u8 = null;

        const write_options = rocksdb.rocksdb_writeoptions_create();
        defer rocksdb.rocksdb_writeoptions_destroy(write_options);

        rocksdb.rocksdb_put(self.db, write_options, key.ptr, key.len, value.ptr, value.len, &err);

        if (err) |e| {
            std.debug.print("rocksdb_put error: {s}\n", .{e});
            rocksdb.rocksdb_free(e);
            return error.WriteFailed;
        }
    }

    pub fn delete(self: *Database, key: []const u8) !void {
        var err: [*c]u8 = null;

        const write_options = rocksdb.rocksdb_writeoptions_create();
        defer rocksdb.rocksdb_writeoptions_destroy(write_options);

        rocksdb.rocksdb_delete(self.db, write_options, key.ptr, key.len, &err);

        if (err) |e| {
            std.debug.print("rocksdb_delete error: {s}\n", .{e});
            rocksdb.rocksdb_free(e);
            return error.DeleteFailed;
        }
    }

    pub fn freeValue(_: *Database, value: []const u8) void {
        rocksdb.rocksdb_free(@constCast(value.ptr));
    }
};

test "Database open put get delete" {
    const allocator = std.testing.allocator;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/novelkv_test_{d}", .{std.posix.system.getpid()});

    var db = try Database.open(allocator, path);
    defer {
        db.close();
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
    }

    try db.put("hello", "world");
    const val = db.get("hello");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("world", val.?);
    db.freeValue(val.?);

    try db.delete("hello");
    const val2 = db.get("hello");
    try std.testing.expect(val2 == null);
}

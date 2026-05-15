const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("deps/include/rocksdb/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const rocksdb_mod = translate_c.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("rocksdb", rocksdb_mod);
    exe_mod.addObjectFile(b.path("deps/lib/librocksdb.a"));
    exe_mod.addObjectFile(b.path("deps/lib/libzstd.a"));
    exe_mod.addObjectFile(b.path("deps/lib/libsnappy.a"));
    exe_mod.linkSystemLibrary("stdc++", .{});
    exe_mod.linkSystemLibrary("pthread", .{});
    exe_mod.linkSystemLibrary("dl", .{});
    exe_mod.linkSystemLibrary("rt", .{});

    const exe = b.addExecutable(.{
        .name = "novelkv",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/compress_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("rocksdb", rocksdb_mod);
    bench_mod.addObjectFile(b.path("deps/lib/librocksdb.a"));
    bench_mod.addObjectFile(b.path("deps/lib/libzstd.a"));
    bench_mod.addObjectFile(b.path("deps/lib/libsnappy.a"));
    bench_mod.linkSystemLibrary("stdc++", .{});
    bench_mod.linkSystemLibrary("pthread", .{});
    bench_mod.linkSystemLibrary("dl", .{});
    bench_mod.linkSystemLibrary("rt", .{});

    const bench_exe = b.addExecutable(.{
        .name = "compress-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }
    const bench_step = b.step("bench", "Run compression benchmark");
    bench_step.dependOn(&bench_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("rocksdb", rocksdb_mod);
    test_mod.addObjectFile(b.path("deps/lib/librocksdb.a"));
    test_mod.addObjectFile(b.path("deps/lib/libzstd.a"));
    test_mod.addObjectFile(b.path("deps/lib/libsnappy.a"));
    test_mod.linkSystemLibrary("stdc++", .{});
    test_mod.linkSystemLibrary("pthread", .{});
    test_mod.linkSystemLibrary("dl", .{});
    test_mod.linkSystemLibrary("rt", .{});

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

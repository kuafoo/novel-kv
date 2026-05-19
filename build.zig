const std = @import("std");

fn addDeps(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("deps/include/rocksdb/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const rocksdb_mod = translate_c.createModule();

    mod.addImport("rocksdb", rocksdb_mod);
    mod.addObjectFile(b.path("deps/lib/librocksdb.a"));
    mod.addObjectFile(b.path("deps/lib/libzstd.a"));
    mod.addObjectFile(b.path("deps/lib/libsnappy.a"));
    mod.linkSystemLibrary("stdc++", .{});
    mod.linkSystemLibrary("pthread", .{});
    mod.linkSystemLibrary("dl", .{});
    mod.linkSystemLibrary("rt", .{});

    const tls_dep = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("tls", tls_dep.module("tls"));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", "1.3.0");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("build_options", options.createModule());
    addDeps(b, exe_mod, target, optimize);

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

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addDeps(b, test_mod, target, optimize);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // TLS test client (only needs tls, not rocksdb)
    const tls_client_mod = b.createModule(.{
        .root_source_file = b.path("src/tls_test_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tls_dep2 = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });
    tls_client_mod.addImport("tls", tls_dep2.module("tls"));
    const tls_client = b.addExecutable(.{
        .name = "tls_test_client",
        .root_module = tls_client_mod,
    });
    b.installArtifact(tls_client);

    // TLS test server
    const tls_server_mod = b.createModule(.{
        .root_source_file = b.path("src/tls_test_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tls_dep3 = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });
    tls_server_mod.addImport("tls", tls_dep3.module("tls"));
    const tls_server = b.addExecutable(.{
        .name = "tls_test_server",
        .root_module = tls_server_mod,
    });
    b.installArtifact(tls_server);
}

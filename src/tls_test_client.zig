const std = @import("std");
const tls = @import("tls");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    _ = init.gpa;

    const host = "127.0.0.1";
    const port = 16379;

    const address = try std.Io.net.IpAddress.parse(host, port);
    var tcp = try address.connect(io, .{ .mode = .stream });
    defer tcp.close(io);

    var rng_impl: std.Random.IoSource = .{ .io = io };
    var conn = try tls.clientFromStream(io, tcp, .{
        .host = host,
        .root_ca = .empty,
        .insecure_skip_verify = true,
        .rng = rng_impl.interface(),
        .now = std.Io.Clock.real.now(io),
    });

    var buf: [4096]u8 = undefined;

    // Send PING
    try conn.writeAll("PING\r\n");
    const n1 = try conn.read(&buf);
    std.debug.print("1: {s}", .{buf[0..n1]});

    // Send SET
    try conn.writeAll("SET foo bar\r\n");
    const n2 = try conn.read(&buf);
    std.debug.print("2: {s}", .{buf[0..n2]});

    // Send GET
    try conn.writeAll("GET foo\r\n");
    const n3 = try conn.read(&buf);
    std.debug.print("3: {s}\n", .{buf[0..n3]});

    // Send DBSIZE
    try conn.writeAll("DBSIZE\r\n");
    const n4 = try conn.read(&buf);
    std.debug.print("4: {s}", .{buf[0..n4]});

    // Send DEL
    try conn.writeAll("DEL foo\r\n");
    const n5 = try conn.read(&buf);
    std.debug.print("5: {s}", .{buf[0..n5]});

    try conn.close();
    std.debug.print("All done!\n", .{});
}

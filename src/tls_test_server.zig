const std = @import("std");
const tls = @import("tls");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    _ = init.gpa;

    var rng_impl: std.Random.IoSource = .{ .io = io };
    var auth = try tls.config.CertKeyPair.fromFilePathAbsolute(
        std.heap.page_allocator, io, "/tmp/tls_test_cert.pem", "/tmp/tls_test_key.pem",
    );
    defer auth.deinit(std.heap.page_allocator);

    const port = 16400;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(io, .{ .reuse_address = true, .mode = .stream });
    defer server.deinit(io);

    std.debug.print("Test TLS server on {d}\n", .{port});

    const stream = try server.accept(io);
    defer stream.close(io);

    var conn = try tls.serverFromStream(io, stream, .{
        .auth = &auth,
        .rng = rng_impl.interface(),
        .now = std.Io.Clock.real.now(io),
    });

    // Read a line
    var buf: [4096]u8 = undefined;
    const n = try conn.read(&buf);
    std.debug.print("Received: {s}\n", .{buf[0..n]});

    // Send response
    try conn.writeAll("+PONG\r\n");
    try conn.close();
}

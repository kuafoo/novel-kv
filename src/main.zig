const std = @import("std");
const resp = @import("resp.zig");
const server = @import("server.zig");
const command = @import("command.zig");
const storage = @import("storage.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var db = try storage.Database.open(allocator, "./data");
    defer db.close();

    try server.serve(io, allocator, &db, "0.0.0.0", 6379);
}

test {
    _ = resp;
    _ = command;
    _ = storage;
}
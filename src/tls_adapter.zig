const std = @import("std");
const tls = @import("tls");
/// Bridges tls.Connection to std.Io.Reader/Writer interfaces.
/// Holds a POINTER to Connection — the Connection must outlive this struct.
/// Caller creates Connection via tls.serverFromStream/clientFromStream on their stack,
/// then wraps it. All RESP parsing code works unchanged through reader()/writer().
pub const TlsStream = struct {
    conn: *tls.Connection,
    stream: std.Io.net.Stream,

    app_read_buf: [65536]u8,
    app_reader: std.Io.Reader,
    app_write_buf: [65536]u8,
    app_writer: std.Io.Writer,

    /// Wrap an existing TLS Connection pointer.
    /// The Connection must live on the caller's stack for the entire connection lifetime.
    pub fn wrap(conn: *tls.Connection, stream: std.Io.net.Stream) TlsStream {
        return .{
            .conn = conn,
            .stream = stream,
            .app_read_buf = undefined,
            .app_reader = .{
                .vtable = &.{
                    .stream = tlsReadStream,
                    .readVec = tlsReadVec,
                },
                .buffer = undefined,
                .seek = 0,
                .end = 0,
            },
            .app_write_buf = undefined,
            .app_writer = .{
                .vtable = &.{
                    .drain = tlsWriteDrain,
                    .flush = tlsWriteFlush,
                },
                .buffer = undefined,
                .end = 0,
            },
        };
    }

    pub fn reader(self: *TlsStream) *std.Io.Reader {
        self.app_reader.buffer = &self.app_read_buf;
        return &self.app_reader;
    }

    pub fn writer(self: *TlsStream) *std.Io.Writer {
        self.app_writer.buffer = &self.app_write_buf;
        return &self.app_writer;
    }

    pub fn close(self: *TlsStream, io: std.Io) void {
        self.conn.close() catch {};
        self.stream.close(io);
    }

    // -- Reader VTable --

    fn tlsReadStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *TlsStream = @alignCast(@fieldParentPtr("app_reader", r));
        const dest = limit.slice(w.writableSliceGreedy(1) catch return 0);
        if (dest.len == 0) return 0;
        const n = self.conn.read(dest) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }

    fn tlsReadVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *TlsStream = @alignCast(@fieldParentPtr("app_reader", r));
        const first = data[0];

        if (first.len >= r.buffer.len - r.end) {
            const n = self.conn.read(first) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            return n;
        }

        const avail = r.buffer.len - r.end;
        if (avail == 0) return 0;
        const n = self.conn.read(r.buffer[r.end..]) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        r.end += n;
        return 0;
    }

    // -- Writer VTable --

    fn tlsWriteDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *TlsStream = @alignCast(@fieldParentPtr("app_writer", w));
        const buffered = w.buffered();

        if (buffered.len > 0) {
            self.conn.writeAll(buffered) catch return error.WriteFailed;
        }

        var data_bytes: usize = 0;
        if (data.len > 0) {
            for (data[0 .. data.len - 1]) |slice| {
                if (slice.len > 0) {
                    self.conn.writeAll(slice) catch return error.WriteFailed;
                    data_bytes += slice.len;
                }
            }
            const last = data[data.len - 1];
            const repeat = @max(splat, 1);
            for (0..repeat) |_| {
                if (last.len > 0) {
                    self.conn.writeAll(last) catch return error.WriteFailed;
                    data_bytes += last.len;
                }
            }
        }

        w.end = 0;
        return data_bytes;
    }

    fn tlsWriteFlush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const buffered = w.buffered();
        if (buffered.len == 0) return;
        const self: *TlsStream = @alignCast(@fieldParentPtr("app_writer", w));
        self.conn.writeAll(buffered) catch return error.WriteFailed;
        w.end = 0;
    }
};

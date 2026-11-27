const std = @import("std");
const Io = std.Io;
const net = Io.net;
const log = std.log.scoped(.ipc);

pub const Command = enum {
    toggle,
    show,
    hide,
    status,
    quit,

    pub fn parse(line: []const u8) ?Command {
        return std.meta.stringToEnum(Command, std.mem.trim(u8, line, " \t\r\n"));
    }
};

/// `$XDG_RUNTIME_DIR/pivot.sock`
pub fn socketPath(buf: []u8, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const dir = environ_map.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
    return std.fmt.bufPrint(buf, "{s}/pivot.sock", .{dir});
}

// Daemon side

pub const Server = struct {
    io: Io,
    listener: net.Server,
    path: []const u8,

    pub const InitError = error{AlreadyRunning} || net.UnixAddress.InitError ||
        net.UnixAddress.ListenError || Io.Dir.DeleteFileError;

    pub fn init(io: Io, path: []const u8) InitError!Server {
        const addr = try net.UnixAddress.init(path);

        const listener = addr.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => blk: {
                // The file exists. Either another daemon owns it, or a previous
                // one crashed and left it behind
                if (addr.connect(io)) |stream| {
                    stream.close(io);
                    return error.AlreadyRunning;
                } else |_| {}

                log.warn("removing stale socket {s}", .{path});
                try Io.Dir.deleteFileAbsolute(io, path);
                break :blk try addr.listen(io, .{});
            },
            else => return err,
        };

        return .{ .io = io, .listener = listener, .path = path };
    }

    pub fn deinit(s: *Server) void {
        s.listener.deinit(s.io);
        Io.Dir.deleteFileAbsolute(s.io, s.path) catch {};
    }

    /// The fd to hand to poll()
    pub fn fd(s: *const Server) std.posix.fd_t {
        return s.listener.socket.handle;
    }

    pub const Request = struct {
        stream: net.Stream,
        command: ?Command,
        /// Raw line, only valid until `reply` is called.
        line: []const u8,
        buf: [128]u8,

        /// Send the one-line response and close the connection.
        pub fn reply(r: *Request, io: Io, comptime fmt: []const u8, args: anytype) void {
            defer r.stream.close(io);
            var wbuf: [256]u8 = undefined;
            var w = r.stream.writer(io, &wbuf);
            w.interface.print(fmt ++ "\n", args) catch return;
            w.interface.flush() catch return;
        }
    };

    /// Accept one client and read its request line. Call when `fd()` is readable.
    pub fn accept(s: *Server, out: *Request) !void {
        const stream = try s.listener.accept(s.io);
        errdefer stream.close(s.io);

        out.stream = stream;
        var rbuf: [128]u8 = undefined;
        var r = stream.reader(s.io, &rbuf);
        // `null` means the client hung up without sending anything.
        const line = (try r.interface.takeDelimiter('\n')) orelse "";
        const n = @min(line.len, out.buf.len);
        @memcpy(out.buf[0..n], line[0..n]);
        out.line = out.buf[0..n];
        out.command = Command.parse(out.line);
    }
};

// Client side

/// Sends `command` to the running daemon and returns the reply line (without '\n').
pub fn send(io: Io, path: []const u8, command: Command, reply_buf: []u8) ![]const u8 {
    const addr = try net.UnixAddress.init(path);
    const stream = addr.connect(io) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => return error.DaemonNotRunning,
        else => return err,
    };
    defer stream.close(io);

    var wbuf: [64]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("{t}\n", .{command});
    try w.interface.flush();

    var r = stream.reader(io, reply_buf);
    return (try r.interface.takeDelimiter('\n')) orelse error.EmptyReply;
}

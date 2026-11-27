const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Io = std.Io;
const log = std.log.scoped(.daemon);

const ipc = @import("ipc.zig");
const Client = @import("client.zig").Client;

var wake_fd: posix.fd_t = -1;

fn onSignal(_: posix.SIG) callconv(.c) void {
    const one: u64 = 1;
    _ = linux.write(wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
}

const State = struct {
    visible: bool = false,
    quit: bool = false,

    fn handle(s: *State, cmd: ipc.Command) []const u8 {
        switch (cmd) {
            .toggle => s.visible = !s.visible,
            .show => s.visible = true,
            .hide => s.visible = false,
            .quit => s.quit = true,
            .status => {},
        }
        if (cmd == .quit) return "ok quitting";
        return if (s.visible) "ok visible" else "ok hidden";
    }
};

pub fn runDaemon(io: Io, path: []const u8) !void {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(rc) != .SUCCESS) return error.EventFdFailed;
    wake_fd = @intCast(rc);

    const sa: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &sa, null);
    posix.sigaction(.TERM, &sa, null);

    var client = try Client.init();
    defer client.deinit();

    var server = try ipc.Server.init(io, path);
    defer server.deinit(); // closes the listener and removes the socket file
    log.info("listening on {s}", .{path});

    var state: State = .{};

    var fds = [_]posix.pollfd{
        .{ .fd = wake_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = server.fd(), .events = posix.POLL.IN, .revents = 0 },
    };

    while (!state.quit) {
        _ = posix.poll(&fds, -1) catch |err| switch (err) {
            error.SystemResources => return err,
            else => continue,
        };

        if (fds[0].revents != 0) {
            log.info("signal received", .{});
            break;
        }

        if (fds[1].revents & posix.POLL.IN != 0) {
            var req: ipc.Server.Request = undefined;
            server.accept(&req) catch |err| {
                log.warn("dropped client: {t}", .{err});
                continue;
            };
            if (req.line.len == 0) {
                req.stream.close(io);
            } else if (req.command) |cmd| {
                const msg = state.handle(cmd);
                log.info("command: {t}", .{cmd});
                req.reply(io, "{s}", .{msg});
            } else {
                log.warn("unknown command: '{s}'", .{req.line});
                req.reply(io, "error unknown command", .{});
            }
        }
    }

    log.info("Quitting", .{});
}

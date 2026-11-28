const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.daemon);

const ipc = @import("ipc.zig");
const Client = @import("client.zig").Client;
const Panel = @import("panel.zig").Panel;
const Gfx = @import("gfx.zig").Gfx;

var wake_fd: posix.fd_t = -1;

fn onSignal(_: posix.SIG) callconv(.c) void {
    const one: u64 = 1;
    _ = linux.write(wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
}

const State = struct {
    gpa: Allocator,
    client: *Client,
    panel: ?*Panel = null,

    visible: bool = false,
    quit: bool = false,

    fn show(self: *State) bool {
        if (self.panel != null) return true;
        self.panel = Panel.create(self.gpa, self.client) catch |err| {
            log.err("could not open the panel: {t}", .{err});
            return false;
        };
        return true;
    }

    fn hide(self: *State) void {
        const panel = self.panel orelse return;
        panel.destroy();
        self.panel = null;
    }

    fn handle(self: *State, cmd: ipc.Command) []const u8 {
        const open_failed = "error could not open the surface";
        switch (cmd) {
            .toggle => if (self.panel != null) self.hide() else if (!self.show()) return open_failed,
            .show => if (!self.show()) return open_failed,
            .hide => self.hide(),
            .quit => {
                self.quit = true;
                return "ok quitting";
            },
            .status => {},
        }
        return if (self.panel != null) "ok visible" else "ok hidden";
    }

    fn hasWork(self: *const State) bool {
        const panel = self.panel orelse return false;
        return panel.closed or panel.needs_redraw;
    }
};

pub fn runDaemon(gpa: Allocator, io: Io, path: []const u8) !void {
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
    var gfx = try Gfx.init(client.display);
    defer gfx.deinit();

    var server = try ipc.Server.init(io, path);
    defer server.deinit(); // closes the listener and removes the socket file
    log.info("listening on {s}", .{path});

    var state: State = .{ .gpa = gpa, .client = &client };
    defer state.hide();

    while (!state.quit) {
        var fds = [_]posix.pollfd{
            .{ .fd = wake_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = server.fd(), .events = posix.POLL.IN, .revents = 0 },
        };

        const timeout: i32 = if (state.hasWork()) 0 else -1;
        _ = posix.poll(&fds, timeout) catch 0;

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

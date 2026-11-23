const std = @import("std");
const Io = std.Io;
const ipc = @import("ipc.zig");
const daemon = @import("daemon.zig");

const log = std.log.scoped(.main);

const usage =
    \\usage:
    \\  pivot                 start the daemon
    \\  pivot msg <command>   talk to a running daemon
    \\
    \\commands: toggle, show, hide, status, quit
    \\
;

fn print_help(io: Io) noreturn {
    var buf: [512]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    w.interface.print("{s}", .{usage}) catch {};
    w.interface.flush() catch {};
    std.process.exit(0);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var path_buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const path = ipc.socketPath(&path_buf, init.environ_map) catch
        fail("XDG_RUNTIME_DIR is not set", .{});

    // `pivot` -> start the daemon
    if (args.len == 1) {
        daemon.runDaemon(io, path) catch |err| switch (err) {
            error.AlreadyRunning => fail("pivot is already running", .{}),
            else => return err,
        };
        return;
    }

    // `pivot help`
    if (args.len == 2 and std.mem.eql(u8, args[1], "help"))
        print_help(io);

    // `pivot msg <command>`
    if (args.len == 3 and std.mem.eql(u8, args[1], "msg")) {
        const cmd = ipc.Command.parse(args[2]) orelse
            fail("unknown command '{s}'\n\n{s}", .{ args[2], usage });

        var reply_buf: [256]u8 = undefined;
        const reply = ipc.send(io, path, cmd, &reply_buf) catch |err| switch (err) {
            error.DaemonNotRunning => fail("pivot is not running", .{}),
            else => fail("ipc failed: {t}", .{err}),
        };

        var out_buf: [256]u8 = undefined;
        var out = Io.File.stdout().writer(io, &out_buf);
        try out.interface.print("{s}\n", .{reply});
        try out.interface.flush();
        if (std.mem.startsWith(u8, reply, "error")) std.process.exit(1);
        return;
    }

    fail("{s}", .{usage});
}

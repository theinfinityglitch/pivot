const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.main);

/// Set from the signal handler; checked once per loop iteration.
var quit_requested: std.atomic.Value(bool) = .init(false);

fn onSignal(_: posix.SIG) callconv(.c) void {
    quit_requested.store(true, .monotonic);
}

pub fn main() !void {
    // Ctrl+C / `kill` => clean shutdown instead of abrupt exit.
    const sa: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &sa, null);
    posix.sigaction(.TERM, &sa, null);

    while (!quit_requested.load(.monotonic)) {}
    log.info("Quitting", .{});
}

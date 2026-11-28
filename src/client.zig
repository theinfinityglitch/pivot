const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.client);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

pub const Client = struct {
    display: *wl.Display,
    compositor: *wl.Compositor,
    layer_shell: *zwlr.LayerShellV1,

    const Globals = struct {
        compositor: ?*wl.Compositor = null,
        layer_shell: ?*zwlr.LayerShellV1 = null,
    };

    pub fn init() !Client {
        const display = wl.Display.connect(null) catch {
            log.err("Could not connect to a Wayland compositor (is WAYLAND_DISPLAY set?)", .{});
            return error.NoWaylandDisplay;
        };
        errdefer display.disconnect();

        const registry = try display.getRegistry();
        var globals: Globals = .{};
        registry.setListener(*Globals, registryListener, &globals);

        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        registry.destroy();

        const compositor = globals.compositor orelse return error.NoCompositor;
        errdefer compositor.destroy();
        const layer_shell = globals.layer_shell orelse {
            log.err("the compositor does not support zwlr_layer_shell_v1 (GNOME has no layer-shell)", .{});
            return error.NoLayerShell;
        };
        log.info("zwlr_layer_shell_v1 bound at version {d}", .{layer_shell.getVersion()});

        return .{ .display = display, .compositor = compositor, .layer_shell = layer_shell };
    }

    pub fn deinit(self: *Client) void {
        _ = self.display.flush();
        self.layer_shell.destroy();
        self.compositor.destroy();
        self.display.disconnect();
    }

    pub fn fd(self: *const Client) posix.fd_t {
        return self.display.getFd();
    }

    pub fn beginWait(self: *Client) !i16 {
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }

        var events: i16 = posix.POLL.IN;
        switch (self.display.flush()) {
            .SUCCESS => {},
            .AGAIN => events |= posix.POLL.OUT,
            else => {
                self.display.cancelRead();
                return error.FlushFailed;
            },
        }
        return events;
    }

    pub fn endWait(self: *Client, revents: i16) !void {
        const readable = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;
        if (revents & readable != 0) {
            if (self.display.readEvents() != .SUCCESS) return error.ReadFailed;
        } else {
            self.display.cancelRead();
        }
        if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Client.Globals) void {
    switch (event) {
        .global => |global| {
            const iface = std.mem.span(global.interface);
            if (std.mem.eql(u8, iface, std.mem.span(wl.Compositor.interface.name))) {
                globals.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.mem.eql(u8, iface, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                // Highest version both sides understand.
                const version = @min(global.version, zwlr.LayerShellV1.generated_version);
                globals.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, version) catch return;
            }
        },
        .global_remove => {},
    }
}

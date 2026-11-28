const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.panel);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const egl = @import("egl.zig");
const gl = @import("gl");
const Client = @import("client.zig").Client;
const Gfx = @import("gfx.zig").Gfx;

pub const Panel = struct {
    gpa: Allocator,
    gfx: *Gfx,

    surface: *wl.Surface,
    layer_surface: *zwlr.LayerSurfaceV1,
    target: ?Target = null,

    configured: bool = false,
    closed: bool = false,
    needs_redraw: bool = false,
    width: u32 = 640,
    height: u32 = 360,

    const Target = struct {
        window: *wl.EglWindow,
        surface: egl.Surface,
        width: u32,
        height: u32,
    };

    pub fn create(gpa: Allocator, client: *Client, gfx: *Gfx) !*Panel {
        const panel = try gpa.create(Panel);
        errdefer gpa.destroy(panel);

        const surface = try client.compositor.createSurface();
        errdefer surface.destroy();

        const layer_surface = try client.layer_shell.getLayerSurface(surface, null, .overlay, "pivot");
        errdefer layer_surface.destroy();

        panel.* = .{ .gpa = gpa, .gfx = gfx, .surface = surface, .layer_surface = layer_surface };
        layer_surface.setListener(*Panel, layerSurfaceListener, panel);

        layer_surface.setSize(640, 360);
        layer_surface.setAnchor(.{});
        layer_surface.setExclusiveZone(-1);
        layer_surface.setKeyboardInteractivity(.on_demand);

        surface.commit();

        return panel;
    }

    pub fn destroy(self: *Panel) void {
        if (self.target) |target| {
            self.gfx.destroySurface(target.surface);
            target.window.destroy();
        }

        self.layer_surface.destroy();
        self.surface.destroy();
        self.gpa.destroy(self);
    }

    pub fn draw(self: *Panel) !void {
        self.needs_redraw = false;
        if (!self.configured) return;

        if (self.target == null) try self.createTarget();
        const target = &self.target.?;

        if (target.width != self.width or target.height != self.height) {
            target.window.resize(@intCast(self.width), @intCast(self.height), 0, 0);
            target.width = self.width;
            target.height = self.height;
        }

        gl.Viewport(0, 0, @intCast(target.width), @intCast(target.height));
        gl.ClearColor(0.074, 0.074, 0.092, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);

        try self.gfx.swap(target.surface);
    }

    fn createTarget(self: *Panel) !void {
        const window = try wl.EglWindow.create(self.surface, @intCast(self.width), @intCast(self.height));
        errdefer window.destroy();
        const surface = try self.gfx.createSurface(window);
        errdefer self.gfx.destroySurface(surface);
        try self.gfx.bind(surface);
        self.target = .{ .window = window, .surface = surface, .width = self.width, .height = self.height };
    }
};

fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, panel: *Panel) void {
    switch (event) {
        .configure => |c| {
            panel.width = if (c.width != 0) c.width else 640;
            panel.height = if (c.height != 0) c.height else 360;
            layer_surface.ackConfigure(c.serial);
            panel.configured = true;
            panel.needs_redraw = true;
        },
        .closed => panel.closed = true,
    }
}

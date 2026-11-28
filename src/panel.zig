const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.panel);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const Client = @import("client.zig").Client;

pub const Panel = struct {
    gpa: Allocator,

    surface: *wl.Surface,
    layer_surface: *zwlr.LayerSurfaceV1,

    configured: bool = false,
    closed: bool = false,
    needs_redraw: bool = false,
    width: u32 = 640,
    height: u32 = 360,

    pub fn create(gpa: Allocator, client: *Client) !*Panel {
        const panel = try gpa.create(Panel);
        defer gpa.destroy(panel);

        const surface = try client.compositor.createSurface();
        errdefer surface.destroy();

        const layer_surface = try client.layer_shell.getLayerSurface(surface, null, .overlay, "pivot");
        errdefer layer_surface.destroy();

        panel.* = .{ .gpa = gpa, .surface = surface, .layer_surface = layer_surface };
        layer_surface.setListener(Panel, layerSurfaceListener, panel);

        layer_surface.setSize(640, 360);
        layer_surface.setAnchor(.{});
        layer_surface.setExclusiveZone(-1);
        layer_surface.setKeyboardInteractivity(.on_demand);

        surface.commit();

        return panel;
    }

    fn destroy(self: *Panel) void {
        self.layer_surface.destroy();
        self.surface.destroy();
        self.gpa.destroy(self);
    }
};

fn layerSurfaceListener(layer_surface: zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, panel: *Panel) void {
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

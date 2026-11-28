const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.panel);

pub const Panel = struct {
    gpa: Allocator,

    pub fn create(gpa: Allocator) !*Panel {
        const panel = try gpa.create(Panel);
        defer gpa.destroy(panel);

        panel.* = .{ .gpa = gpa };

        return panel;
    }
};

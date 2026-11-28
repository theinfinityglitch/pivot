const std = @import("std");
const log = std.log.scoped(.gfx);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const egl = @import("egl.zig");

pub const Gfx = struct {
    display: egl.Display,
    config: egl.Config,
    context: egl.Context,

    pub fn init(wl_display: *wl.Display) !Gfx {
        const display = egl.eglGetPlatformDisplay(egl.PLATFORM_WAYLAND_KHR, wl_display, null) orelse {
            egl.logError(log, "eglGetPlatformDisplay");
            return error.NoEglDisplay;
        };

        var major: egl.Int = 0;
        var minor: egl.Int = 0;
        if (egl.eglInitialize(display, &major, &minor) != egl.TRUE) {
            egl.logError(log, "eglInitialize");
            return error.EglInitFailed;
        }
        errdefer _ = egl.eglTerminate(display);
        log.info("EGL {d}.{d} ({s})", .{ major, minor, std.mem.span(egl.eglQueryString(display, egl.VENDOR) orelse "?") });

        if (egl.eglBindAPI(egl.OPENGL_API) != egl.TRUE) {
            egl.logError(log, "eglBindAPI");
            return error.BindApiFailed;
        }

        const config_attribs = [_]egl.Int{
            egl.SURFACE_TYPE,    egl.WINDOW_BIT,
            egl.RENDERABLE_TYPE, egl.OPENGL_BIT,
            egl.RED_SIZE,        8,
            egl.GREEN_SIZE,      8,
            egl.BLUE_SIZE,       8,
            egl.ALPHA_SIZE,      8,
            egl.NONE,
        };
        var config: egl.Config = undefined;
        var num_configs: egl.Int = 0;
        if (egl.eglChooseConfig(display, &config_attribs, @ptrCast(&config), 1, &num_configs) != egl.TRUE or num_configs < 1) {
            egl.logError(log, "eglChooseConfig");
            return error.NoSuitableConfig;
        }

        const context_attribs = [_]egl.Int{
            egl.CONTEXT_MAJOR_VERSION,       3,
            egl.CONTEXT_MINOR_VERSION,       3,
            egl.CONTEXT_OPENGL_PROFILE_MASK, egl.CONTEXT_OPENGL_CORE_PROFILE_BIT,
            egl.NONE,
        };
        const context = egl.eglCreateContext(display, config, null, &context_attribs) orelse {
            egl.logError(log, "eglCreateContext");
            return error.ContextCreationFailed;
        };

        return .{ .display = display, .config = config, .context = context };
    }

    pub fn deinit(self: *Gfx) void {
        _ = egl.eglMakeCurrent(self.display, null, null, null);
        _ = egl.eglDestroyContext(self.display, self.context);
        _ = egl.eglTerminate(self.display);
        _ = egl.eglReleaseThread();
    }
};

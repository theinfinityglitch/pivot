const std = @import("std");
const log = std.log.scoped(.gfx);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const egl = @import("egl.zig");
const gl = @import("gl");

var gl_procs: gl.ProcTable = undefined;
var gl_loaded = false;

fn getProcAddress(name: [*:0]const u8) ?gl.PROC {
    return @ptrCast(@alignCast(egl.eglGetProcAddress(name)));
}

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

    pub fn createSurface(self: *Gfx, window: *wl.EglWindow) !egl.Surface {
        return egl.eglCreatePlatformWindowSurface(self.display, self.config, window, null) orelse {
            egl.logError(log, "eglCreatePlatformWindowSurface");
            return error.SurfaceCreationFailed;
        };
    }

    pub fn destroySurface(self: *Gfx, surface: egl.Surface) void {
        _ = egl.eglMakeCurrent(self.display, null, null, null);
        _ = egl.eglDestroySurface(self.display, surface);
    }

    pub fn bind(self: *Gfx, surface: egl.Surface) !void {
        if (egl.eglMakeCurrent(self.display, surface, surface, self.context) != egl.TRUE) {
            egl.logError(log, "eglMakeCurrent");
            return error.MakeCurrentFailed;
        }

        if (egl.eglSwapInterval(self.display, 0) != egl.TRUE) egl.logError(log, "eglSwapInterval");

        if (!gl_loaded) {
            if (!gl_procs.init(getProcAddress)) return error.GlLoadFailed;
            gl.makeProcTableCurrent(&gl_procs);
            gl_loaded = true;
            log.info("GL_RENDERER: {s}", .{glString(gl.RENDERER)});
            log.info("GL_VERSION:  {s}", .{glString(gl.VERSION)});
        }
    }

    pub fn swap(self: *Gfx, surface: egl.Surface) !void {
        if (egl.eglSwapBuffers(self.display, surface) != egl.TRUE) {
            egl.logError(log, "eglSwapBuffers");
            return error.SwapFailed;
        }
    }
};

fn glString(name: gl.@"enum") []const u8 {
    const s = gl.GetString(name) orelse return "?";
    return std.mem.span(s);
}

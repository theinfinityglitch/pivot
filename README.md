<h1 align="center">Pivot</h1>
<h4 align="center">A small but powerful launcher with a Lua runtime</h4>

**Pivot** is a lightweight focussed launcher for wayland (x11 not planned for now) desktops. On it's simplest form excluding the default plugins, it's just a layer shell client that handles input focus and a LuaJIT runtime.

Being fully customizable using CSS and custom plugins, this is a ultimate build your own launcher (not comparing to custom built launchers or something like that T-T). Also, I use to see it as a Swiss Army Knife due to it's nature of being extremely extensible and multi-use.

# Planned features

- Single binary that acts as the launcher and messenger
- Background runtime that manages the LuaJIT runtimes for the plugins
- Toggleable launcher window. Can be toggled to any plugin view
- Reactive interface system based on Lua
- Fully customizable interface look via CSS
- Lazy loading plugins

# Roadmap (0.1.0)

- [x] Project setup: Clear exit setup + basic app loop
- [ ] Message handling via IPC
- [ ] Make a binding for EGL
- [ ] Open a basic layer shell client and clear it with OpenGL
- [ ] Scan for the Lua config entry file (config.lua)
- [ ] Start a LuaJIT VM for the config
- [ ] Implement a interface framework
- [ ] Integrate the Lua API

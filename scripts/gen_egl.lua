#!/usr/bin/env lua
--[[
gen_egl.lua - generate a single-file Zig (0.17.0) EGL binding from Khronos' egl.xml

Usage:
    lua gen_egl.lua egl.xml [out.zig]        (writes to stdout when out.zig is omitted)

Pure Lua, no dependencies; runs on Lua 5.1 - 5.4 and LuaJIT.

What is generated
-----------------
  * Types       EGLint -> Int, EGLDisplay -> Display, ... (the `EGL` prefix is dropped
                and the first letter capitalised, as in a hand written binding).
                Handles are distinct opaque pointers so a Display can't be passed where a
                Surface is expected. `FooKHR`/`FooNV` handles alias `Foo`, so the KHR and
                core entry points stay interchangeable.
  * Constants   EGL_ALPHA_SIZE -> ALPHA_SIZE. Plain numbers are untyped (comptime_int), so
                they coerce to whichever of Int / Enum / Boolean an API expects.
                EGL_TRUE/FALSE are `Boolean`, EGL_NO_* are typed `null`s.
  * Functions   Core EGL 1.0 - 1.5 entry points are `pub extern fn` (link libEGL).
                Extension-only entry points get a `PFN...PROC` type and a slot in
                `ProcTable`, which loads them through eglGetProcAddress.
  * Helpers     errorName() / logError() built from the registry's error codes.

Only what `<feature api="egl">` and `<extension supported="egl">` actually `<require>`
is emitted (same rule as Khronos' own header generator), so unreleased/placeholder
tokens in the registry are skipped.

The tables just below are the only hand-maintained knowledge: the registry has no
nullability / array information, so it lives here.
]]

local unpack = table.unpack or unpack

------------------------------------------------------------------------------
-- Configuration tables
------------------------------------------------------------------------------

-- C scalar types -> Zig
local C_SCALARS = {
    ["int"] = "i32",
    ["unsigned int"] = "u32",
    ["intptr_t"] = "isize",
    ["uintptr_t"] = "usize",
    ["khronos_int32_t"] = "i32",
    ["khronos_uint32_t"] = "u32",
    ["khronos_int64_t"] = "i64",
    ["khronos_uint64_t"] = "u64",
    ["khronos_ssize_t"] = "isize",
    ["khronos_utime_nanoseconds_t"] = "u64",
    ["khronos_stime_nanoseconds_t"] = "i64",
}

-- Types that the registry only declares via the platform header (<EGL/eglplatform.h>).
-- `kind = "native"` means the Zig type already contains its own nullability.
local PLATFORM_TYPES = {
    EGLint = { kind = "scalar", def = "i32" },
    EGLNativeDisplayType = { kind = "native", def = "?*anyopaque" },
    -- X11 Pixmap/Window are `unsigned long`, wayland/android ones are pointers; every
    -- one of them is pointer sized, so an integer of that size is ABI compatible.
    EGLNativePixmapType = { kind = "scalar", def = "usize" },
    EGLNativeWindowType = { kind = "scalar", def = "usize" },
}

-- `typedef void *X` types that are *not* distinct handles but "any pointer-ish thing"
-- (they're routinely filled with integers cast to pointers, application labels, ...).
local RAW_VOID_TYPEDEFS = {
    EGLClientBuffer = true,
    EGLLabelKHR = true,
    EGLObjectKHR = true,
}

-- Vendor suffixes: `EGLImageKHR` becomes an alias of `EGLImage` when the latter exists.
local HANDLE_ALIAS_SUFFIXES = { "KHR", "NV", "EXT" }

-- Explicit Zig names for C typedefs that would otherwise get an ugly name.
local TYPE_RENAMES = {
    __eglMustCastToProperFunctionPointerType = "FunctionPointer",
}

-- Handle parameters that may legitimately be EGL_NO_* (null). Everything else is
-- non-optional. "*" applies to every command. Handle *return values* are always optional.
local NULLABLE_PARAMS = {
    ["*"] = { share_context = true },
    eglMakeCurrent = { draw = true, read = true, ctx = true },
    eglQueryString = { dpy = true },
    eglCreateImage = { ctx = true },
    eglCreateImageKHR = { ctx = true },
    eglLabelObjectKHR = { dpy = true },
}

-- Pointer parameters that point at ONE object (out-parameters). Every other pointer
-- becomes a many-item pointer, which still accepts `&x` and `&array`, so a missing entry
-- here is harmless.
local SINGLE_PARAMS = {
    major = true, minor = true, numerator = true, denominator = true,
    name = true, handle = true, stride = true, fourcc = true, frameId = true,
    display_id = true, pixmap = true, window = true, pImage = true,
    event = true, aux = true, size = true,
}
-- Single-item out-parameters that must not be null.
local function is_required_single(name)
    return name == "value" or name:match("^num_") ~= nil
end
local function is_single(name)
    return SINGLE_PARAMS[name] or is_required_single(name)
end

local ZIG_KEYWORDS = {}
for w in ([[addrspace align allowzero and anyframe anytype asm async await break callconv
catch comptime const continue defer else enum errdefer error export extern fn for if inline
linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct
suspend switch test threadlocal try union unreachable usingnamespace var volatile while]]):gmatch("%S+") do
    ZIG_KEYWORDS[w] = true
end

------------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------------

local function die(fmt, ...)
    io.stderr:write("gen_egl: error: ", string.format(fmt, ...), "\n")
    os.exit(1)
end

local function warn(fmt, ...)
    io.stderr:write("gen_egl: warning: ", string.format(fmt, ...), "\n")
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then die("cannot open %s: %s", path, tostring(err)) end
    local s = f:read("*a")
    f:close()
    return s
end

local function zig_ident(name)
    if ZIG_KEYWORDS[name] or name:match("^[^%a_]") or name:match("[^%w_]") then
        return '@"' .. name .. '"'
    end
    return name
end

------------------------------------------------------------------------------
-- Minimal XML parser (elements, attributes, text, comments, entities)
------------------------------------------------------------------------------

local function utf8_char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(192 + math.floor(cp / 64), 128 + cp % 64)
    elseif cp < 0x10000 then
        return string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
    end
    return string.char(240 + math.floor(cp / 262144), 128 + math.floor(cp / 4096) % 64,
        128 + math.floor(cp / 64) % 64, 128 + cp % 64)
end

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function decode_entities(s)
    if not s:find("&", 1, true) then return s end
    return (s:gsub("&(#?%w+);", function(e)
        if e:sub(1, 1) == "#" then
            local n
            if e:sub(2, 2) == "x" or e:sub(2, 2) == "X" then n = tonumber(e:sub(3), 16) else n = tonumber(e:sub(2)) end
            return n and utf8_char(n) or nil
        end
        return ENTITIES[e]
    end))
end

-- Returns a tree of { tag=, attrs={}, children={ node | string, ... } }
local function parse_xml(s)
    local root = { tag = "#document", attrs = {}, children = {} }
    local stack, top = { root }, root
    local pos = 1
    while true do
        local lt = s:find("<", pos, true)
        if not lt then break end
        if lt > pos then
            top.children[#top.children + 1] = decode_entities(s:sub(pos, lt - 1))
        end
        if s:sub(lt, lt + 3) == "<!--" then
            local e = s:find("-->", lt + 4, true) or die("unterminated comment")
            pos = e + 3
        elseif s:sub(lt, lt + 8) == "<![CDATA[" then
            local e = s:find("]]>", lt + 9, true) or die("unterminated CDATA")
            top.children[#top.children + 1] = s:sub(lt + 9, e - 1)
            pos = e + 3
        elseif s:sub(lt, lt + 1) == "<?" or s:sub(lt, lt + 1) == "<!" then
            local e = s:find(">", lt, true) or die("unterminated declaration")
            pos = e + 1
        elseif s:sub(lt, lt + 1) == "</" then
            local gt = s:find(">", lt, true) or die("unterminated end tag")
            local name = s:sub(lt + 2, gt - 1):match("^%s*(%S+)")
            if name ~= top.tag then die("mismatched </%s>, expected </%s>", tostring(name), top.tag) end
            stack[#stack] = nil
            top = stack[#stack]
            pos = gt + 1
        else
            local name, p = s:match("^<([^%s/>]+)()", lt)
            if not name then die("malformed tag near byte %d", lt) end
            local node = { tag = name, attrs = {}, children = {} }
            while true do
                p = s:find("%S", p) or die("unterminated tag <%s>", name)
                if s:sub(p, p + 1) == "/>" then
                    top.children[#top.children + 1] = node
                    pos = p + 2
                    break
                elseif s:sub(p, p) == ">" then
                    top.children[#top.children + 1] = node
                    stack[#stack + 1] = node
                    top = node
                    pos = p + 1
                    break
                end
                local k, _, v, np = s:match("^([^%s=]+)%s*=%s*([\"'])(.-)%2()", p)
                if not k then die("malformed attribute in <%s> near byte %d", name, p) end
                node.attrs[k] = decode_entities(v)
                p = np
            end
        end
    end
    if top ~= root then die("unclosed <%s>", top.tag) end
    return root
end

local function node_text(n)
    if type(n) == "string" then return n end
    local t = {}
    for _, c in ipairs(n.children) do t[#t + 1] = node_text(c) end
    return table.concat(t)
end

local function each(n, tag)
    local i = 0
    return function()
        while true do
            i = i + 1
            local c = n.children[i]
            if c == nil then return nil end
            if type(c) == "table" and (tag == nil or c.tag == tag) then return c end
        end
    end
end

local function first(n, tag)
    for c in each(n, tag) do return c end
end

-- <proto>/<param>: text pieces and <ptype> make up the C type, <name> is the identifier.
local function parse_decl(node)
    local parts, name = {}, nil
    for _, c in ipairs(node.children) do
        if type(c) == "string" then
            parts[#parts + 1] = c
        elseif c.tag == "name" then
            name = trim(node_text(c))
        else
            parts[#parts + 1] = node_text(c)
        end
    end
    return trim(table.concat(parts, " ")), name
end

------------------------------------------------------------------------------
-- C type string parsing:  "const EGLint *"  ->  { base="EGLint", nptr=1, const=true }
------------------------------------------------------------------------------

local function parse_ctype(s)
    local t = { base = nil, nptr = 0, const = false, struct = false }
    local words = {}
    for w in s:gsub("%*", " * "):gmatch("%S+") do
        if w == "const" then t.const = true
        elseif w == "volatile" then -- ignored
        elseif w == "struct" then t.struct = true
        elseif w == "*" then t.nptr = t.nptr + 1
        else words[#words + 1] = w end
    end
    t.base = table.concat(words, " ")
    if t.base == "" then die("cannot parse C type '%s'", s) end
    return t
end

-- "type name" with the name being the last identifier ("const char* message")
local function split_c_declarator(s)
    local ty, nm = s:match("^%s*(.-)([%w_]+)%s*$")
    if not ty or trim(ty) == "" then die("cannot parse declarator '%s'", s) end
    return trim(ty), nm
end

------------------------------------------------------------------------------
-- Load the registry
------------------------------------------------------------------------------

local xml_path, out_path = arg and arg[1], arg and arg[2]
if not xml_path or xml_path == "-h" or xml_path == "--help" then
    io.stderr:write("usage: lua gen_egl.lua egl.xml [out.zig]\n")
    os.exit(xml_path and 0 or 1)
end

local xml_src = read_file(xml_path)
local doc = parse_xml(xml_src)
local registry = first(doc, "registry") or die("no <registry> element in %s", xml_path)

-- License banner (first Copyright / SPDX lines of the registry's leading comment)
local license_lines = {}
do
    local c = xml_src:match("Copyright[^\n]*")
    local spdx = xml_src:match("SPDX%-License%-Identifier:[^\n]*")
    if c then license_lines[#license_lines + 1] = trim(c) end
    if spdx then license_lines[#license_lines + 1] = trim(spdx) end
end

------------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------------

local types = {}      -- C name -> info
local type_order = {} -- C names in registry order

local function zig_type_name(cname)
    if TYPE_RENAMES[cname] then return TYPE_RENAMES[cname] end
    local n = cname
    if n:sub(1, 5) == "__egl" then
        n = n:sub(6)
    elseif n:sub(1, 3) == "EGL" and #n > 3 then
        n = n:sub(4)
    end
    return n:sub(1, 1):upper() .. n:sub(2)
end

local function add_type(cname, info)
    if types[cname] then return end
    info.cname = cname
    if info.kind ~= "foreign" then info.zig = zig_type_name(cname) end
    types[cname] = info
    type_order[#type_order + 1] = cname
end

for tsec in each(registry, "types") do
    for t in each(tsec, "type") do
        local attr_name = t.attrs.name
        local text = trim(node_text(t))
        if attr_name then
            local p = PLATFORM_TYPES[attr_name]
            if p then add_type(attr_name, { kind = p.kind, def = p.def }) end
        elseif text:sub(1, 1) == "#" then
            -- #include / #define: preprocessor noise, nothing to bind
        else
            local hname = text:match("^typedef%s+void%s*%*%s*([%w_]+)%s*;$")
            local ret, fname, fparams = text:match("^typedef%s+(.-)%(%s*%*%s*([%w_]+)%s*%)%s*%((.*)%)%s*;$")
            local sbase, sname = text:match("^typedef%s+(.-)%s+([%w_]+)%s*;$")
            local fwd = text:match("^struct%s+([%w_]+)%s*;$")
            local stname, stbody = text:match("^struct%s+([%w_]+)%s*(%b{})%s*;$")
            if hname then
                if RAW_VOID_TYPEDEFS[hname] then
                    add_type(hname, { kind = "raw", def = "?*const anyopaque" })
                else
                    add_type(hname, { kind = "handle" })
                end
            elseif fname then
                add_type(fname, { kind = "callback", ret = trim(ret), params = fparams })
            elseif sname and not sbase:find("[%*%(]") then
                local def = C_SCALARS[trim(sbase)] or die("typedef '%s': unknown scalar base '%s'", sname, sbase)
                add_type(sname, { kind = "scalar", def = def })
            elseif fwd then
                add_type(fwd, { kind = "foreign" })
            elseif stname then
                add_type(stname, { kind = "struct", body = stbody:sub(2, -2) })
            end
        end
    end
end

-- Resolve `EGLImageKHR` -> alias of `EGLImage`, etc.
for _, cname in ipairs(type_order) do
    local t = types[cname]
    if t.kind == "handle" then
        for _, suf in ipairs(HANDLE_ALIAS_SUFFIXES) do
            if cname:sub(-#suf) == suf then
                local base = types[cname:sub(1, -#suf - 1)]
                if base and base.kind == "handle" then
                    t.alias_of = base.zig
                    break
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- Enums
------------------------------------------------------------------------------

local enums = {}
for sec in each(registry, "enums") do
    for e in each(sec, "enum") do
        local name = e.attrs.name
        if name then
            if enums[name] then
                if enums[name].value ~= e.attrs.value then
                    warn("enum %s defined twice with different values; keeping the first", name)
                end
            else
                enums[name] = {
                    name = name,
                    value = e.attrs.value,
                    alias = e.attrs.alias,
                    type = e.attrs.type,
                    group = sec.attrs.group,
                }
            end
        end
    end
end

------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------

local commands = {}
for sec in each(registry, "commands") do
    for c in each(sec, "command") do
        local proto = first(c, "proto") or die("<command> without <proto>")
        local ret, name = parse_decl(proto)
        local params = {}
        for p in each(c, "param") do
            local ct, pn = parse_decl(p)
            params[#params + 1] = { ctype = ct, name = pn }
        end
        commands[name] = { name = name, ret = ret, params = params }
    end
end

------------------------------------------------------------------------------
-- Features / extensions: decide what is actually emitted
------------------------------------------------------------------------------

local sections = {} -- { name=, core=bool, enums={...}, commands={...} }

local function supports_egl(attr)
    if not attr then return true end
    for api in attr:gmatch("[^|,]+") do
        if api == "egl" then return true end
    end
    return false
end

local function collect(node, core)
    local sec = { name = node.attrs.name, core = core, enums = {}, commands = {} }
    for req in each(node, "require") do
        for item in each(req) do
            if item.tag == "enum" then
                sec.enums[#sec.enums + 1] = item.attrs.name
            elseif item.tag == "command" then
                sec.commands[#sec.commands + 1] = item.attrs.name
            end
        end
    end
    if first(node, "remove") then warn("%s has <remove> blocks, which are ignored", sec.name) end
    return sec
end

local core_version = "1.0"
for f in each(registry, "feature") do
    if f.attrs.api == "egl" then
        sections[#sections + 1] = collect(f, true)
        core_version = f.attrs.number or core_version
    end
end
for ext_sec in each(registry, "extensions") do
    for x in each(ext_sec, "extension") do
        if supports_egl(x.attrs.supported) then
            sections[#sections + 1] = collect(x, false)
        end
    end
end

-- Dedup: first section that requires something owns it. Features come first, so a
-- command in both EGL 1.5 and an extension is treated as core.
local seen_enum, seen_cmd = {}, {}
for _, sec in ipairs(sections) do
    local es, cs = {}, {}
    for _, n in ipairs(sec.enums) do
        if not seen_enum[n] then
            if enums[n] then
                seen_enum[n] = true
                es[#es + 1] = n
            else
                warn("%s requires unknown enum %s", sec.name, n)
            end
        end
    end
    for _, n in ipairs(sec.commands) do
        if not seen_cmd[n] then
            if commands[n] then
                seen_cmd[n] = true
                cs[#cs + 1] = n
            else
                warn("%s requires unknown command %s", sec.name, n)
            end
        end
    end
    sec.enums, sec.commands = es, cs
end

------------------------------------------------------------------------------
-- Zig type mapping
------------------------------------------------------------------------------

local function base_info(ct)
    local b = ct.base
    if b == "void" then return { kind = "void", zig = "anyopaque" } end
    if b == "char" then return { kind = "char", zig = "u8" } end
    if C_SCALARS[b] then return { kind = "scalar", zig = C_SCALARS[b] } end
    local t = types[b]
    if t then return t end
    if ct.struct then return { kind = "foreign", zig = "anyopaque" } end
    die("unknown C type '%s'", b)
end

local function is_nullable(cmd, pname)
    local per = NULLABLE_PARAMS[cmd]
    return (per and per[pname]) or NULLABLE_PARAMS["*"][pname] or false
end

-- role: "param" | "ret" | "field"
local function ztype(ct, role, pname, cmd)
    local info = base_info(ct)

    if ct.nptr == 0 then
        local k = info.kind
        if k == "void" then return "void" end
        if k == "foreign" then die("foreign struct '%s' used by value", ct.base) end
        if k == "handle" then
            local opt = role == "ret" or is_nullable(cmd, pname)
            return (opt and "?" or "") .. info.zig
        elseif k == "callback" then
            return "?" .. info.zig
        end
        return info.zig
    end

    -- pointers --------------------------------------------------------------
    if info.kind == "void" or info.kind == "foreign" then
        local z = ct.const and "?*const anyopaque" or "?*anyopaque"
        if ct.nptr >= 2 then
            z = "?*" .. z
        end
        return z
    end
    if info.kind == "char" and ct.nptr == 1 then
        -- strings: only return values may be null
        local opt = role == "ret" and "?" or ""
        return opt .. (ct.const and "[*:0]const u8" or "[*:0]u8")
    end
    local c = ct.const and "const " or ""
    if info.kind == "struct" then return "?*" .. c .. info.zig end
    if ct.nptr > 1 then die("unsupported pointer depth for '%s'", ct.base) end

    if role == "param" and pname and not is_single(pname) then
        return "?[*]" .. c .. info.zig
    end
    if role == "param" and pname and is_required_single(pname) then
        return "*" .. c .. info.zig
    end
    return "?*" .. c .. info.zig
end

local function zig_param_list(params, role, cmd)
    local out = {}
    for _, p in ipairs(params) do
        out[#out + 1] = string.format("%s: %s", zig_ident(p.name), ztype(parse_ctype(p.ctype), role, p.name, cmd))
    end
    return table.concat(out, ", ")
end

local function callback_signature(t)
    local params = {}
    local ptext = trim(t.params)
    if ptext ~= "" and ptext ~= "void" then
        for piece in (ptext .. ","):gmatch("([^,]*),") do
            local ty, nm = split_c_declarator(piece)
            params[#params + 1] = { ctype = ty, name = nm }
        end
    end
    local ret = ztype(parse_ctype(t.ret), "ret")
    return string.format("fn (%s) callconv(.c) %s", zig_param_list(params, "cbparam", nil), ret)
end

------------------------------------------------------------------------------
-- Emit
------------------------------------------------------------------------------

local out = {}
local function emit(s) out[#out + 1] = s end

local declared = {} -- top-level Zig names, to catch collisions early
local function declare(name, what)
    if declared[name] then die("name collision on '%s' (%s vs %s)", name, declared[name], what) end
    declared[name] = what
end

local n_types, n_consts, n_core, n_ext = 0, 0, 0, 0

-- header ---------------------------------------------------------------------
emit("//! EGL " .. core_version .. " bindings (core + all registered extensions) for Zig.")
emit("//!")
emit("//! GENERATED by gen_egl.lua from the Khronos EGL registry (egl.xml). DO NOT EDIT BY HAND;")
emit("//! change the generator and re-run it instead.")
emit("//!")
for _, l in ipairs(license_lines) do emit("//! " .. l) end
if #license_lines > 0 then emit("//!") end
emit("//! Layout:")
emit("//!   * `Int`, `Enum`, handle types ...  `EGL` prefix dropped, first letter upper-cased.")
emit("//!   * `ALPHA_SIZE`, `NONE`, ...        `EGL_` prefix dropped. Numbers are untyped, so")
emit("//!                                      they coerce to Int / Enum / Boolean as needed.")
emit("//!   * `eglFoo`                         core entry points: `extern fn`, link libEGL.")
emit("//!   * `ProcTable`                      extension entry points, loaded with")
emit("//!                                      eglGetProcAddress (`PFNEGLFOOPROC` types).")
emit("const std = @import(\"std\");")
emit("")

-- types ----------------------------------------------------------------------
emit("// ── Types ───────────────────────────────────────────────────────────────────")
for _, cname in ipairs(type_order) do
    local t = types[cname]
    if t.kind ~= "foreign" then
        declare(t.zig, "type " .. cname)
        n_types = n_types + 1
        if t.kind == "scalar" or t.kind == "native" or t.kind == "raw" then
            emit(string.format("pub const %s = %s;", t.zig, t.def))
        elseif t.kind == "handle" then
            if t.alias_of then
                emit(string.format("pub const %s = %s;", t.zig, t.alias_of))
            else
                emit(string.format("pub const %s = *const opaque {};", t.zig))
            end
        elseif t.kind == "callback" then
            emit(string.format("pub const %s = *const %s;", t.zig, callback_signature(t)))
        elseif t.kind == "struct" then
            emit(string.format("pub const %s = extern struct {", t.zig))
            for member in t.body:gmatch("([^;]+);") do
                local ty, nm = split_c_declarator(member)
                emit(string.format("    %s: %s,", zig_ident(nm), ztype(parse_ctype(ty), "field", nm)))
            end
            emit("};")
        end
    end
end
emit("")

-- constants ------------------------------------------------------------------
local function const_name(cname)
    return zig_ident((cname:gsub("^EGL_", "")))
end

local function norm_number(v)
    v = trim(v)
    if v:match("^%-?0[xX]%x+$") then
        return (v:gsub("0[xX]", "0x"))
    elseif v:match("^%-?%d+$") then
        local sign, digits = v:match("^(%-?)(%d+)$")
        digits = digits:gsub("^0+(%d)", "%1")
        return sign .. digits
    end
end

local emitted_enum = {}
-- Returns the Zig declaration RHS (with optional ": Type")
local function render_enum(e)
    if e.alias and seen_enum[e.alias] then
        return "", const_name(e.alias)
    end
    local cast_t, cast_v = e.value:match("^EGL_CAST%(([%w_]+)%s*,%s*(.-)%)$")
    if cast_t then
        local t = types[cast_t] or die("enum %s: EGL_CAST to unknown type %s", e.name, cast_t)
        local v = norm_number(cast_v) or die("enum %s: bad cast value '%s'", e.name, cast_v)
        if v == "0" and (t.kind == "handle" or t.kind == "raw" or t.kind == "native") then
            return ": " .. (t.kind == "handle" and "?" or "") .. t.zig, "null"
        end
        return ": " .. t.zig, v
    end
    local v = norm_number(e.value) or die("enum %s: unsupported value '%s'", e.name, e.value)
    if e.type == "ull" then return ": u64", v end
    if e.type then die("enum %s: unsupported type '%s'", e.name, e.type) end
    if e.group == "Boolean" then return ": " .. (types.EGLBoolean and types.EGLBoolean.zig or "u32"), v end
    return "", v
end

emit("// ── Constants ───────────────────────────────────────────────────────────────")
for _, sec in ipairs(sections) do
    if #sec.enums > 0 then
        emit("")
        emit("// " .. sec.name)
        for _, n in ipairs(sec.enums) do
            local e = enums[n]
            local zn = const_name(n)
            declare(zn, "enum " .. n)
            local ann, rhs = render_enum(e)
            emit(string.format("pub const %s%s = %s;", zn, ann, rhs))
            emitted_enum[#emitted_enum + 1] = e
            n_consts = n_consts + 1
        end
    end
end
emit("")

-- core functions ---------------------------------------------------------------
local function fn_sig(c)
    local params = zig_param_list(c.params, "param", c.name)
    local ret = ztype(parse_ctype(c.ret), "ret", nil, c.name)
    return params, ret
end

emit("// ── Functions (core, linked from libEGL) ────────────────────────────────────")
for _, sec in ipairs(sections) do
    if sec.core and #sec.commands > 0 then
        emit("")
        emit("// " .. sec.name)
        for _, n in ipairs(sec.commands) do
            local params, ret = fn_sig(commands[n])
            declare(n, "function " .. n)
            emit(string.format("pub extern fn %s(%s) %s;", n, params, ret))
            n_core = n_core + 1
        end
    end
end
emit("")

-- extension functions ----------------------------------------------------------
local ext_cmds = {} -- { {cmd=, ext=}, ... }
local ext_pfn_emitted = false
for _, sec in ipairs(sections) do
    if not sec.core then
        for _, n in ipairs(sec.commands) do
            ext_cmds[#ext_cmds + 1] = { cmd = commands[n], ext = sec.name }
        end
    end
end

local has_get_proc = seen_cmd["eglGetProcAddress"] == true
if #ext_cmds > 0 and not has_get_proc then
    warn("eglGetProcAddress is not part of the selected API; skipping extension loader")
    ext_cmds = {}
end

if #ext_cmds > 0 then
    emit("// ── Extension function pointer types ────────────────────────────────────────")
    local last
    for _, x in ipairs(ext_cmds) do
        if x.ext ~= last then
            emit("")
            emit("// " .. x.ext)
            last = x.ext
        end
        local params, ret = fn_sig(x.cmd)
        local pfn = "PFN" .. x.cmd.name:upper() .. "PROC"
        declare(pfn, "pfn " .. x.cmd.name)
        emit(string.format("pub const %s = *const fn (%s) callconv(.c) %s;", pfn, params, ret))
        n_ext = n_ext + 1
    end
    emit("")

    emit("// ── Extension loader ────────────────────────────────────────────────────────")
    emit("")
    emit("/// Looks up one entry point through `eglGetProcAddress` and casts it to `T`.")
    emit("pub fn getProc(comptime T: type, name: [*:0]const u8) ?T {")
    emit("    const p = eglGetProcAddress(name) orelse return null;")
    emit("    return @ptrCast(p);")
    emit("}")
    emit("")
    emit("/// One optional function pointer per extension entry point. A slot stays `null`")
    emit("/// when the driver doesn't provide it, so check it (and the extension string from")
    emit("/// `eglQueryString`) before calling. Call `load()` once EGL is usable; per the")
    emit("/// spec some entry points are only valid for displays exposing the extension.")
    declare("ProcTable", "ProcTable")
    emit("pub const ProcTable = struct {")
    last = nil
    for _, x in ipairs(ext_cmds) do
        if x.ext ~= last then
            if last then emit("") end
            emit("    // " .. x.ext)
            last = x.ext
        end
        emit(string.format("    %s: ?PFN%sPROC = null,", x.cmd.name, x.cmd.name:upper()))
    end
    emit("")
    emit("    pub fn init() ProcTable {")
    emit("        var t: ProcTable = .{};")
    emit("        t.load();")
    emit("        return t;")
    emit("    }")
    emit("")
    emit("    pub fn load(self: *ProcTable) void {")
    for _, x in ipairs(ext_cmds) do
        emit(string.format("        self.%s = getProc(PFN%sPROC, \"%s\");", x.cmd.name, x.cmd.name:upper(), x.cmd.name))
    end
    emit("    }")
    emit("};")
    emit("")
end

-- helpers -----------------------------------------------------------------------
emit("// ── Helpers ─────────────────────────────────────────────────────────────────")
emit("")

-- Error codes: SUCCESS, NOT_INITIALIZED, CONTEXT_LOST, BAD_*; one prong per value,
-- preferring the shortest (i.e. un-suffixed core) name.
local by_value, error_values = {}, {}
for _, e in ipairs(emitted_enum) do
    local n = e.name
    if n == "EGL_SUCCESS" or n == "EGL_NOT_INITIALIZED" or n == "EGL_CONTEXT_LOST" or n:match("^EGL_BAD_") then
        local v = tonumber(norm_number(e.value) or "")
        if v then
            local cur = by_value[v]
            if not cur then
                by_value[v] = e
                error_values[#error_values + 1] = v
            elseif #n < #cur.name then
                by_value[v] = e
            end
        end
    end
end
table.sort(error_values)

if #error_values > 0 and types.EGLint then
    local int_t = types.EGLint.zig
    declare("errorName", "helper")
    emit("/// Human-readable name for an `eglGetError()` code.")
    emit(string.format("pub fn errorName(code: %s) []const u8 {", int_t))
    emit("    return switch (code) {")
    for _, v in ipairs(error_values) do
        local e = by_value[v]
        emit(string.format("        %s => \"%s\",", const_name(e.name), e.name))
    end
    emit("        else => \"unknown EGL error\",")
    emit("    };")
    emit("}")
    emit("")
    if seen_cmd["eglGetError"] then
        declare("logError", "helper")
        emit("/// Logs the pending EGL error (if any) together with what we were doing.")
        emit("pub fn logError(comptime log: type, what: []const u8) void {")
        emit("    const code = eglGetError();")
        emit("    log.err(\"{s} failed: {s} (0x{x})\", .{ what, errorName(code), @as(u32, @bitCast(code)) });")
        emit("}")
        emit("")
    end
    if by_value[0x3000] and enums["EGL_BAD_ALLOC"] and seen_enum["EGL_BAD_ALLOC"] then
        emit("test \"error names\" {")
        emit("    try std.testing.expectEqualStrings(\"EGL_BAD_ALLOC\", errorName(BAD_ALLOC));")
        emit("}")
        emit("")
    end
end

local text = table.concat(out, "\n")
text = text:gsub("\n+$", "\n")

if out_path then
    local f, err = io.open(out_path, "wb")
    if not f then die("cannot write %s: %s", out_path, tostring(err)) end
    f:write(text)
    f:close()
else
    io.stdout:write(text)
end

io.stderr:write(string.format("gen_egl: %d types, %d constants, %d core functions, %d extension functions\n",
    n_types, n_consts, n_core, n_ext))

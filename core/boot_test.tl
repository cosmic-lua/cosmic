--- core/boot.c, the `--boot` bridge a bare core runs a tree's
--- `build.boot` through. `bin/zig build boot` runs it over this whole
--- tree with the vendored compiler; here a tree of three stand-in modules
--- and a compiler that passes its source through unchanged drive the same
--- C in a fraction of a second: the bridge, the compiler's load, the
--- syscall declaration, the raw modules preloaded for the tree, and the
--- exit status or failure `build.boot` ends with.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local artifact = require("build.artifact")

--- A compiler with the three members the bridge reaches for; `gen`
--- hands back its source, so each stand-in below is plain Lua.
local compiler <const> = [[
return {
  search_module = function() return nil end,
  new_env = function() return {} end,
  gen = function(source) return source, {} end,
}
]]

local gen_syscalls <const> = [[
return { declaration = function() return "return {}" end }
]]

--- Reaches a raw module the core preloads for the tree, then ends as
--- its argument asks.
local boot <const> = [[
local store = require("cosmic.internal.store")
return function(root, argv)
  if argv[4] == "raise" then error("asked to raise in " .. root, 0) end
  return type(store) == "table" and 7 or 3
end
]]

--- Boots the stand-in tree under `tmp` with a bare core, asking
--- `build.boot` to end as `mode` says.
local function run_boot(tmp: string, mode: string): Child.Result
  local core = assert(artifact.trusted_core())
  local path = tmp .. "/cosmic-core"
  assert(Fs.write(path, core.bytes, 0x1ed))
  assert(Fs.mkdirs(tmp .. "/tree/core"))
  assert(Fs.mkdirs(tmp .. "/tree/build"))
  assert(Fs.mkdirs(tmp .. "/tl"))
  assert(Fs.write(tmp .. "/tree/core/syscalls.h", "/* stand-in */\n"))
  assert(Fs.write(tmp .. "/tree/build/gen_syscalls.tl", gen_syscalls))
  assert(Fs.write(tmp .. "/tree/build/boot.tl", boot))
  assert(Fs.write(tmp .. "/tl/tl.lua", compiler))
  return (assert(Child.run({ path, "--boot", tmp .. "/tree", tmp .. "/tl", mode },
    { stdout = "capture", stderr = "capture", timeout_ms = 30000 })))
end

local function test_boot_exits_with_the_status_build_boot_returns(tmp: string)
  local r = run_boot(tmp, "status")
  assert(r.code == 7, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
end

local function test_boot_reports_a_build_boot_that_raises(tmp: string)
  local r = run_boot(tmp, "raise")
  assert(r.code == 1, "exit " .. tostring(r.code))
  local err = assert(r.stderr)
  assert(err:find("cosmic boot: build.boot failed: asked to raise in " .. tmp .. "/tree",
    1, true), err)
end

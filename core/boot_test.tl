--- core/boot.c, the `--boot` bridge a bare core runs a tree's
--- [`build.boot`] through. `bin/zig build boot` runs it over this whole
--- tree from the pinned release's seed; here a tree of stand-in modules
--- and a seed that passes its source through unchanged drive the same
--- C in a fraction of a second: the tree's own bridge, the seed's load, the
--- syscall declaration, the raw modules preloaded for the tree, and the
--- exit status or failure [`build.boot`] ends with.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local artifact = require("build.artifact")
local Clock = require("cosmic.clock")

--- The bridge a stand-in tree boots through, and the program itself,
--- which its tests start.
Test.policy{ grants = { { path = "core/bridge.lua", letters = "r" } } }

--- The entry of a stand-in seed: its `compile` passes each file through as its Lua, and its `program` answers the two
--- modules a boot asks for, whose Lua is their text here, by name: the generator of the syscall declaration, and
--- [`build.boot`], which reaches a raw module the core preloads for the tree and then ends as its argument asks.
local entry <const> = [==[
return {
  compile = function(files)
    local out = {}
    for index, file in ipairs(files) do
      out[index] = { path = file.path, code = file.text, syntax_errors = {}, type_errors = {}, trouble = "" }
    end
    return out
  end,
  program = function(_root, _declared)
    local modules = {
      ["build.gen_syscalls"] = [=[
        return {
          targets = { { path = "cosmic.sys", target = { header = "core/syscalls.h" } } },
          declaration = function() return "return {}" end,
        }
      ]=],
      ["build.boot"] = [=[
        local store = require("cosmic.internal.store")
        return function(root, argv)
          if argv[4] == "raise" then error("asked to raise in " .. root, 0) end
          return type(store) == "table" and 7 or 3
        end
      ]=],
    }
    return { module = function(name)
      if modules[name] then return { file = name:gsub("%.", "/") .. ".tl", code = modules[name] } end
      return nil, ""
    end }
  end,
}
]==]

--- Boots the stand-in tree under `tmp` with a bare core, asking
--- [`build.boot`] to end as `mode` says. The tree holds this tree's own
--- bridge unless `bridge` is false.
local function run_boot(tmp: string, mode: string, bridge?: boolean): Child.Result
  local core = assert(artifact.trusted_core())
  local path = tmp .. "/cosmic-core"
  assert(Fs.write(path, core.bytes, 0x1ed))
  assert(Fs.mkdirs(tmp .. "/tree/core"))
  assert(Fs.mkdirs(tmp .. "/tree/build"))
  assert(Fs.mkdirs(tmp .. "/tl"))
  assert(Fs.write(tmp .. "/tree/core/syscalls.h", "/* stand-in */\n"))
  if bridge ~= false then
    assert(Fs.write(tmp .. "/tree/core/bridge.lua", (assert(Fs.read("core/bridge.lua")))))
  end
  assert(Fs.write(tmp .. "/tree/build/seed.txt", "build/seed.tl\n"))
  assert(Fs.write(tmp .. "/tree/build/seed.tl", entry))
  assert(Fs.write(tmp .. "/tl/seed.lua", entry))
  return (assert(Child.run({ path, "--boot", tmp .. "/tree", tmp .. "/tl", mode },
    { env = { COSMIC_BUILD_CACHE = "0" }, stdout = "capture", stderr = "capture",
      timeout_ns = Clock.seconds(30) })))
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

--- A tree with no bridge is refused by name before anything runs.
local function test_boot_refuses_a_tree_without_a_bridge(tmp: string)
  local r = run_boot(tmp, "status", false)
  assert(r.code == 1, "exit " .. tostring(r.code))
  local err = assert(r.stderr)
  assert(err:find("cosmic boot: the bridge would not load", 1, true) and
      err:find("core/bridge.lua", 1, true), err)
end

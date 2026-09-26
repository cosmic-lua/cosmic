--- The compiler compiles itself to itself. A boot compiles the vendored
--- `tl.tl`, its records applied, with the vendored `tl.lua`, and the tool
--- carries what that compiled to (core/bridge.lua's `bootstrap`); that
--- compiler, compiling the same source, must give back exactly the Lua
--- it is, so the compiler the tree is built with is a function of its
--- Teal source and records alone, not of the one that first compiled it.
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local teal = require("build.teal")
local type Declared = require("build.inputs").Declared

--- The compiler's own source, as the boot vendored it.
local _inputs: Declared = { reads = { "o/vendor/tl/tl.tl" } }

--- The patched source a boot compiled, or nil in a tree no boot has
--- built: the portable suite tests a fresh `git archive` of the tree,
--- where nothing under o/ was built. In a booted tree -- one with its
--- cores under o/core -- a missing source is a failure.
local function patched_source(): string | nil
  local path = "o/vendor/tl/tl.tl"
  if Fs.exists(path) then
    return (assert(Fs.read(path)))
  end
  assert(not Fs.exists("o/core"), path .. " is missing; run bin/zig build boot")
  return nil
end

local function test_the_compiler_compiles_itself_to_itself()
  local source = patched_source()
  if source == nil then return end
  local carried = assert(Store.source("vendor.tl"))
  local built = assert(teal.load())
  local env = assert(built.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4",
  } }))
  local code, result = built.gen(source, env, nil, "tl")
  assert(code ~= nil and #result.syntax_errors == 0 and #result.type_errors == 0,
    "the compiler refused its own source")
  assert(code == carried, "the compiler compiled its own source to other Lua " ..
    "than it is: " .. tostring(#code) .. " bytes against " .. tostring(#carried))
end

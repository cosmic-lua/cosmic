--- The compiler compiles itself to itself. A boot compiles the tree's own
--- checker, [`checker/tl.tl`], with the vendored `tl.lua`, and the tool
--- carries what that compiled to (core/bridge.lua's `bootstrap`); that
--- compiler, compiling the same source, must give back exactly the Lua
--- it is, so the compiler the tree is built with is a function of its
--- Teal source alone, not of the one that first compiled it.
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local teal = require("build.teal")

--- The compiler's own source, as the boot compiled it.
Test.policy{ grants = { { path = "checker/tl.tl", letters = "r" } } }

local function test_the_compiler_compiles_itself_to_itself()
  local source = assert(Fs.read("checker/tl.tl"))
  local carried = assert(Store.source("vendor.tl"))
  -- The compiler without its line information, which compiles to the
  -- same Lua. Every test runs under the coverage line hook, which finds
  -- the line of each instruction a function with line information runs,
  -- and the compiler's lines are no coverage of the tree's. With them,
  -- this compile takes about 24 s on the checked core, past the runner's
  -- 30 on a loaded host; without them, about 9 s.
  local built = assert(teal.load(true))
  local env = assert(built.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4",
  } }))
  local code, result = built.gen(source, env, nil, "tl")
  assert(code ~= nil and #result.syntax_errors == 0,
    "the compiler could not parse its own source")
  -- It still reports type errors in its own source, which upstream's
  -- `tl.lua` accepts (tables omitting a field that does not admit nil,
  -- types passed where a narrower one is wanted). The count is pinned: a
  -- change to the checker's source that fixes or adds one moves it.
  --
  -- TODO: assert `#result.type_errors == 0` instead, once the checker's own
  -- source is migrated to the rules the checker holds the tree to.
  local known <const> = 321
  assert(#result.type_errors == known, "the checker's source has " ..
      tostring(#result.type_errors) .. " type errors, not " .. tostring(known) ..
      ": update `known` if a change to the source fixed or added one")
  assert(code == carried, "the compiler compiled its own source to other Lua " ..
      "than it is: " .. tostring(#code) .. " bytes against " .. tostring(#carried))
end

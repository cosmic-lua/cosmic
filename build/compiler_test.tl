--- The compiler compiles itself to itself. A boot compiles the tree's own
--- checker, [`checker/tl.tl`] and the files beside it ([`checker/flow.tl`],
--- [`checker/narrowing.tl`], [`checker/captures.tl`], [`checker/facts.tl`]),
--- in stages (core/bridge.lua's `bootstrap`). The seed, the Lua the pinned
--- release wrote for them, is stage one; stage one compiles them to stage
--- two, which the tool carries: the entry's Lua behind a first line that
--- holds the Lua standard library's declarations, [`checker/stdlib.d.tl`],
--- as its local `stdlib` and the Lua of each other file for its local
--- `require`. The carried compiler, compiling the same files, is stage
--- three, which must be exactly stage two: the compiler the tree is built
--- with is a function of its Teal sources and those declarations alone,
--- not of the seed that first compiled it, nor of the emitter that wrote
--- the seed. That is what this test holds.
---
--- Stage one against stage two is held at the boot, not here, since only
--- a boot holds a seed made from the files it compiles (a seed on disk
--- would be stale after the first edit of `checker/`, which the tool
--- rebuilds itself on without a boot): stage one equals stage two while
--- the generator writes what the release's does, so a seed that
--- miscompiles fails the boot, and a change to the generator declares
--- itself in `checker/SEED_DIFFERS` until the pin moves
--- ([`build/bridge_cache_test.tl`] holds the three cases).
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local checker_wrapper = require("build.checker_wrapper")
local teal = require("build.teal")
local type compiler = require("build.compiler")

--- The compiler's own source, as the boot compiled it.
Test.policy{ grants = { { path = "checker/", letters = "r" } } }

--- The checker's files other than its entry, by the name the entry
--- requires them by. A new file in `checker/` fails
--- [`test_every_checker_file_is_compiled`] until it is named here.
local parts: {{string}} = {
  { "checker.captures", "checker/captures.tl" },
  { "checker.facts", "checker/facts.tl" },
  { "checker.flow", "checker/flow.tl" },
  { "checker.narrowing", "checker/narrowing.tl" },
}

--- Makes `built` find the checker's other files by name in `texts`, as
--- the bridge makes `stage0` do, and nothing else.
local function serving(built: compiler, texts: {string:string})
  built.search_module = function(name: string, _search_all: boolean): string | nil, any
    local text = texts[name]
    if text == nil then
      return nil, nil
    end
    return name:gsub("%.", "/") .. ".tl", {
      read = function(_self: any, _what: string): string
        return text
      end,
      close = function(_self: any): boolean
        return true
      end,
    }
  end
end

local function test_the_compiler_compiles_itself_to_itself()
  local source = assert(Fs.read("checker/tl.tl"))
  local declarations = assert(Fs.read("checker/stdlib.d.tl"))
  local carried = assert(Store.source("vendor.tl"))
  -- The compiler without its line information, which compiles to the
  -- same Lua. Every test runs under the coverage line hook, which finds
  -- the line of each instruction a function with line information runs,
  -- and the compiler's lines are no coverage of the tree's. With them,
  -- this compile takes about 24 s on the checked core, past the runner's
  -- 30 on a loaded host; without them, about 9 s.
  local built = assert(teal.load(true))
  local texts: {string:string} = {}
  for _, part in ipairs(parts) do
    texts[part[1]] = assert(Fs.read(part[2]))
  end
  serving(built, texts)
  local function compile(text: string): string, compiler.Result
    local env = assert(built.new_env({ defaults = {
      feat_lax = "off", gen_compat = "off", gen_target = "5.4",
    } }))
    local made, result = built.gen(text, env, nil, "tl")
    assert(made ~= nil and #result.syntax_errors == 0,
      "the compiler could not parse its own source")
    return made, result
  end
  local code, result = compile(source)
  -- It still reports type errors in its own source, which the pinned
  -- release's checker accepts (tables omitting a field that does not admit
  -- nil, types passed where a narrower one is wanted). The count is pinned: a
  -- change to the checker's source that fixes or adds one moves it.
  --
  -- TODO: assert `#result.type_errors == 0` instead, once the checker's own
  -- source is migrated to the rules the checker holds the tree to.
  local known <const> = 317
  assert(#result.type_errors == known, "the checker's source has " ..
      tostring(#result.type_errors) .. " type errors, not " .. tostring(known) ..
      ": update `known` if a change to the source fixed or added one")
  local modules: {{string}} = {}
  for index, part in ipairs(parts) do
    local module_code, module_result = compile(texts[part[1]])
    assert(#module_result.type_errors == 0, part[2] .. " has " ..
        tostring(#module_result.type_errors) .. " type errors")
    modules[index] = { part[1], module_code, part[2] }
  end
  code = checker_wrapper.wrapped(code, declarations, modules)
  assert(code == carried, "the compiler compiled its own source to other Lua " ..
      "than it is: " .. tostring(#code) .. " bytes against " .. tostring(#carried))
end

--- The bridge compiles every `.tl` beside the entry, so a file added to
--- `checker/` without a line in `parts` would be carried and never held to
--- the fixed point above.
local function test_every_checker_file_is_compiled()
  local named: {string:boolean} = { ["tl.tl"] = true }
  for _, part in ipairs(parts) do
    named[part[2]:gsub("^checker/", "")] = true
  end
  for _, name in ipairs((assert(Fs.list("checker")))) do
    if name:find("%.tl$") ~= nil and name:find("%.d%.tl$") == nil then
      assert(named[name], "checker/" .. name .. " is compiled into the " ..
          "compiler but not held to the fixed point: add it to `parts`")
    end
  end
end

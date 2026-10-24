--- The bridge of the new checker (core/bridge_new.lua), dark until the switch: its two stages, the declared differences of
--- the seed, the searcher it installs and the compiles it keeps. Each case boots a tree of stand-ins with a bare core, as
--- core/boot_test.tl does: the stand-in seed's `compile` passes a file through as its Lua, so the stand-in sources are Lua,
--- and its `program` answers a few modules by name. The real seed is [`build/seed_proof_test.tl`]'s.

local Fs = require("cosmic.fs")
local SeedProof = require("build.seed_proof")
local Test = require("cosmic.test")
local artifact = require("build.artifact")

Test.policy{ grants = { { path = "core/bridge_new.lua", letters = "r" } } }

--- The entry of the stand-in seed, as a source and as the Lua the seed has for it (they are one text). Its `compile`
--- hands each file back as its Lua; its `program` answers the modules a boot asks for.
local ENTRY <const> = [[
local count = 0
return {
  compile = function(files)
    local out = {}
    for index, file in ipairs(files) do
      out[index] = { path = file.path, code = file.text, syntax_errors = {}, type_errors = {}, trouble = "" }
    end
    return out
  end,
  program = function(root, declared)
    local modules = {
      ["build.gen_syscalls"] = [==[
        local sys = require("cosmic.sys")
        return {
          targets = { { path = "cosmic.sys", target = { header = "core/syscalls.h" } } },
          declaration = function() return sys.getenv("DECL") or "x" end,
        }
      ]==],
      ["build.boot"] = [=[
        local helper = require("build.helper")
        return function(root, argv, source)
          local ok, err = pcall(require, "build.refused")
          if ok then return 3 end
          return tostring(err):find("refused by the generator", 1, true) and 7 or 4
        end
      ]=],
      ["build.helper"] = "return {}",
    }
    return { module = function(name)
      count = count + 1
      if name == "build.refused" then return nil, "build/refused.tl: refused by the generator" end
      if modules[name] then return { file = name:gsub("%.", "/") .. ".tl", code = modules[name] } end
      return nil, ""
    end }
  end,
}
]]

--- A second file of the stand-in seed.
local HELPER <const> = "return { helper = true }\n"

--- Writes a tree of stand-ins below `tmp` with the seed that `seed_entry` and `seed_helper` hold, and returns its path. The
--- lang/SEED_DIFFERS file is written where `differs` is given.
local function tree_of(tmp: string, seed_entry: string, differs?: string): string
  local tree = tmp .. "/tree"
  assert(Fs.mkdirs(tree .. "/core"))
  assert(Fs.mkdirs(tree .. "/build"))
  assert(Fs.mkdirs(tree .. "/lang"))
  assert(Fs.write(tree .. "/core/bridge.lua", SeedProof.shim()))
  assert(Fs.write(tree .. "/core/bridge_new.lua", (assert(Fs.read("core/bridge_new.lua")))))
  assert(Fs.mkdirs(tree .. "/core"))
  assert(Fs.write(tree .. "/core/syscalls.h", "/* stand-in */\n"))
  assert(Fs.write(tree .. "/build/seed.txt", "build/seed.tl\nlang/helper.tl\n"))
  assert(Fs.write(tree .. "/build/seed.tl", ENTRY))
  assert(Fs.write(tree .. "/lang/helper.tl", HELPER))
  if differs ~= nil then
    assert(Fs.write(tree .. "/lang/SEED_DIFFERS", differs))
  end
  assert(Fs.mkdirs(tmp .. "/seed"))
  assert(Fs.write(tmp .. "/seed/seed.lua", seed_entry))
  assert(Fs.write(tmp .. "/seed/helper.lua", HELPER))
  return tree
end

--- Boots `tree` with `tmp`'s seed; the cache is off unless `cache` names its file.
local function boot(tmp: string, tree: string, cache?: string, declaration?: string): SeedProof.Booted
  local core = tmp .. "/cosmic-core"
  if Fs.exists(core) ~= true then
    local trusted = assert(artifact.trusted_core())
    assert(Fs.write(core, trusted.bytes, 0x1ed))
  end
  local booted = assert(SeedProof.boot(core, tree, tmp .. "/seed", { "status" },
    { COSMIC_BRIDGE_TRACE = "1", COSMIC_BUILD_CACHE = cache or "0", DECL = declaration or "x" }))
  return booted
end

local function test_a_boot_loads_the_seed_compiles_it_again_and_answers_the_build_from_stage_two(tmp: string)
  local booted = boot(tmp, tree_of(tmp, ENTRY))
  -- 7: the refusal of build.refused reached the build's code whole.
  assert(booted.code == 7, "exit " .. tostring(booted.code) .. ": " .. booted.stderr)
  local seen = table.concat(booted.trace, "\n")
  assert(seen:find("read the seed list: 2 files", 1, true) and seen:find("stage two: compiled by stage one", 1, true) and
      seen:find("build.boot loaded: 3 modules compiled", 1, true), seen)
end

local function test_a_seed_that_differs_from_stage_two_is_refused_naming_the_file(tmp: string)
  local booted = boot(tmp, tree_of(tmp, ENTRY .. "-- the pin's generator wrote this differently\n"))
  assert(booted.code == 1, "exit " .. tostring(booted.code))
  assert(booted.stderr:find("differs from the build compiled by itself in build/seed.tl", 1, true), booted.stderr)
end

local function test_a_difference_the_tree_declares_is_let_through(tmp: string)
  local booted = boot(tmp, tree_of(tmp, ENTRY .. "-- other\n", "build/seed.tl\n"))
  assert(booted.code == 7, "exit " .. tostring(booted.code) .. ": " .. booted.stderr)
end

local function test_a_declared_difference_that_is_gone_is_refused(tmp: string)
  local booted = boot(tmp, tree_of(tmp, ENTRY, "build/seed.tl\n"))
  assert(booted.code == 1, "exit " .. tostring(booted.code))
  assert(booted.stderr:find("declares that the seed in", 1, true) and booted.stderr:find("differs in build/seed.tl, and it does not", 1, true),
    booted.stderr)
end

local function test_a_declared_name_that_is_no_file_of_the_seed_is_refused(tmp: string)
  local booted = boot(tmp, tree_of(tmp, ENTRY, "codegen.lua\n"))
  assert(booted.code == 1, "exit " .. tostring(booted.code))
  assert(booted.stderr:find("codegen.lua names no file of build/seed.txt", 1, true), booted.stderr)
end

local function test_a_declaration_file_that_names_nothing_is_refused(tmp: string)
  local booted = boot(tmp, tree_of(tmp, ENTRY, "\n"))
  assert(booted.code == 1, "exit " .. tostring(booted.code))
  assert(booted.stderr:find("lang/SEED_DIFFERS names no file: remove it", 1, true), booted.stderr)
end

local function test_a_seed_without_a_file_of_the_list_is_refused_naming_it(tmp: string)
  local tree = tree_of(tmp, ENTRY)
  assert(Fs.remove(tmp .. "/seed/helper.lua"))
  local booted = boot(tmp, tree)
  assert(booted.code == 1, "exit " .. tostring(booted.code))
  assert(booted.stderr:find("helper.lua", 1, true) and booted.stderr:find("the seed step of build.zig writes it", 1, true), booted.stderr)
end

local function test_two_files_of_one_basename_are_refused(tmp: string)
  local tree = tree_of(tmp, ENTRY)
  assert(Fs.write(tree .. "/build/seed.txt", "build/seed.tl\nlang/seed.tl\n"))
  assert(Fs.write(tree .. "/lang/seed.tl", HELPER))
  local booted = boot(tmp, tree)
  assert(booted.code == 1, "exit " .. tostring(booted.code))
  assert(booted.stderr:find("are both written as seed.lua", 1, true), booted.stderr)
end

local function test_a_second_boot_takes_stage_two_and_the_modules_from_the_cache(tmp: string)
  local tree = tree_of(tmp, ENTRY)
  local cache = tmp .. "/cache.db"
  local first = boot(tmp, tree, cache)
  assert(first.code == 7, "exit " .. tostring(first.code) .. ": " .. first.stderr)
  local second = boot(tmp, tree, cache)
  assert(second.code == 7, "exit " .. tostring(second.code) .. ": " .. second.stderr)
  local seen = table.concat(second.trace, "\n")
  assert(seen:find("stage two: taken from the cache", 1, true) and seen:find("build.boot loaded: 0 modules compiled", 1, true), seen)
  -- A module that is not in the row is compiled, and the row is not kept for it: the same boot after an edit compiles again.
  assert(Fs.write(tree .. "/lang/helper.tl", HELPER .. "-- edited\n"))
  assert(Fs.write(tmp .. "/seed/helper.lua", HELPER .. "-- edited\n"))
  local third = boot(tmp, tree, cache)
  assert(third.code == 7, "exit " .. tostring(third.code) .. ": " .. third.stderr)
  assert(table.concat(third.trace, "\n"):find("stage two: compiled by stage one", 1, true))
end

--- The cache key, one input at a time. Each case boots into a cache file of its own until the second boot takes both rows
--- from it, changes exactly one input, and boots again: a part of the key left out would let the old rows stand for the new
--- input, which is the stale compiler this keeps from running.

local function seen(booted: SeedProof.Booted): string
  return table.concat(booted.trace, "\n")
end

--- A tree and its seed warm in the cache `tmp`/cache.db: the second boot found both rows.
local function warmed(tmp: string, declaration?: string): string
  local tree = tree_of(tmp, ENTRY)
  boot(tmp, tree, tmp .. "/cache.db", declaration)
  local again = boot(tmp, tree, tmp .. "/cache.db", declaration)
  assert(again.code == 7, "exit " .. tostring(again.code) .. ": " .. again.stderr)
  assert(seen(again):find("stage two: taken from the cache", 1, true) and
      seen(again):find("build.boot loaded: 0 modules compiled", 1, true), seen(again))
  return tree
end

local function test_an_edit_of_the_bridge_makes_stage_two_again(tmp: string)
  local tree = warmed(tmp)
  assert(Fs.write(tree .. "/core/bridge_new.lua", assert(Fs.read(tree .. "/core/bridge_new.lua")) .. "\n-- edited\n"))
  local booted = boot(tmp, tree, tmp .. "/cache.db")
  assert(booted.code == 7, "exit " .. tostring(booted.code) .. ": " .. booted.stderr)
  assert(seen(booted):find("stage two: compiled by stage one", 1, true), seen(booted))
end

local function test_an_edit_of_the_seeds_lua_alone_makes_stage_two_again(tmp: string)
  local tree = warmed(tmp)
  assert(Fs.write(tmp .. "/seed/seed.lua", ENTRY .. "-- the pin's emitter wrote this\n"))
  assert(Fs.write(tree .. "/lang/SEED_DIFFERS", "build/seed.tl\n"))
  local booted = boot(tmp, tree, tmp .. "/cache.db")
  assert(booted.code == 7, "exit " .. tostring(booted.code) .. ": " .. booted.stderr)
  assert(seen(booted):find("stage two: compiled by stage one", 1, true), seen(booted))
end

local function test_an_edit_of_a_seed_source_alone_makes_stage_two_again(tmp: string)
  local tree = warmed(tmp)
  assert(Fs.write(tree .. "/lang/helper.tl", HELPER .. "-- edited\n"))
  assert(Fs.write(tree .. "/lang/SEED_DIFFERS", "lang/helper.tl\n"))
  local booted = boot(tmp, tree, tmp .. "/cache.db")
  assert(booted.code == 7, "exit " .. tostring(booted.code) .. ": " .. booted.stderr)
  assert(seen(booted):find("stage two: compiled by stage one", 1, true), seen(booted))
end

local function test_the_order_of_the_seed_list_makes_stage_two_again(tmp: string)
  local tree = warmed(tmp)
  assert(Fs.write(tree .. "/build/seed.txt", "lang/helper.tl\nbuild/seed.tl\n"))
  local booted = boot(tmp, tree, tmp .. "/cache.db")
  assert(booted.code == 7, "exit " .. tostring(booted.code) .. ": " .. booted.stderr)
  assert(seen(booted):find("stage two: compiled by stage one", 1, true), seen(booted))
end

--- Nothing the seed is made of changed: stage two stands, and the modules, which the whole tree names, are made again.
local function test_an_edit_elsewhere_in_the_tree_keeps_stage_two_and_makes_the_modules_again(tmp: string)
  for _, file in ipairs({ "lang/unrelated.tl", "lang/stdlib.d.tl", "core/other.h" }) do
    local tree = warmed(tmp)
    assert(Fs.write(tree .. "/" .. file, "-- edited\n"))
    local booted = boot(tmp, tree, tmp .. "/cache.db")
    assert(booted.code == 7, file .. ": exit " .. tostring(booted.code) .. ": " .. booted.stderr)
    assert(seen(booted):find("stage two: taken from the cache", 1, true), file .. ": " .. seen(booted))
    assert(seen(booted):find("build.boot loaded: [1-9]%d* modules compiled") ~= nil, file .. ": " .. seen(booted))
    assert(Fs.remove_tree(tmp .. "/tree"))
    assert(Fs.remove(tmp .. "/cache.db"))
  end
end

--- The declarations boot derives from a header are in no file of the tree the key digests: the stand-in derives them from
--- the environment.
local function test_other_declarations_than_the_modules_were_made_with_make_them_again(tmp: string)
  local tree = warmed(tmp, "one")
  local other = boot(tmp, tree, tmp .. "/cache.db", "two")
  assert(other.code == 7, "exit " .. tostring(other.code) .. ": " .. other.stderr)
  assert(seen(other):find("stage two: taken from the cache", 1, true), seen(other))
  assert(seen(other):find("build.boot loaded: [1-9]%d* modules compiled") ~= nil, seen(other))
  -- The row is kept again for the declarations it was just made with.
  local same = boot(tmp, tree, tmp .. "/cache.db", "two")
  assert(seen(same):find("build.boot loaded: 0 modules compiled", 1, true), seen(same))
end

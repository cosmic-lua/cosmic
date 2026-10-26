--- The bridge (core/bridge.lua): its two stages, the declared differences of the seed, the searcher it installs and the
--- compiles it keeps. Each case boots a tree of stand-ins with a bare core, as core/boot_test.tl does: the stand-in seed's
--- `compile` passes a file through as its Lua, so the stand-in sources are Lua, and its `program` answers a few modules by
--- name.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local artifact = require("build.artifact")
local cache_formats = require("build.cache_formats")

Test.policy{ grants = { { path = "core/bridge.lua", letters = "r" } } }

--- What [`boot`] ran.
local record Booted
  code: integer?
  stdout: string
  --- The bridge's account of its steps (`COSMIC_BRIDGE_TRACE`), one line each.
  trace: {string}
  --- The rest of the standard error.
  stderr: string
end

--- The bridge's lines that say a step (`bridge: <seconds> s ...`), and the rest of `text`.
local function split_trace(text: string): {string}, string
  local trace: mut {string} = {}
  local rest: mut {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:find("^bridge: ") ~= nil then
      trace[#trace + 1] = line
    elseif line ~= "" then
      rest[#rest + 1] = line
    end
  end
  return trace, table.concat(rest, "\n")
end

--- The entry of the stand-in seed, as a source and as the Lua the seed has for it (they are one text). Its `compile`
--- hands each file back as its Lua; its `program` answers the modules a boot asks for.
local ENTRY <const> = [[
local count = 0
local sys = require("cosmic.sys")
-- MID_RUN, "<action>:<path>", changes a file under the root as the load asks for build.helper, after the bridge took
-- its manifest and before it keeps the row: "write" makes or replaces the file, "remove" removes it.
local function mid_run()
  local action, path = (sys.getenv("MID_RUN") or ""):match("^(%a+):(.*)$")
  if action == "write" then
    local fd = assert(sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 420))
    sys.write(fd, "-- changed while the bridge ran\n")
    sys.close(fd)
  elseif action == "remove" then
    assert(sys.unlink(path))
  end
end
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
      if name == "build.helper" then mid_run() end
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
  assert(Fs.write(tree .. "/core/bridge.lua", (assert(Fs.read("core/bridge.lua")))))
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
local function boot(tmp: string, tree: string, cache?: string, declaration?: string, mid_run?: string): Booted
  local core = tmp .. "/cosmic-core"
  if Fs.exists(core) ~= true then
    local trusted = assert(artifact.trusted_core())
    assert(Fs.write(core, trusted.bytes, 0x1ed))
  end
  local ran = assert(Child.run({ core, "--boot", tree, tmp .. "/seed", "status" },
    { env = { COSMIC_BRIDGE_TRACE = "1", COSMIC_BUILD_CACHE = cache or "0", DECL = declaration or "x",
      MID_RUN = mid_run or "" },
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60), capture_limit = 1 << 24 }))
  local trace, rest = split_trace(ran.stderr or "")
  return { code = ran.code, stdout = ran.stdout or "", trace = trace, stderr = rest }
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

local function seen(booted: Booted): string
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
  assert(Fs.write(tree .. "/core/bridge.lua", assert(Fs.read(tree .. "/core/bridge.lua")) .. "\n-- edited\n"))
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

--- How many rows the cache file holds, of the kind `where` names (all where none).
local function rows(cache: string, where?: string): integer
  local db = assert(Sqlite.open(cache))
  local found = assert(Sqlite.text_rows(db, "SELECT count(*) FROM bridge_v2 " .. (where or "")))
  assert(db:close())
  local first = assert(found[1])
  return math.tointeger(tonumber(first:text(1))) or 0
end

--- Rows become code that runs, so a file or directory that anyone else could write is neither read nor written, and a link
--- is not taken for the file.
local function test_a_cache_others_could_write_is_refused(tmp: string)
  local function refused(name: string, spoil: function(string))
    local dir = tmp .. "/" .. name
    assert(Fs.mkdirs(dir))
    local tree = tree_of(dir, ENTRY)
    local cache = dir .. "/cache/cache.db"
    assert(Fs.mkdirs(dir .. "/cache"))
    assert(Fs.chmod(dir .. "/cache", 0x1c0))
    boot(dir, tree, cache)
    assert(rows(cache) == 2, name .. ": the control kept nothing")
    spoil(cache)
    local again = boot(dir, tree, cache)
    assert(again.code == 7, name .. ": exit " .. tostring(again.code) .. ": " .. again.stderr)
    assert(seen(again):find("stage two: compiled by stage one", 1, true), name .. ": rows were read from a cache others could write")
  end
  refused("group-writable-file", function(cache: string) assert(Fs.chmod(cache, 0x1b0)) end)
  refused("world-writable-directory", function(cache: string)
    assert(Fs.chmod(Fs.dirname(cache), 0x1c7))
  end)
  refused("linked-file", function(cache: string)
    assert(Fs.rename(cache, cache .. ".real"))
    assert(Fs.symlink(cache .. ".real", cache))
  end)
end

--- The file keeps the newest rows of each kind and no more.
local function test_the_cache_keeps_a_bounded_number_of_rows(tmp: string)
  local tree = tree_of(tmp, ENTRY)
  local cache = tmp .. "/cache.db"
  for round = 1, 20 do
    assert(Fs.write(tree .. "/core/syscalls.h", "/* stand-in " .. tostring(round) .. " */\n"))
    boot(tmp, tree, cache)
  end
  assert(rows(cache, "WHERE kind = 'modules'") == 16, "module rows: " .. tostring(rows(cache, "WHERE kind = 'modules'")))
  assert(rows(cache, "WHERE kind = 'compiler'") == 1)
end

--- The bridge makes its table in plain Lua; it has to be the one [`build.cache_formats`] names, which the file's
--- maintenance reads.
local function test_the_bridge_makes_the_table_the_formats_name(tmp: string)
  local cache = tmp .. "/cache.db"
  boot(tmp, tree_of(tmp, ENTRY), cache)
  local function schema(db: Sqlite.Handle): string
    local found = assert(Sqlite.text_rows(db,
      "SELECT sql FROM sqlite_schema WHERE name LIKE 'bridge_v%' ORDER BY name"))
    local out: mut {string} = {}
    for _, row in ipairs(found) do out[#out + 1] = row:text(1):gsub("%s+", "") end
    return table.concat(out, ";")
  end
  local made = assert(Sqlite.open(cache))
  local expected = assert(Sqlite.memory())
  for _, statement in ipairs(cache_formats.bridge_statements) do
    assert(expected:exec(statement))
  end
  assert(schema(made) ~= "" and schema(made) == schema(expected), schema(made))
  assert(made:close())
  assert(expected:close())
end

--- Changes the cache file by a statement, as another user of the file could.
local function sql(cache: string, statement: string)
  local db = assert(Sqlite.open(cache, { writable = true }))
  assert(db:exec(statement))
  assert(db:close())
end

--- How many modules the boot says it compiled.
local function compiled(booted: Booted): integer
  local count = seen(booted):match("build.boot loaded: (%d+) modules compiled")
  return math.tointeger(tonumber(count)) or -1
end

--- A cached row is Lua that runs before any sandbox, and its digest is the file's only check of it: a row that fails it is
--- a miss, deleted, and the compile that follows replaces it. A row that decodes to something else is the same.
local function test_a_row_whose_digest_fails_is_a_miss(tmp: string)
  local tree = warmed(tmp)
  local cache = tmp .. "/cache.db"
  local all = compiled(boot(tmp, tree, "0"))
  assert(all >= 1, "the control compiled " .. tostring(all))
  sql(cache, "UPDATE bridge_v2 SET digest = 'bad' WHERE kind = 'modules'")
  local missed = boot(tmp, tree, cache)
  assert(missed.code == 7 and compiled(missed) == all, "a module row with a bad digest was used: " .. seen(missed))
  assert(compiled(boot(tmp, tree, cache)) == 0, "the bad row was not replaced")
  sql(cache, "UPDATE bridge_v2 SET payload = deflate('tampered') WHERE kind = 'compiler'")
  local tampered = boot(tmp, tree, cache)
  assert(tampered.code == 7 and seen(tampered):find("stage two: compiled by stage one", 1, true) ~= nil,
    "a compiler row that was tampered with was used: " .. tampered.stderr .. seen(tampered))
  assert(seen(boot(tmp, tree, cache)):find("stage two: taken from the cache", 1, true), "the tampered row was not replaced")
  sql(cache, "UPDATE bridge_v2 SET payload = x'00ff' WHERE kind = 'modules'")
  assert(compiled(boot(tmp, tree, cache)) == all, "a row that does not inflate was used")
  assert(rows(cache) == 2)
end

--- A file of the tree changed after the key is made and before the row is kept is not kept under that key: the row would
--- hold the Lua of the tree as it was for the tree as it is, and undoing the change would take it as a hit. Each case
--- changes the tree in one way as the load asks for build.helper (the stand-in seed does), whichever way the bridge's
--- manifest sees it: a file edited, one added, one removed, and a header. The control changes a file the manifest does
--- not list, which keeps the row.
local function test_a_tree_changed_while_the_bridge_runs_is_not_kept(tmp: string)
  local record Case
    name: string
    --- The change, as the stand-in's MID_RUN spells it, given the tree.
    change: function(tree: string): string
    --- Undoes it, on the tree.
    undo: function(tree: string)
    kept: boolean
  end
  local cases: {Case} = {
    { name = "a note nobody reads", kept = true,
      change = function(tree: string): string return "write:" .. tree .. "/lang/note.txt" end,
      undo = function(tree: string) assert(Fs.remove(tree .. "/lang/note.txt")) end },
    { name = "an edited source", kept = false,
      change = function(tree: string): string return "write:" .. tree .. "/lang/unrelated.tl" end,
      undo = function(tree: string)
        assert(Fs.write(tree .. "/lang/unrelated.tl", "-- before\n"))
      end },
    { name = "an added source", kept = false,
      change = function(tree: string): string return "write:" .. tree .. "/lang/added.tl" end,
      undo = function(tree: string) assert(Fs.remove(tree .. "/lang/added.tl")) end },
    { name = "a removed source", kept = false,
      change = function(tree: string): string return "remove:" .. tree .. "/lang/unrelated.tl" end,
      undo = function(tree: string)
        assert(Fs.write(tree .. "/lang/unrelated.tl", "-- before\n"))
      end },
    { name = "an edited header", kept = false,
      change = function(tree: string): string return "write:" .. tree .. "/core/other.h" end,
      undo = function(tree: string) assert(Fs.write(tree .. "/core/other.h", "/* before */\n")) end },
  }
  for index, case in ipairs(cases) do
    local dir = tmp .. "/mid-" .. tostring(index)
    assert(Fs.mkdirs(dir))
    local tree = tree_of(dir, ENTRY)
    assert(Fs.write(tree .. "/lang/unrelated.tl", "-- before\n"))
    assert(Fs.write(tree .. "/core/other.h", "/* before */\n"))
    local cache = dir .. "/cache.db"
    local changed = boot(dir, tree, cache, nil, case.change(tree))
    assert(changed.code == 7, case.name .. ": exit " .. tostring(changed.code) .. ": " .. changed.stderr)
    assert((rows(cache, "WHERE kind = 'modules'") == 1) == case.kept,
      case.name .. ": the row was " .. (if case.kept then "not kept" else "kept for a tree that changed under it" end))
    if not case.kept then
      case.undo(tree)
      local restored = boot(dir, tree, cache)
      assert(restored.code == 7 and compiled(restored) >= 1,
        case.name .. ": the restored tree took the row of the changed one: " .. seen(restored))
    end
  end
end

--- `COSMIC_BUILD_CACHE=0` and a name that is not absolute each turn the cache off: nothing is read or kept.
local function test_the_cache_can_be_turned_off(tmp: string)
  local tree = tree_of(tmp, ENTRY)
  local warm = tmp .. "/warm.db"
  boot(tmp, tree, warm)
  assert(rows(warm) == 2, "the control kept nothing")
  local relative = "bridge-test-cache-" .. tostring(Clock.monotonic_ns()) .. ".db"
  for _, name in ipairs({ "0", relative }) do
    for _ = 1, 2 do
      local booted = boot(tmp, tree, name)
      assert(booted.code == 7, name .. ": exit " .. tostring(booted.code) .. ": " .. booted.stderr)
      assert(seen(booted):find("stage two: compiled by stage one", 1, true) ~= nil, name .. " kept or read rows: " .. seen(booted))
      assert(compiled(booted) >= 1, name .. " took modules from a cache: " .. seen(booted))
    end
    assert(Fs.exists(name) == false and Fs.exists(tmp .. "/" .. name) == false, name .. " made the file")
  end
  -- Off, a cache that holds the rows is not read either.
  local off = boot(tmp, tree, "0")
  assert(seen(off):find("stage two: compiled by stage one", 1, true) ~= nil and compiled(off) >= 1)
  assert(rows(warm) == 2, "the warm file changed with the cache off")
end

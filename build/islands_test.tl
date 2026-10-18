--- The islands ([`build.islands`]) are what they say: each is in the tree, each is run on the pinned release
--- and checked to parse under it in CI (the tool checks them under the fork on every build), and each file of `build/` is held to the forms the new grammar
--- refuses that it still needs.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Grammar = require("build.compile_grammar")
local islands = require("build.islands")

Test.policy{ grants = {
  { path = "bin/", letters = "r" }, { path = "build/", letters = "r" }, { path = "ci/", letters = "r" },
  { path = ".github/scripts/", letters = "r" },
} }

--- The files of `build/` among the islands.
local function build_islands(): {string}
  local out: {string} = {}
  for _, path in ipairs(islands.list) do
    if path:sub(1, 6) == "build/" then out[#out + 1] = path end
  end
  return out
end

local function test_each_island_is_in_the_tree_and_the_list_is_in_order()
  local last = ""
  for _, path in ipairs(islands.list) do
    assert(path > last, path .. " is out of order or repeated")
    last = path
    if path:sub(-1) == "/" then
      assert(Fs.is_dir(path:sub(1, -2)) == true, path .. " is no directory")
    else
      assert(Fs.exists(path) == true, path .. " does not exist")
    end
  end
end

--- A script of `bin/` that runs a file of `build/` standalone on the bootstrap release is one whose file is an
--- island, and each island of `build/` is run so.
local function test_the_scripts_run_on_the_pinned_release_are_the_islands_of_build()
  local run: {string: boolean} = {}
  for _, name in ipairs((assert(Fs.list("bin")))) do
    local text = Fs.read("bin/" .. name)
    if text ~= nil then
      for path in text:gmatch("cosmic%-bootstrap\" %-%-standalone \"%$root/(build/[%w_]+%.tl)\"") do
        run[path] = true
      end
    end
  end
  local listed: {string: boolean} = {}
  for _, path in ipairs(build_islands()) do
    listed[path] = true
  end
  for path in pairs(run) do
    assert(listed[path], path .. " runs on the pinned release and is no island")
  end
  for path in pairs(listed) do
    assert(run[path], path .. " is an island but no script of bin/ runs it")
  end
end

--- CI compiles each of them on the pinned driver, so a form that release does not parse fails there.
local function test_ci_parses_each_island_of_build_on_the_pinned_release()
  local text = (assert(Fs.read(".github/scripts/pinned-parse.sh")))
  for _, path in ipairs(build_islands()) do
    assert(text:find("\"$root/" .. path .. "\"", 1, true), path .. " is not checked by .github/scripts/pinned-parse.sh")
  end
end

--- The new grammar's parser refuses `blocked` of each island and nothing else: a count only falls, and a file
--- with none is written in the subset both grammars read, so the switch can stage it unchanged.
local function test_each_island_of_build_has_only_the_forms_blocked_names_that_the_new_grammar_refuses()
  for _, path in ipairs(build_islands()) do
    local text = (assert(Fs.read(path)))
    local made = Grammar.compile({ { path = path, relative = path, text = text, declaration = false } })
    local found: {string: integer} = {}
    local written = false
    for _, compiled in ipairs(made) do
      for _, e in ipairs(compiled.syntax_errors) do
        found[e.code] = (found[e.code] or 0) + 1
      end
      written = compiled.code ~= nil
    end
    local wanted = islands.blocked[path] or {}
    for code, count in pairs(found) do
      assert(wanted[code] == count, path .. ": " .. tostring(count) .. " of " .. code .. ", blocked " .. tostring(wanted[code]))
    end
    for code, count in pairs(wanted) do
      assert(found[code] == count, path .. ": blocked " .. tostring(count) .. " of " .. code .. ", found " .. tostring(found[code]))
    end
    if islands.blocked[path] == nil then
      assert(written, path .. " is in the common subset and the new grammar writes no Lua for it")
    end
  end
  for path in pairs(islands.blocked) do
    local listed = false
    for _, island in ipairs(islands.list) do listed = listed or island == path end
    assert(listed, path .. " is blocked but no island")
  end
end

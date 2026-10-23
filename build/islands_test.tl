--- The islands, [`ci/islands.txt`], are what they say: each is in the tree, each is run on the pinned release
--- and checked under it in CI by the driver's `check-islands` (the tool checks them under the fork on every
--- build), and each file of `build/` is held to the forms the new grammar refuses that it still needs
--- ([`build.islands`]).

local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local Test = require("cosmic.test")
local Grammar = require("build.compile_grammar")
local islands = require("build.islands")

Test.policy{ grants = {
  { path = "bin/", letters = "r" }, { path = "build/", letters = "r" }, { path = "ci/", letters = "r" },
} }

--- The islands, as the CI driver's `check-islands` reads the list (cosmic_ci/islands.tl): one path a line from the
--- root of the tree, a directory ending in "/", with what a `#` starts and blank lines left out; only the files of
--- `build/` where `build_only`.
local function listed_islands(build_only: boolean): {string}
  local out: {string} = {}
  for line in (assert(Fs.read("ci/islands.txt"))):gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" and (not build_only or path:sub(1, 6) == "build/") then out[#out + 1] = path end
  end
  return out
end

local function test_each_island_is_in_the_tree_and_the_list_is_in_order()
  local last = ""
  local paths = listed_islands(false)
  assert(#paths > 0, "ci/islands.txt names no island")
  for _, path in ipairs(paths) do
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
--- island, and so is a file that build/zig.tl runs standalone (`standalone(root, "build/patch.tl", ...)`) on that
--- release's own binary; each island of `build/` is run so.
local function test_the_scripts_run_on_the_pinned_release_are_the_islands_of_build()
  local run: {string: boolean} = {}
  local text = (assert(Fs.read("build/zig.tl")))
  for _, name in ipairs((assert(Fs.list("bin")))) do
    text = text .. "\n" .. (Fs.read("bin/" .. name) or "")
  end
  for _, pattern in ipairs({ "cosmic%-bootstrap\" %-%-standalone \"%$root/(build/[%w_]+%.tl)\"",
      "standalone%(root, \"(build/[%w_]+%.tl)\"" }) do
    for path in text:gmatch(pattern) do
      run[path] = true
    end
  end
  for _, path in ipairs({ "build/patch.tl", "build/paths.tl", "build/zig_fetch.tl" }) do
    assert(run[path] == true, "build/zig.tl no longer runs " .. path .. ", which this test looks for")
  end
  local listed: {string: boolean} = {}
  for _, path in ipairs(listed_islands(true)) do
    listed[path] = true
  end
  for path in pairs(run) do
    assert(listed[path], path .. " runs on the pinned release and is no island")
  end
  for path in pairs(listed) do
    assert(run[path], path .. " is an island but no script of bin/ runs it")
  end
end

--- The new grammar's parser refuses `blocked` of each island and nothing else: a count only falls, and a file
--- with none is written in the subset both grammars read, so the switch can stage it unchanged.
local function test_each_island_of_build_has_only_the_forms_blocked_names_that_the_new_grammar_refuses()
  for _, path in ipairs(listed_islands(true)) do
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
    for _, island in ipairs(listed_islands(false)) do listed = listed or island == path end
    assert(listed, path .. " is blocked but no island")
  end
end

--- The tool asks the list which files stay on the fork: the files and directories of the checkout's own list, by their path
--- below the nearest directory above them that holds one, and no file outside such a checkout.
local function test_the_tool_finds_the_islands_of_the_checkout_a_file_lies_in(tmp: string)
  assert(Fs.mkdirs(tmp .. "/co/ci") and Fs.mkdirs(tmp .. "/co/build") and Fs.mkdirs(tmp .. "/co/lang") and Fs.mkdirs(tmp .. "/free"))
  assert(Fs.write(tmp .. "/co/ci/islands.txt", "# the islands\n\nbuild/zig.tl  # a script\nci/\n"))
  for _, path in ipairs({ "co/build/zig.tl", "co/build/zig.tl.bak", "co/build/other.tl", "co/lang/zig.tl", "co/ci/driver.tl",
      "free/zig.tl" }) do
    assert(Fs.write(tmp .. "/" .. path, "return 1\n"))
  end
  assert(islands.holds(tmp .. "/co/build/zig.tl"))
  assert(islands.holds(tmp .. "/co/ci/driver.tl"), "a file of an island directory")
  assert(not islands.holds(tmp .. "/co/build/other.tl") and not islands.holds(tmp .. "/co/lang/zig.tl"))
  assert(not islands.holds(tmp .. "/co/build/zig.tl.bak"), "a name that only starts like an island")
  assert(not islands.holds(tmp .. "/free/zig.tl"), "a file outside a checkout")
  assert(not islands.holds(tmp .. "/nowhere/zig.tl"), "a file that is not there")
  -- this checkout's own list names the bootstrap scripts
  assert(islands.holds("build/zig.tl") and islands.holds("ci/cosmic_ci/driver.tl") and not islands.holds("build/importer.tl"))
end

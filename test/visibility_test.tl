--- Proves the sibling-privacy rule `build.positions` enforces on every
--- directory in the tree, not only cosmic's own: a directory with its
--- own `init.tl` is private, and only a file inside it may require a
--- sibling that sits beside that entry. Also proves the entry itself,
--- `case/init.tl`, resolves under its own bare name, `require("case")`
--- -- the ordinary Lua `?/init.lua` convention -- from outside `case/`,
--- which the sibling-privacy checks above never exercise.
---
--- The fixture is written to a fresh temp directory per test, the same
--- one `build.test`'s runner already hands every test function, rather
--- than checked into the tree: a version of it that violates the rule
--- would fail this tree's own build the moment it existed on disk,
--- since the whole tree compiles together in one pass.

local Fs = require("cosmic.fs")
local importer = require("build.importer")
local teal = require("build.teal")

local entry_source = "local record entry\nend\nreturn entry\n"
local sibling_source = "local record sibling\nend\nreturn sibling\n"
local user_source = "local sibling = require(\"case.sibling\")\nreturn sibling\n"
local entry_user_source = "local case = require(\"case\")\nreturn case\n"

--- Writes a directory-shaped module, `case/`, with its own `init.tl`
--- and a sibling beside it, plus one file that requires the sibling --
--- inside `case/` when `outside` is false, beside it otherwise.
local function write_fixture(root: string, outside: boolean)
  assert(Fs.mkdirs(root .. "/case"))
  assert(Fs.write(root .. "/case/init.tl", entry_source))
  assert(Fs.write(root .. "/case/sibling.tl", sibling_source))
  local user_path = outside and (root .. "/outsider.tl") or
    (root .. "/case/insider.tl")
  assert(Fs.write(user_path, user_source))
end

--- Writes the same directory-shaped module, `case/`, with a file
--- outside it that requires the entry by its own bare name, `case`,
--- rather than a sibling inside it.
local function write_entry_fixture(root: string)
  assert(Fs.mkdirs(root .. "/case"))
  assert(Fs.write(root .. "/case/init.tl", entry_source))
  assert(Fs.write(root .. "/outsider.tl", entry_user_source))
end

--- Builds the fixture at `root` and reports whether the tree compiled.
local function try_build(root: string): boolean, string
  local built, load_trouble = teal.load()
  if built == nil then
    return false, load_trouble
  end
  local env, env_trouble = teal.environment_for(built, root)
  if env == nil then
    return false, env_trouble
  end
  local result, trouble = importer.compile(root, built, env, "visibility-test")
  if result == nil then
    return false, trouble
  end
  return true, ""
end

local function test_sibling_reachable_from_within_its_own_directory(tmp: string)
  local root = tmp .. "/inside"
  write_fixture(root, false)
  local ok, trouble = try_build(root)
  assert(ok, "a sibling required from within its own directory should " ..
    "build, but: " .. tostring(trouble))
end

local function test_sibling_refused_from_outside_its_own_directory(tmp: string)
  local root = tmp .. "/outside"
  write_fixture(root, true)
  local ok, trouble = try_build(root)
  assert(not ok, "a sibling required from outside its own directory " ..
    "should have been refused")
  assert(trouble:find("case.sibling", 1, true) ~= nil and
    trouble:find("case/", 1, true) ~= nil,
    "the refusal should name the path and the private directory it " ..
    "belongs to: " .. trouble)
end

local function test_entry_reachable_from_outside_by_its_own_bare_name(tmp: string)
  local root = tmp .. "/entry"
  write_entry_fixture(root)
  local ok, trouble = try_build(root)
  assert(ok, "require(\"case\") from outside case/ should resolve to " ..
    "case/init.tl, but: " .. tostring(trouble))
end

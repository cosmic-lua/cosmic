--- Proves the privacy by position `build.positions` enforces on every
--- directory in the tree, not only cosmic's own, end to end through
--- `importer.compile`: a directory's own `init.tl` is the one path in
--- from outside, and only a file inside the directory may require a
--- sibling that sits beside that entry. Also proves the entry itself,
--- `case/init.tl`, resolves under its own bare name, `require("case")`
--- -- the ordinary Lua `?/init.lua` convention -- from outside `case/`,
--- and that a nested directory with no `init.tl`, `deep/dir/`, has no
--- path in from outside at all.
---
--- The fixture is written to a fresh temp directory per test, the same
--- one `build.test`'s runner already hands every test function, rather
--- than checked into the tree: a version of it that violates the rule
--- would fail this tree's own build the moment it existed on disk,
--- since the whole tree compiles together in one pass.

local Fs = require("cosmic.fs")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

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

--- Writes a nested directory with no entry, `deep/dir/`, holding one
--- module, and a file at the root that requires it -- or, when `inside`
--- is true, a file beside it that does.
local function write_unentered_fixture(root: string, inside: boolean)
  assert(Fs.mkdirs(root .. "/deep/dir"))
  assert(Fs.write(root .. "/deep/dir/x.tl", sibling_source))
  local user_path = inside and (root .. "/deep/dir/user.tl") or
    (root .. "/outsider.tl")
  assert(Fs.write(user_path, "local x = require(\"deep.dir.x\")\nreturn x\n"))
end

--- Builds the fixture at `root` and reports whether the tree compiled.
local function try_build(root: string): boolean, string
  local built, load_trouble = teal.load()
  if built == nil then
    return false, load_trouble
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return false, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return false, stage_trouble
  end
  local result, trouble = importer.compile(handle, built, "visibility-test")
  work.close(handle)
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

local function test_nested_directory_without_an_entry_refused_from_outside(tmp: string)
  local root = tmp .. "/unentered"
  write_unentered_fixture(root, false)
  local ok, trouble = try_build(root)
  assert(not ok, "a module in a nested directory with no init.tl, " ..
    "required from outside it, should have been refused")
  assert(trouble:find("outsider.tl: deep.dir.x is private to deep/dir/", 1, true) ~= nil,
    trouble)
end

local function test_nested_directory_without_an_entry_reachable_from_inside(tmp: string)
  local root = tmp .. "/unentered_inside"
  write_unentered_fixture(root, true)
  local ok, trouble = try_build(root)
  assert(ok, "a module required from within its own entry-less directory " ..
    "should build, but: " .. tostring(trouble))
end

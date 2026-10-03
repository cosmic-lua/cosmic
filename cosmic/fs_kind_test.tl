--- A path's kind is an enum ([`sys.Kind`], [`Fs.Kind`]): a fixture
--- comparing a `Stat`'s `kind`, or one a walk's `skip` is told, with a
--- name no path has (`"directory"`) does not compile, and one naming
--- the kinds there are does.
local Fs = require("cosmic.fs")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

-- A fixture reads the `cosmic.*` modules it requires out of the store,
-- which holds a test to its import closure: these are the ones the
-- fixtures name.
local type _sys = require("cosmic.sys")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Compiles `source` as the one module of a fresh fixture project:
--- true, or false and what the compile refused.
local function compiles(tmp: string, case: string, source: string): boolean, string
  local root = tmp .. "/" .. case
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/main.tl", source))
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return false, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return false, stage_trouble
  end
  local result, trouble = importer.compile(handle, built, "fs-kind-test")
  work.close(handle)
  if result == nil then
    return false, trouble
  end
  return true, ""
end

local function test_a_kind_no_path_has_does_not_compile(tmp: string)
  local ok, trouble = compiles(tmp, "stat", [[
local Fs = require("cosmic.fs")
local st = assert(Fs.stat("."))
return st.kind == "directory"
]])
  assert(not ok, "a comparison with \"directory\" compiled")
  assert(trouble:find('"directory" is not a member of', 1, true), trouble)
end

local function test_fs_kind_is_the_enum(tmp: string)
  local ok, trouble = compiles(tmp, "walk", [[
local Fs = require("cosmic.fs")
return Fs.walk(".", function(_: string, _: string, kind: Fs.Kind): boolean
  return kind == "directory"
end)
]])
  assert(not ok, "a comparison with \"directory\" compiled")
  assert(trouble:find('"directory" is not a member of', 1, true), trouble)
end

-- A function literal's untyped parameter is the type its callee
-- declares (patch/tl/37d), so a `skip` is held to the enum without
-- naming [`Fs.Kind`].
local function test_an_untyped_skip_is_told_a_kind(tmp: string)
  local ok, trouble = compiles(tmp, "walk-untyped", [[
local Fs = require("cosmic.fs")
return Fs.walk(".", function(_, _, kind)
  return kind == "directory"
end)
]])
  assert(not ok, "a comparison with \"directory\" compiled")
  assert(trouble:find('"directory" is not a member of', 1, true), trouble)
end

local function test_a_listing_names_kinds(tmp: string)
  local ok, trouble = compiles(tmp, "readdir", [[
local sys = require("cosmic.sys")
local entries = assert(sys.readdir("."))
for _, kind in pairs(entries) do
  if kind == "folder" then return true end
end
return false
]])
  assert(not ok, "a comparison with \"folder\" compiled")
  assert(trouble:find('"folder" is not a member of', 1, true), trouble)
end

local function test_every_kind_compiles(tmp: string)
  local ok, trouble = compiles(tmp, "valid", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local kinds: {Fs.Kind} = { "file", "dir", "link", "socket", "fifo", "char", "block", "other" }
local st = assert(sys.lstat("."))
local known: sys.Kind = st.kind
local seen = false
for _, kind in ipairs(kinds) do
  seen = seen or kind == known
end
return seen and st.kind == "dir"
]])
  assert(ok, trouble)
end

--- A path's kind is an enum ([`sys.Kind`], [`Fs.Kind`]): a fixture
--- comparing a `Stat`'s `kind`, or one a walk's `skip` is told, with a
--- name no path has (`"directory"`) does not compile, and one naming
--- the kinds there are does.
local Snippet = require("build.snippet_fixture")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

-- A fixture reads the `cosmic.*` modules it requires out of the store,
-- which holds a test to its import closure: these are the ones the
-- fixtures name.
local type _fs = require("cosmic.fs")
local type _sys = require("cosmic.sys")

--- Compiles `source` as a module of its own: true, or false and what the
--- checker refused.
local function compiles(source: string): boolean, string
  return Snippet.compiles(source)
end

local function test_a_kind_no_path_has_does_not_compile()
  local ok, trouble = compiles([[
local Fs = require("cosmic.fs")
local st = assert(Fs.stat("."))
return st.kind == "directory"
]])
  assert(not ok, "a comparison with \"directory\" compiled")
  assert(trouble:find('`"directory"` is not a member of `sys.Kind`', 1, true), trouble)
end

local function test_fs_kind_is_the_enum()
  local ok, trouble = compiles([[
local Fs = require("cosmic.fs")
return Fs.walk(".", function(_: string, _: string, kind: Fs.Kind): boolean
  return kind == "directory"
end)
]])
  assert(not ok, "a comparison with \"directory\" compiled")
  assert(trouble:find('`"directory"` is not a member of `sys.Kind`', 1, true), trouble)
end

-- A function literal's untyped parameter is the type its callee
-- declares, so a `skip` is held to the enum without naming
-- [`Fs.Kind`].
local function test_an_untyped_skip_is_told_a_kind()
  local ok, trouble = compiles([[
local Fs = require("cosmic.fs")
return Fs.walk(".", function(_, _, kind)
  return kind == "directory"
end)
]])
  assert(not ok, "a comparison with \"directory\" compiled")
  assert(trouble:find('`"directory"` is not a member of `sys.Kind`', 1, true), trouble)
end

local function test_a_listing_names_kinds()
  local ok, trouble = compiles([[
local sys = require("cosmic.sys")
local entries = assert(sys.readdir("."))
local found = false
for _, kind in pairs(entries) do
  found = found or kind == "folder"
end
return found
]])
  assert(not ok, "a comparison with \"folder\" compiled")
  assert(trouble:find('`"folder"` is not a member of `sys.Kind`', 1, true), trouble)
end

local function test_every_kind_compiles()
  local ok, trouble = compiles([[
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

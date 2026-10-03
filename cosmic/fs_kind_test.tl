--- A path's kind is an enum ([`sys.Kind`], [`Fs.Kind`]): a fixture
--- comparing a `Stat`'s `kind`, or one a walk's `skip` is told, with a
--- name no path has (`"directory"`) does not compile, and one naming
--- the kinds there are does.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local gen_syscalls = require("build.gen_syscalls")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

-- A fixture reads the `cosmic.*` modules it requires out of the store,
-- which holds a test to its import closure: these are the ones the
-- fixtures name.
local type _sys = require("cosmic.sys")

Test.needs{ reads = { "core" } }

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

-- An untyped parameter of a function literal is `any`, not what the
-- callee declares, so a `skip` holds its kind to the enum only when its
-- parameter names [`Fs.Kind`].
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

--- Every kind the core can answer is a member of the enum, and every
--- member is one it answers: the header's `Kind` and the words
--- core/syscalls_fs.c's `mode_kind` and `readdir` push are one set, so
--- a kind added to the C cannot be left out of the type.
local function test_the_enum_is_what_the_core_answers()
  local found = assert(gen_syscalls.read((assert(Fs.read("core/syscalls.h")))))
  local declared: {string:boolean} = {}
  for _, alias in ipairs(found.aliases) do
    if alias.name == "Kind" then
      for _, member in ipairs(alias.members) do declared[member.value] = true end
    end
  end
  local c = assert(Fs.read("core/syscalls_fs.c"))
  local mode_kind = assert(c:match("mode_kind %(mode_t mode%) {(.-)\n}"), "no mode_kind")
  local answered: {string:boolean} = {}
  for word in mode_kind:gmatch('return "(%w+)";') do answered[word] = true end
  local readdir = assert(c:match("COSMIC_SYSCALL%(readdir, 1%) {(.-)\n}"), "no readdir")
  for word in readdir:gmatch('kind = "(%w+)";') do answered[word] = true end
  for word in pairs(answered) do
    assert(declared[word], "the core answers \"" .. word .. "\", which Kind does not declare")
  end
  for word in pairs(declared) do
    assert(answered[word], "Kind declares \"" .. word .. "\", which the core never answers")
  end
end

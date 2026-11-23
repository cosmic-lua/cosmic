--- Tests of [`build.removed_fix`]: the new checker's error for each name [`cosmic.removed`] lists carries what to write
--- instead as its fix, and an error about any other
--- name keeps the checker's own fix.
local Driver = require("build.driver")
local Programs = require("lang.check_programs")
local Removed = require("cosmic.removed")
local Test = require("cosmic.test")

Test.policy{}

local function nothing(_file: string): boolean
  return false
end

--- The declarations the removed names are checked against: the small library of the checker's tests, and a `package`
--- with a field of its own, as the fork's standard library declares one.
local LIBRARY <const> = Programs.library .. "\nglobal record package\n  loaded: integer\nend\n"

--- The problems of the module `m`, whose text is `text`, with the modules `stubs` (by name) it requires.
local function problems_of(text: string, stubs?: {string: string}): {Driver.Problem}
  local index = Driver.index({ { "m.tl", text } }, nothing)
  local build = Driver.new({
    globals = { Driver.declarations("std", "std.d.tl", LIBRARY, {}) },
    adjust = nil, external = {}, types = false,
  })
  build:provide(Driver.files(index))
  build:provide(Driver.stubs(stubs or {}))
  return assert(build:result("m", true)).errors
end

--- The problems of each of the modules `texts` (`m1`, `m2`, ...), checked in one build so that the library is lowered once.
local function problems_of_each(texts: {string}, stubs?: {string: string}): {{Driver.Problem}}
  local files: mut {{string}} = {}
  for i, text in ipairs(texts) do
    files[#files + 1] = { "m" .. tostring(i) .. ".tl", text }
  end
  local index = Driver.index(files, nothing)
  local build = Driver.new({
    globals = { Driver.declarations("std", "std.d.tl", LIBRARY, {}) },
    adjust = nil, external = {}, types = false,
  })
  build:provide(Driver.files(index))
  build:provide(Driver.stubs(stubs or {}))
  local out: mut {{Driver.Problem}} = {}
  for i = 1, #texts do
    out[#out + 1] = assert(build:result("m" .. tostring(i), true)).errors
  end
  return out
end

--- The one problem of a list of them.
local function the(list: {Driver.Problem}, what: string): Driver.Problem
  assert(#list == 1, tostring(#list) .. " problems for " .. what)
  for _, p in ipairs(list) do
    return p
  end
  error("no problem for " .. what)
end

--- The one problem of `text`.
local function only(text: string, stubs?: {string: string}): Driver.Problem
  local list = problems_of(text, stubs)
  assert(#list == 1, tostring(#list) .. " problems for " .. text)
  for _, p in ipairs(list) do
    return p
  end
  error("no problem")
end

--- The last problem of `text`.
local function last(text: string, stubs?: {string: string}): Driver.Problem
  local found: Driver.Problem? = nil
  for _, p in ipairs(problems_of(text, stubs)) do
    found = p
  end
  assert(found ~= nil, "no problem for " .. text)
  return found
end

local function sorted(map: {string: string}): {string}
  local keys: mut {string} = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a: string, b: string): boolean
    return a < b
  end)
  return keys
end

local function test_a_removed_global_read_with_a_field_says_what_to_write_for_that_field()
  local names: mut {string} = {}
  local fields: mut {string} = {}
  local texts: mut {string} = {}
  for _, dotted in ipairs(sorted(Removed.replacements)) do
    local name, field = dotted:match("^(%a+)%.(%a+)$")
    if name ~= nil and field ~= nil and name ~= "package" then
      names[#names + 1] = name
      fields[#fields + 1] = field
      texts[#texts + 1] = "local v = " .. dotted .. "\nprint(v)\n"
    end
  end
  for i, list in ipairs(problems_of_each(texts)) do
    local name = names[i] or ""
    local field = fields[i] or ""
    local p = the(list, name .. "." .. field)
    assert(p.code == "unknown_variable" and p.stage == "scoped" and p.removed, name .. "." .. field .. ": " .. p.code)
    assert(p.fix == Removed.message(name, field), name .. "." .. field .. ": " .. p.fix)
    assert(p.fix:find("^" .. name .. "%." .. field .. " is not available: ") ~= nil, p.fix)
  end
  assert(#texts >= 40, "checked " .. tostring(#texts))
end

local function test_a_removed_global_called_or_read_alone_says_where_to_look()
  for _, name in ipairs(Removed.order) do
    local p = only("local v = " .. name .. "\nprint(v)\n")
    assert(p.fix == Removed.message(name), name .. ": " .. p.fix)
  end
  local call = only("dofile(\"x.tl\")\n")
  assert(call.code == "unknown_variable" and call.fix == Removed.message("dofile"), call.fix)
  -- a field the catalog has no entry for is told where the name's library went
  local unlisted = only("print(os.nothing_here)\n")
  assert(unlisted.fix == Removed.message("os", "nothing_here"), unlisted.fix)
  -- a method call reads the same field
  local method = only("print(io:write(\"x\"))\n")
  assert(method.fix == Removed.message("io", "write"), method.fix)
end

local function test_a_require_of_a_removed_library_says_what_replaces_it()
  for _, name in ipairs(Removed.order) do
    local p = only("local m = require(\"" .. name .. "\")\nprint(m)\n")
    assert(p.code == "require_unknown" and p.stage == "checked" and p.removed, name .. ": " .. p.code)
    assert(p.fix == Removed.message(name), name .. ": " .. p.fix)
  end
  local other = only("local m = require(\"nothing.here\")\nprint(m)\n")
  assert(other.code == "require_unknown" and other.fix:find("require a module of the project: `bin/cosmic docs` lists them; a file sees the modules of the tree", 1,
    true) ~= nil, other.fix)
  assert(not other.removed)
end

local function test_a_field_of_package_the_runtime_withholds_says_what_to_write_instead()
  for _, field in ipairs(Removed.package_fields) do
    local p = only("print(package." .. field .. ")\n")
    assert(p.code == "field_unknown" and p.stage == "checked" and p.removed, field .. ": " .. p.code)
    assert(p.fix == Removed.message("package", field), field .. ": " .. p.fix)
    local indexed = only("print(package[\"" .. field .. "\"])\n")
    assert(indexed.removed and indexed.fix == Removed.message("package", field), field .. ": " .. indexed.fix)
  end
  -- a field `package` has is read; one nothing lists keeps the checker's fix
  assert(#problems_of("print(package.loaded)\n") == 0)
  local unlisted = only("print(package.nothing_here)\n")
  assert(unlisted.code == "field_unknown" and unlisted.fix:find("^declare `nothing_here` in `package`") ~= nil, unlisted.fix)
  -- a local named `package` is the program's own, and its missing field is the ordinary error
  local own = last("local record Pk\n  x: integer\nend\nlocal package: Pk = { x = 1 }\nprint(package.path)\n")
  assert(own.code == "field_unknown" and own.fix:find("^declare `path` in") ~= nil and not own.removed, own.fix)
end

local function test_a_field_named_by_a_reserved_word_is_read_through_a_removed_global()
  -- `mut` is a keyword of the lexer and a legal field name
  local p = only("print(os.mut)\n")
  assert(p.code == "unknown_variable" and p.fix == Removed.message("os", "mut"), p.fix)
  assert(p.fix ~= Removed.message("os"), p.fix)
end

local function test_an_error_about_a_name_that_was_not_removed_keeps_the_checkers_fix()
  local p = only("print(nothing_here.x)\n")
  assert(p.code == "unknown_variable" and p.fix:find("^declare it with `local nothing_here = ...`") ~= nil and not p.removed, p.fix)
  local typed = only("local x: integer = \"s\"\nprint(x)\n")
  assert(typed.code == "not_assignable" and typed.fix:find("^pass a value of type `integer`") ~= nil, typed.fix)
end

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

--- The one problem of `text`; every test of this file but the last expects exactly one.
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

--- What `Removed` says for `key` of its `members`.
local function instead(key: string): string
  return (assert(Removed.members[key], key))
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
  assert(other.code == "require_unknown" and other.fix == "require a module of the project: `bin/cosmic docs` lists them", other.fix)
  assert(not other.removed)
end

local function test_a_field_of_package_the_runtime_withholds_says_what_to_write_instead()
  for _, field in ipairs(Removed.package_fields) do
    local p = only("print(package." .. field .. ")\n")
    assert(p.code == "field_unknown" and p.stage == "checked" and p.removed, field .. ": " .. p.code)
    assert(p.fix == Removed.message("package", field), field .. ": " .. p.fix)
  end
  -- a field `package` has is read; one nothing lists keeps the checker's fix
  assert(#problems_of("print(package.loaded)\n") == 0)
  local unlisted = only("print(package.nothing_here)\n")
  assert(unlisted.code == "field_unknown" and unlisted.fix:find("^declare `nothing_here` in `package`") ~= nil, unlisted.fix)
  -- a local named `package` is the program's own, and its missing field is the ordinary error
  local own = last("local record Pk\n  x: integer\nend\nlocal package: Pk = { x = 1 }\nprint(package.path)\n")
  assert(own.code == "field_unknown" and own.fix:find("^declare `path` in") ~= nil and not own.removed, own.fix)
end

--- The module and the member a key of [`Removed.members`] names.
local function split(key: string): string, string
  local module, member = key:match("^(.+)%.([%w_]+)$")
  assert(module ~= nil and member ~= nil, key)
  return module, member
end

--- The stub of a module with a record of its own and no member of the catalog's.
local STUB <const> = "local record Module\n  alive: integer\nend\nreturn Module\n"

local function test_a_member_a_module_no_longer_has_says_what_to_write_instead()
  local keys: {string} = sorted(Removed.members)
  local stubs: mut {string: string} = {}
  local texts: mut {string} = {}
  for _, key in ipairs(keys) do
    local module, member = split(key)
    stubs[module] = STUB
    if member:match("^%u") ~= nil then
      -- a name that begins with a capital is read as a type
      texts[#texts + 1] = "local M = require(\"" .. module .. "\")\nlocal v: M." .. member .. " = nil\nprint(v)\n"
    else
      texts[#texts + 1] = "local M = require(\"" .. module .. "\")\nlocal v = M." .. member .. "\nprint(v)\n"
    end
  end
  local types = 0
  for i, list in ipairs(problems_of_each(texts, stubs)) do
    local key = keys[i] or ""
    local _, member = split(key)
    local p = the(list, key)
    if member:match("^%u") ~= nil then
      assert(p.code == "member_missing" and p.stage == "declared", key .. ": " .. p.code)
      types = types + 1
    else
      assert(p.code == "field_unknown" and p.stage == "checked", key .. ": " .. p.code)
    end
    assert(p.fix == "M." .. member .. " was removed: " .. instead(key) and p.removed, key .. ": " .. p.fix)
  end
  assert(#keys >= 100 and types >= 30, "checked " .. tostring(#keys) .. " members, " .. tostring(types) .. " types")
end

local HASH <const> = "local record Hash\n  alive: integer\nend\nreturn Hash\n"

local function test_a_member_called_through_the_module_or_a_value_of_its_record_is_told_the_same()
  local stubs: {string: string} = { ["cosmic.hash"] = HASH }
  local why = instead("cosmic.hash.hex")
  local direct = only("local Hash = require(\"cosmic.hash\")\nlocal d = Hash.hex(\"x\")\nprint(d)\n", stubs)
  assert(direct.fix == "Hash.hex was removed: " .. why, direct.fix)
  local value = only("local Hash = require(\"cosmic.hash\")\nlocal function f(h: Hash)\n  print(h:hex(\"x\"))\nend\nreturn f\n", stubs)
  assert(value.code == "field_unknown", value.code)
  assert(value.fix == "h:hex was removed: " .. why, value.fix)
  -- named by another binding of the module
  local other = only("local Digest = require(\"cosmic.hash\")\nlocal d = Digest.hex(\"x\")\nprint(d)\n", stubs)
  assert(other.fix == "Digest.hex was removed: " .. why, other.fix)
end

local function test_a_member_the_catalog_does_not_list_keeps_the_checkers_fix()
  local stubs: {string: string} = { ["cosmic.hash"] = HASH }
  local p = only("local Hash = require(\"cosmic.hash\")\nlocal d = Hash.nothing_here(\"x\")\nprint(d)\n", stubs)
  assert(p.code == "field_unknown" and p.fix:find("^declare `nothing_here` in `Hash`") ~= nil and not p.removed, p.fix)
  -- a module of the program's own with a member of the same name is no cosmic module's
  local own = only("local Hash = require(\"own.hash\")\nlocal d = Hash.hex(\"x\")\nprint(d)\n", { ["own.hash"] = HASH })
  assert(own.fix:find("^declare `hex` in `Hash`") ~= nil, own.fix)
  -- a type is named by a capital: a removed function the program writes in a type's place is the ordinary error
  local lowercase = only("local Hash = require(\"cosmic.hash\")\nlocal v: Hash.hex = nil\nprint(v)\n", stubs)
  assert(lowercase.code == "member_missing" and not lowercase.removed, lowercase.fix)
  local type_named = only("local Zip = require(\"own.zip\")\nlocal v: Zip.ZipReader = nil\nprint(v)\n",
    { ["own.zip"] = "local record Zip\nend\nreturn Zip\n" })
  assert(type_named.code == "member_missing" and type_named.fix:find("^declare `ZipReader` inside `Zip`") ~= nil, type_named.fix)
end

--- A module whose own record has a nested record, as cosmic.fs has `Stat` and cosmic.sqlite `Handle`.
local function nested_stub(record: string, nested: string): string
  return "local record " .. record .. "\n  alive: integer\n  record " .. nested .. "\n    size: integer\n  end\nend\nreturn " ..
    record .. "\n"
end

local function test_a_field_of_another_record_of_the_module_is_not_a_removed_member_of_the_module()
  -- `Fs.truncate`, `Json.items` and `Sqlite.close` were removed from the modules, not from the records they declare
  local cases: {{string}} = {
    { "cosmic.fs", "Fs", "Stat", "truncate", "s.truncate" },
    { "cosmic.json", "Json", "Value", "items", "s.items" },
    { "cosmic.sqlite", "Sqlite", "Handle", "close", "s.close" },
    { "cosmic.sqlite", "Sqlite", "Handle", "cell", "s:cell(1)" },
  }
  for _, case in ipairs(cases) do
    local module, record, nested, member, read = case[1], case[2], case[3], case[4], case[5]
    assert(module ~= nil and record ~= nil and nested ~= nil and member ~= nil and read ~= nil)
    assert(Removed.members[module .. "." .. member] ~= nil, module .. "." .. member .. " is no removed member")
    local p = only("local " .. record .. " = require(\"" .. module .. "\")\nlocal function f(s: " .. record .. "." .. nested ..
        ")\n  print(" .. read .. ")\nend\nreturn f\n", { [module] = nested_stub(record, nested) })
    assert(p.code == "field_unknown" and not p.removed and p.fix:find("was removed", 1, true) == nil, module .. ": " .. p.fix)
  end
  -- the module's own record, read through a value of it, is the removed member
  local own = only("local Fs = require(\"cosmic.fs\")\nlocal function f(s: Fs)\n  print(s.truncate)\nend\nreturn f\n",
    { ["cosmic.fs"] = nested_stub("Fs", "Stat") })
  assert(own.removed and own.fix == "s.truncate was removed: " .. instead("cosmic.fs.truncate"), own.fix)
end

local function test_a_member_read_through_a_require_call_or_an_index_by_a_string_is_told_the_same()
  local stubs: {string: string} = { ["cosmic.hash"] = HASH }
  local call = only("print(require(\"cosmic.hash\").hex)\n", stubs)
  assert(call.code == "field_unknown" and call.removed, call.fix)
  assert(call.fix == "require(\"cosmic.hash\").hex was removed: " .. instead("cosmic.hash.hex"), call.fix)
  local method = only("print(require(\"cosmic.hash\"):hex(\"x\"))\n", stubs)
  assert(method.removed and method.fix:find("^require%(\"cosmic.hash\"%):hex was removed: ") ~= nil, method.fix)
  local own = only("print(require(\"own.hash\").hex)\n", { ["own.hash"] = HASH })
  assert(not own.removed, own.fix)
  local indexed = only("local Hash = require(\"cosmic.hash\")\nprint(Hash[\"hex\"])\n", stubs)
  assert(indexed.removed and indexed.fix == "Hash[\"hex\"] was removed: " .. instead("cosmic.hash.hex"), indexed.fix)
  for _, field in ipairs(Removed.package_fields) do
    local p = only("print(package[\"" .. field .. "\"])\n")
    assert(p.code == "field_unknown" and p.removed and p.fix == Removed.message("package", field), field .. ": " .. p.fix)
  end
end

local function test_a_field_named_by_a_reserved_word_is_read_through_a_removed_global()
  -- `mut` is a keyword of the lexer and a legal field name
  local p = only("print(os.mut)\n")
  assert(p.code == "unknown_variable" and p.fix == Removed.message("os", "mut"), p.fix)
  assert(p.fix ~= Removed.message("os"), p.fix)
end

local function test_a_field_deeper_than_the_member_the_catalog_lists_is_the_ordinary_error()
  -- `Hash.hex` is a field the module has here, so `Hash.hex.x` is a missing field of what it holds, not a removed `hex`
  local stubs: {string: string} = {
    ["cosmic.hash"] = "local record Hash\n  record Inner\n    alive: integer\n  end\n  hex: Inner\nend\nreturn Hash\n",
  }
  local chained = only("local Hash = require(\"cosmic.hash\")\nprint(Hash.hex.x)\n", stubs)
  assert(chained.code == "field_unknown" and not chained.removed and chained.fix:find("^declare `x` in") ~= nil, chained.fix)
end

--- The stub of cosmic.sqlite's two types that matter here: the options record and a function that takes it.
local SQLITE <const> = "local record Sqlite\n  record OpenOptions\n    writable?: boolean\n  end\n" ..
  "  open: function(string, p2?: OpenOptions): integer\n  other: function(string, p2?: boolean): integer\nend\nreturn Sqlite\n"

local function test_a_boolean_given_where_a_record_now_goes_says_what_the_record_replaced()
  local stubs: {string: string} = { ["cosmic.sqlite"] = SQLITE }
  local why = assert(Removed.arguments["cosmic.sqlite.OpenOptions"])
  for _, value in ipairs({ "true", "false" }) do
    local p = only("local Sqlite = require(\"cosmic.sqlite\")\nlocal db = Sqlite.open(\"x\", " .. value .. ")\nprint(db)\n", stubs)
    assert(p.code == "not_assignable" and p.removed, p.code)
    assert(p.fix == "Sqlite.OpenOptions replaced a boolean argument: " .. why, p.fix)
  end
  -- not at an argument, not a boolean, not a record the catalog lists, and not from the module the catalog names
  local assigned = only("local Sqlite = require(\"cosmic.sqlite\")\nlocal o: Sqlite.OpenOptions = true\nprint(o)\n", stubs)
  assert(assigned.fix:find("replaced a boolean") == nil and not assigned.removed, assigned.fix)
  local number = only("local Sqlite = require(\"cosmic.sqlite\")\nlocal db = Sqlite.open(\"x\", 1)\nprint(db)\n", stubs)
  assert(number.fix:find("replaced a boolean") == nil and not number.removed, number.fix)
  local own = only("local Sqlite = require(\"own.sqlite\")\nlocal db = Sqlite.open(\"x\", true)\nprint(db)\n",
    { ["own.sqlite"] = SQLITE })
  assert(own.fix:find("replaced a boolean") == nil and not own.removed, own.fix)
end

local function test_an_error_about_a_name_that_was_not_removed_keeps_the_checkers_fix()
  local p = only("print(nothing_here.x)\n")
  assert(p.code == "unknown_variable" and p.fix:find("^declare it with `local nothing_here = ...`") ~= nil and not p.removed, p.fix)
  local typed = only("local x: integer = \"s\"\nprint(x)\n")
  assert(typed.code == "not_assignable" and typed.fix:find("^pass a value of type `integer`") ~= nil, typed.fix)
end

--- The stub of cosmic.sqlite's row: an interface whose values are read by column, with a function that answers one.
local ROWS <const> = "local record Sqlite\n  interface Row\n    count: function(Row): integer\n  end\n" ..
  "  first: function(): Row\nend\nreturn Sqlite\n"

local function test_a_row_indexed_like_a_list_says_how_a_row_is_read()
  local stubs: {string: string} = { ["cosmic.sqlite"] = ROWS }
  local why = assert(Removed.indexed["cosmic.sqlite.Row"])
  local p = only("local Sqlite = require(\"cosmic.sqlite\")\nlocal row = Sqlite.first()\nprint(row[1])\n", stubs)
  assert(p.code == "not_indexable" and p.removed and p.fix == why, p.fix)
  assert(why:find("row:text(i)", 1, true) and why:find("row:integer(i)", 1, true) and why:find("row:texts()", 1, true), why)
  -- a module required under another name is the same module
  local aliased = only("local S = require(\"cosmic.sqlite\")\nlocal row = S.first()\nprint(row[1])\n", stubs)
  assert(aliased.removed and aliased.fix == why, aliased.fix)
  -- the same record from a module that is not cosmic.sqlite, and a record the catalog does not list, keep the checker's fix
  local own = only("local Sqlite = require(\"own.sqlite\")\nlocal row = Sqlite.first()\nprint(row[1])\n", { ["own.sqlite"] = ROWS })
  assert(own.code == "not_indexable" and not own.removed and own.fix:find("^index an array") ~= nil, own.fix)
  local plain = only("local record R\n  n: integer\nend\nlocal r: R = { n = 1 }\nprint(r[1])\n")
  assert(not plain.removed, plain.fix)
end

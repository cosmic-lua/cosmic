local Removed = require("cosmic.removed")

--- Every module a replacement quotes, required by a literal name so the
--- test's import closure holds each: a `require` of a computed name is
--- refused under `cosmic test` ([`build.test_worker`]).
local modules <const>: {string:any} = {
  ["cosmic.child"] = require("cosmic.child"), -- checked: any_use
  ["cosmic.clock"] = require("cosmic.clock"), -- checked: any_use
  ["cosmic.env"] = require("cosmic.env"), -- checked: any_use
  ["cosmic.errors"] = require("cosmic.errors"), -- checked: any_use
  ["cosmic.fs"] = require("cosmic.fs"), -- checked: any_use
  ["cosmic.proc"] = require("cosmic.proc"), -- checked: any_use
  ["cosmic.stream"] = require("cosmic.stream"), -- checked: any_use
  ["cosmic.string"] = require("cosmic.string"), -- checked: any_use
  ["cosmic.time"] = require("cosmic.time"), -- checked: any_use
}

--- Every replacement is for a field of a name the surface removes, so
--- `message` can reach it: an entry under a misspelt library would never
--- be said.
local function test_every_replacement_is_for_a_removed_name()
  local package_fields: mut {string:boolean} = {}
  for _, field in ipairs(Removed.package_fields) do
    package_fields[field] = true
  end
  for dotted in pairs(Removed.replacements) do
    local name, field = dotted:match("^([%a_]+)%.([%a_]+)$")
    if name == "package" then
      -- `package` is no removed name: only its four removed fields are.
      assert(field ~= nil and package_fields[field] == true, dotted)
      assert(Removed.names.package == nil) -- checked: map_field
    else
      assert(name ~= nil and Removed.names[name] ~= nil, dotted)
    end
  end
  for _, field in ipairs(Removed.package_fields) do
    assert(Removed.replacements["package." .. field] ~= nil, field)
  end
  for _, name in ipairs(Removed.order) do
    assert(Removed.names[name] ~= nil, name)
  end
end

--- Each removed field of `package` says there is no search path and
--- what a module or a file's text comes from instead.
local function test_the_removed_package_fields_say_what_to_do_instead()
  assert(#Removed.package_fields == 4)
  for _, field in ipairs(Removed.package_fields) do
    local text = Removed.message("package", field)
    assert(text:find("package." .. field .. " is not available: ", 1, true) == 1, text)
    assert(text:find("require(name)", 1, true) ~= nil, text)
  end
  assert(Removed.message("package", "path"):find("Fs.read(path)", 1, true) ~= nil)
  assert(Removed.message("package", "loaded") == "package.loaded is not available")
end

local function test_a_field_with_no_replacement_names_where_to_look()
  assert(Removed.message("debug", "nonesuch") ==
      "debug.nonesuch is not available: " .. Removed.names.debug) -- checked: map_field
  assert(Removed.message("print") == "print is not available")
end

--- Every dotted [`Alias.name`] a replacement quotes names a function or
--- value that the module the same entry's `local Alias =
--- require("...")` brings in still has, so a rename there cannot leave a
--- hint pointing at nothing. Only that form is read: not `Alias:method`
--- nor a second segment (`Alias.record.field`). A capitalized name is a
--- type (Stream.EntryKind), which is no field of the module's table and
--- is not checked; a qualifier the entry does not require (a record such
--- as ExtractOptions, a name in prose) is not a module and is passed
--- over. An entry that requires a module must quote at least one name of
--- it (a type counts, though it is not looked up), so a pattern that stopped matching would fail rather than check
--- nothing.
local function test_every_quoted_function_exists_in_the_module_it_names()
  local entries: mut {string:string} = {}
  for _, group in ipairs({ Removed.replacements, Removed.names }) do
    for key, text in pairs(group) do
      entries[key] = text
    end
  end
  for key, text in pairs(entries) do
    local aliases: mut {string:string} = {}
    local required = 0
    for alias, module in text:gmatch("local ([%a_][%w_]*) = require%(\"([%w_.]+)\"%)") do
      aliases[alias] = module
      required = required + 1
    end
    local checked = 0
    for alias, field in text:gmatch("%f[%w_]([%a_][%w_]*)%.([%a_][%w_]*)") do
      local module = aliases[alias]
      if module ~= nil then
        checked = checked + 1
      end
      if module ~= nil and not field:find("^%u") then
        local loaded = modules[module]
        assert(loaded ~= nil, module .. " is not among this test's modules: add it")
        assert(loaded is {string: any} and loaded[field] ~= nil, -- checked: is_on_record
          key .. " quotes " .. alias .. "." .. field .. ", which " .. module .. " lacks")
      end
    end
    assert(required == 0 or checked > 0, key .. " requires a module and quotes none of its names")
  end
end

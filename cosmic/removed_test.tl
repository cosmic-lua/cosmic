local Removed = require("cosmic.removed")

--- Every module [`Removed.members`] names a member of, required by a
--- literal name so the test's import closure holds each: a `require`
--- of a computed name is refused under `cosmic test`
--- ([`build.test_worker`]).
local modules <const>: {string:any} = {
  ["cosmic.archive"] = require("cosmic.archive"),
  ["cosmic.codec"] = require("cosmic.codec"),
  ["cosmic.hash"] = require("cosmic.hash"),
  ["cosmic.json"] = require("cosmic.json"),
  ["cosmic.sqlite"] = require("cosmic.sqlite"),
  ["cosmic.stream"] = require("cosmic.stream"),
  ["cosmic.sys"] = require("cosmic.sys"),
  ["cosmic.tar"] = require("cosmic.tar"),
  ["cosmic.zip"] = require("cosmic.zip"),
}

--- Every replacement is for a field of a name the surface removes, so
--- `message` can reach it: an entry under a misspelt library would never
--- be said.
local function test_every_replacement_is_for_a_removed_name()
  for dotted in pairs(Removed.replacements) do
    local name = dotted:match("^([%a_]+)%.")
    assert(name ~= nil and Removed.names[name] ~= nil, dotted)
  end
  for _, name in ipairs(Removed.order) do
    assert(Removed.names[name] ~= nil, name)
  end
end

local function test_a_field_with_no_replacement_names_where_to_look()
  assert(Removed.message("debug", "getinfo") ==
    "debug.getinfo is not available: " .. Removed.names.debug)
  assert(Removed.message("print") == "print is not available")
end

--- Every removed member names a `cosmic.*` module that loads and no
--- longer has that member, so its replacement is never said for a
--- member that still works.
local function test_every_removed_member_is_gone_from_its_module()
  for dotted in pairs(Removed.members) do
    local module, member = dotted:match("^(cosmic%.[%w_]+)%.([%w_]+)$")
    assert(module ~= nil, dotted)
    local loaded = modules[module]
    assert(loaded ~= nil, module .. " is not among this test's modules: add it")
    assert(loaded is {string: any} and loaded[member] == nil, dotted)
  end
end

--- A program that called a streaming coder is told that `cosmic codec`
--- has them and which whole-string function to use.
local function test_the_removed_coders_name_the_verb_and_the_whole_string_functions()
  for _, member in ipairs({ "encoder", "decoder", "Coder", "Name" }) do
    local instead = Removed.members["cosmic.codec." .. member]
    assert(instead ~= nil, member)
    assert(instead:find("`cosmic codec`", 1, true), instead)
    assert(instead:find("Codec.base64", 1, true), instead)
  end
end

--- A program that named the removed codec type is told its interface.
local function test_the_removed_codec_type_names_the_transform_interface()
  local instead = Removed.members["cosmic.stream.Codec"]
  assert(instead ~= nil and instead:find("Stream.Transform", 1, true), instead)
end

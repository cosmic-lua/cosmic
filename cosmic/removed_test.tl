local Removed = require("cosmic.removed")

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
    local loaded: any = require(module)
    assert(loaded is {string: any} and loaded[member] == nil, dotted)
  end
end

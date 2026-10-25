--- The names cosmic's runtime removes, spelled apart from the catalog ([`cosmic.removed`]) in [`build.withheld`] so that a compile
--- is decided by that module alone, are the very names the catalog lists, in its order.

local Removed = require("cosmic.removed")
local withheld = require("build.withheld")

local function test_the_withheld_globals_are_the_catalog_s_order()
  assert(#withheld.globals == #Removed.order,
    table.concat(withheld.globals, " ") .. " against " .. table.concat(Removed.order, " "))
  for i, name in ipairs(Removed.order) do
    assert(withheld.globals[i] == name, tostring(i) .. ": " .. tostring(withheld.globals[i]) ..
        " against the catalog's " .. name)
  end
end

local function test_the_withheld_package_fields_are_the_catalog_s_order()
  assert(table.concat(withheld.package_fields, " ") == table.concat(Removed.package_fields, " "))
end

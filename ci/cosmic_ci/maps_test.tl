local Maps = require("cosmic_ci.maps")

local function test_with_adds_and_replaces_without_changing_either_map()
  local base: {string:string} = { A = "1", B = "2" }
  local extra: {string:string} = { B = "3", C = "4" }
  local merged = Maps.with(base, extra)
  assert(merged["A"] == "1" and merged["B"] == "3" and merged["C"] == "4")
  assert(base["B"] == "2" and base["C"] == nil)
  assert(extra["A"] == nil)
end

local function test_without_leaves_the_names_out_and_the_map_alone()
  local base: {string:string} = { A = "1", B = "2", C = "3" }
  local left = Maps.without(base, { "A", "C", "absent" })
  assert(left["A"] == nil and left["B"] == "2" and left["C"] == nil)
  assert(base["A"] == "1" and base["C"] == "3")
end

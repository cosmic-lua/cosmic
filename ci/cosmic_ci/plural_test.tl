local Plural = require("cosmic_ci.plural")

--- Exactly one takes the singular; zero and every other count take the plural.
local function test_one_is_singular_and_the_rest_are_plural()
  assert(Plural.count(1, "asset") == "1 asset")
  assert(Plural.count(0, "asset") == "0 assets")
  assert(Plural.count(3, "directory", "directories") == "3 directories")
  assert(Plural.noun(1, "row") == "row" and Plural.noun(2, "row") == "rows")
end

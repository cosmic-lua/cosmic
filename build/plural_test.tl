local plural = require("build.plural")

--- Exactly one takes the singular; zero and every other count take the
--- plural.
local function test_one_is_singular_and_the_rest_are_plural()
  assert(plural.count(1, "use") == "1 use")
  assert(plural.count(0, "use") == "0 uses")
  assert(plural.count(2, "database") == "2 databases")
  assert(plural.count(1, "entry", "entries") == "1 entry")
  assert(plural.count(3, "entry", "entries") == "3 entries")
end

--- The bare noun follows the same rule, for a line that prints the
--- number itself.
local function test_the_bare_noun_follows_the_count()
  assert(plural.noun(1, "row") == "row")
  assert(plural.noun(12, "row") == "rows")
end

local Coverage = require("cosmic.coverage")

local function test_long_source_names_remain_distinct()
  -- Both names exceed short_src's display limit. Their identical suffix
  -- must not merge their hits.
  local suffix = string.rep("shared", 50)
  local first = "coverage.first." .. suffix
  local second = "coverage.second." .. suffix
  local a, a_trouble = load("local n = 1\nreturn n", "@" .. first, "t")
  local b, b_trouble = load("\n\nlocal n = 2\nreturn n", "@" .. second, "t")
  assert(a ~= nil, tostring(a_trouble))
  assert(b ~= nil, tostring(b_trouble))
  assert(a() == 1)
  assert(b() == 2)

  local hits = Coverage.snapshot()
  local first_hits = hits[first]
  local second_hits = hits[second]
  assert(first_hits ~= nil, "full first source name must be preserved")
  assert(second_hits ~= nil, "full second source name must be preserved")
  assert(first_hits[1] == true)
  assert(first_hits[3] == nil, "second source's hits must not leak into first")
  assert(second_hits[3] == true)
  assert(second_hits[1] == nil, "first source's hits must not leak into second")
end

--- `build.c_functions.tally` against made-up functions and hits, so the
--- rules hold whatever C the core has today.

local type Coverage = require("cosmic.coverage")
local c_functions = require("build.c_functions")

local function fn(path: string, line: integer, name: string): Coverage.Function
  return { path = path, line = line, name = name }
end

local function test_a_function_is_entered_when_its_line_is_hit()
  local tally = c_functions.tally({
    fn("core/a.c", 10, "entered"),
    fn("core/a.c", 20, "missed"),
  }, { ["core/a.c"] = { [10] = true } })
  assert(tally.total == 2 and tally.entered == 1 and tally.exempted == 0)
  assert(#tally.unentered == 1 and tally.unentered[1] == "core/a.c:missed")
end

local function test_an_exempt_function_is_not_a_failure()
  local exempt = next(c_functions.exempt) as string
  local path, name = exempt:match("^(.-):([^:]+)$")
  local tally = c_functions.tally({ fn(path, 1, name) }, {})
  assert(tally.exempted == 1 and #tally.unentered == 0)
end

local function test_a_header_helper_is_left_out()
  local tally = c_functions.tally({ fn("core/check.h", 5, "helper") }, {})
  assert(tally.total == 0 and #tally.unentered == 0)
end

local function test_one_copy_entered_enters_the_function()
  local tally = c_functions.tally({
    fn("core/a.c", 10, "copied"),
    fn("core/a.c", 30, "copied"),
  }, { ["core/a.c"] = { [30] = true } })
  assert(tally.total == 1 and tally.entered == 1 and #tally.unentered == 0)
end

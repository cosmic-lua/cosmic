local positions = require("build.positions")

--- Joins lines the way a real source file would read, without writing
--- any of them starting at column 0 in THIS file: a long-bracket
--- string holding literal `local function test_*` lines would also be
--- found by this very file's own discovery pass, since it is a plain
--- text scan with no notion of what a string literal is.
local function lines(parts: {string}): string
  return table.concat(parts, "\n") .. "\n"
end

--- A `local function test_*` at column 0 is discovered, in the order
--- it appears.
local function test_discovers_top_level_tests()
  local source = lines({
    "local function test_one()",
    "end",
    "",
    "local function test_two()",
    "end",
  })
  local found = positions.discover_tests(source)
  assert(#found == 2, "expected 2, got " .. #found)
  assert(found[1] == "test_one")
  assert(found[2] == "test_two")
end

--- A helper that is not named `test_*` is not a test.
local function test_ignores_non_test_functions()
  local source = lines({
    "local function helper()",
    "end",
    "",
    "local function test_uses_helper()",
    "end",
  })
  local found = positions.discover_tests(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_uses_helper")
end

--- A `local function test_*` declared inside another function is
--- indented, not at column 0, and is not a test some other function
--- happens to declare for itself.
local function test_ignores_indented_functions()
  local source = lines({
    "local function outer()",
    "  local function test_inner()",
    "  end",
    "  return test_inner",
    "end",
    "",
    "local function test_top()",
    "end",
  })
  local found = positions.discover_tests(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_top")
end

--- A module with no `local function test_*` at all discovers nothing.
local function test_discovers_nothing_when_there_is_no_test()
  local source = lines({ "local function helper()", "end" })
  local found = positions.discover_tests(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

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

--- A source SAMPLE held as a `[[...]]` long-bracket string can put its
--- own `local function test_*` at column 0 inside the bracket; that is
--- fixture text, not a real test of the file it sits in.
local function test_ignores_a_fake_test_inside_a_plain_long_bracket()
  local source = lines({
    "local sample = [[",
    "local function test_something()",
    "  return 1",
    "end",
    "]]",
  })
  local found = positions.discover_tests(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- The same shape, but the bracket carries one `=` sign, `[=[...]=]`,
--- which only a matching `]=]` closes.
local function test_ignores_a_fake_test_inside_a_leveled_long_bracket()
  local source = lines({
    "local sample = [=[",
    "local function test_something()",
    "end",
    "]=]",
  })
  local found = positions.discover_tests(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- A long COMMENT has the identical column-0-inside risk as a
--- long-bracket string and needs the same skip.
local function test_ignores_a_fake_test_inside_a_long_comment()
  local source = lines({
    "--[[",
    "local function test_something()",
    "end",
    "]]",
  })
  local found = positions.discover_tests(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- Scanning resumes after a skipped bracket region: a real test that
--- follows one in the same file is still discovered.
local function test_discovers_a_real_test_after_a_bracket_region()
  local source = lines({
    "local sample = [[",
    "local function test_fake()",
    "end",
    "]]",
    "",
    "local function test_real()",
    "end",
  })
  local found = positions.discover_tests(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_real")
end

--- A bracket region does not retroactively un-discover a real test
--- that came before it in the same file.
local function test_discovers_a_real_test_before_a_bracket_region()
  local source = lines({
    "local function test_real()",
    "end",
    "",
    "local sample = [[",
    "local function test_fake()",
    "end",
    "]]",
  })
  local found = positions.discover_tests(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_real")
end

--- An ordinary quoted string holding the same text as a plain literal,
--- on one line, was never actually a problem, since the pattern is
--- anchored at column 0 and a quote character sits before it; confirm
--- this still is not one.
local function test_ignores_a_quoted_string_naming_a_test()
  local source = lines({
    'local x = "local function test_x()"',
    "",
    "local function test_real()",
    "end",
  })
  local found = positions.discover_tests(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_real")
end

--- A file with no top-level return has none to collide with a
--- generated tail.
local function test_has_top_level_return_false_when_absent()
  local source = lines({ "local function helper()", "end" })
  assert(not positions.has_top_level_return(source))
end

--- A genuine top-level `return`, the file's own last statement.
local function test_has_top_level_return_true_for_a_real_one()
  local source = lines({
    "local function test_one()",
    "end",
    "",
    "return 0",
  })
  assert(positions.has_top_level_return(source))
end

--- A `return` nested inside a function body is indented, not at
--- column 0, and is not the file's own chunk-level return.
local function test_has_top_level_return_false_when_only_nested()
  local source = lines({
    "local function helper()",
    "  return 1",
    "end",
  })
  assert(not positions.has_top_level_return(source))
end

--- A `return` inside a long-bracket sample does not count either.
local function test_has_top_level_return_false_inside_a_bracket()
  local source = lines({
    "local sample = [[",
    "return 0",
    "]]",
  })
  assert(not positions.has_top_level_return(source))
end

--- A table constructor return is still a genuine top-level return.
local function test_has_top_level_return_true_for_a_table_constructor()
  local source = lines({ "return {" })
  assert(positions.has_top_level_return(source))
end

--- A `return` immediately followed by a comment, with no value, is
--- still the chunk's genuine top-level return.
local function test_has_top_level_return_true_with_a_trailing_comment()
  local source = lines({ "return -- nothing to give back" })
  assert(positions.has_top_level_return(source))
end

--- An ordinary snake_case identifier assignment that happens to start
--- with the six letters `return` is not a `return` statement at all --
--- this project's own naming convention (D20) is full of names shaped
--- exactly like this one.
local function test_has_top_level_return_false_for_return_prefixed_assignment()
  local source = lines({
    "local function test_one()",
    "end",
    "",
    "return_code = 1",
  })
  assert(not positions.has_top_level_return(source))
end

--- A function call whose name starts with `return_` reads the same way
--- at column 0: `return_value(` also starts with the six letters
--- `return_`, but it is a call, never a `return` statement.
local function test_has_top_level_return_false_for_return_prefixed_call()
  local source = lines({ "return_value(x)" })
  assert(not positions.has_top_level_return(source))
end

--- `return(x)`, a genuine return of a parenthesized expression with no
--- space before the `(`, must still be flagged: the fix for the two
--- cases above must not overcorrect and swallow this legitimate one.
local function test_has_top_level_return_true_for_a_parenthesized_return()
  local source = lines({ "return(x)" })
  assert(positions.has_top_level_return(source))
end

local teal = require("build.teal")
local positions = require("build.positions")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Joins lines the way a real source file would read. Fixtures are
--- built from a table of plain string literals, assembled at run time,
--- rather than as a long-bracket literal sitting directly in THIS
--- file's own source: this file is itself a `_test.tl` module the real
--- importer discovers and parses, and a fixture string embedded here
--- as literal `[[...]]` text would put its own `local function
--- test_*` sample right into this file's real AST for the discovery
--- pass under test to find -- exactly the ambiguity `analyze`
--- no longer has to resolve, since a string built this way is never
--- anything but a "string" node's `conststr`, whichever implementation
--- reads it.
local function lines(parts: {string}): string
  return table.concat(parts, "\n") .. "\n"
end

--- `analyze` on `source`, asserting the parse itself succeeded, and
--- returning just its test names.
local function discover(source: string): {string}
  local found, err = positions.analyze(built, source, "fixture.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  return found.tests
end

--- `analyze` on `source`, asserting the parse succeeded, and returning
--- just its top-level-return fact.
local function has_return(source: string): boolean
  local found, err = positions.analyze(built, source, "fixture.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  return found.has_top_level_return
end

--- A `local function test_*` at the chunk's own top level is
--- discovered, in the order it appears.
local function test_discovers_top_level_tests()
  local source = lines({
    "local function test_one()",
    "end",
    "",
    "local function test_two()",
    "end",
  })
  local found = discover(source)
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
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_uses_helper")
end

--- A `local function test_*` declared inside another function is a
--- child of that OTHER function's own body, never a direct element of
--- the chunk's own top-level statement array, and is not a test some
--- other function happens to declare for itself.
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
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_top")
end

--- A module with no `local function test_*` at all discovers nothing.
local function test_discovers_nothing_when_there_is_no_test()
  local source = lines({ "local function helper()", "end" })
  local found = discover(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- A source SAMPLE held as a `[[...]]` long-bracket string parses to a
--- single "string" node, never a chunk-level statement of its own kind
--- -- its own `local function test_something()` text is never a
--- candidate for `analyze` to find at all, structurally, rather
--- than excluded by tracking where the bracket opens and closes.
local function test_ignores_a_fake_test_inside_a_plain_long_bracket()
  local source = lines({
    "local sample = [[",
    "local function test_something()",
    "  return 1",
    "end",
    "]]",
  })
  local found = discover(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- The same shape, but the bracket carries one `=` sign, `[=[...]=]`.
local function test_ignores_a_fake_test_inside_a_leveled_long_bracket()
  local source = lines({
    "local sample = [=[",
    "local function test_something()",
    "end",
    "]=]",
  })
  local found = discover(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- A long COMMENT parses to no statement at all -- tl's lexer consumes
--- it as a comment attached to the following token, so it never
--- reaches the parser as source text in the first place.
local function test_ignores_a_fake_test_inside_a_long_comment()
  local source = lines({
    "--[[",
    "local function test_something()",
    "end",
    "]]",
  })
  local found = discover(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- Discovery is not fooled by a string sample that precedes a real
--- test: a real test that follows one in the same file is still found.
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
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_real")
end

--- A string sample does not retroactively un-discover a real test that
--- came before it in the same file.
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
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_real")
end

--- An ordinary quoted string holding the same text as a plain literal,
--- on one line, parses to a "string" node either way; confirm this
--- still is not one.
local function test_ignores_a_quoted_string_naming_a_test()
  local source = lines({
    'local x = "local function test_x()"',
    "",
    "local function test_real()",
    "end",
  })
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_real")
end

--- A file with no top-level return has none to collide with a
--- generated tail.
local function test_has_top_level_return_false_when_absent()
  local source = lines({ "local function helper()", "end" })
  assert(not has_return(source))
end

--- A genuine top-level `return`, the file's own last statement.
local function test_has_top_level_return_true_for_a_real_one()
  local source = lines({
    "local function test_one()",
    "end",
    "",
    "return 0",
  })
  assert(has_return(source))
end

--- A `return` nested inside a function body is a child of that
--- function's own "statements" node, never a direct element of the
--- chunk's own top-level array.
local function test_has_top_level_return_false_when_only_nested()
  local source = lines({
    "local function helper()",
    "  return 1",
    "end",
  })
  assert(not has_return(source))
end

--- A `return` inside a long-bracket sample parses as part of a
--- "string" node's own text, not as a "return" statement.
local function test_has_top_level_return_false_inside_a_bracket()
  local source = lines({
    "local sample = [[",
    "return 0",
    "]]",
  })
  assert(not has_return(source))
end

--- A table constructor return is still a genuine top-level return:
--- `has_top_level_return` checks the statement's own `kind`, so what
--- the return's own expression happens to be shaped like never
--- matters, unlike a text pattern that has to special-case it.
local function test_has_top_level_return_true_for_a_table_constructor()
  local source = lines({ "return { 1, 2, 3 }" })
  assert(has_return(source))
end

--- A `return` immediately followed by a comment, with no value, is
--- still the chunk's genuine top-level return.
local function test_has_top_level_return_true_with_a_trailing_comment()
  local source = lines({ "return -- nothing to give back" })
  assert(has_return(source))
end

--- An ordinary snake_case identifier assignment that happens to start
--- with the six letters `return` parses to an `"assignment"` node, not
--- `"return"` -- there is no shared text prefix for a checker to get
--- wrong, unlike `%f[^%w_]` over raw source.
local function test_has_top_level_return_false_for_return_prefixed_assignment()
  local source = lines({
    "local function test_one()",
    "end",
    "",
    "return_code = 1",
  })
  assert(not has_return(source))
end

--- A function call whose name starts with `return_` parses to an
--- `"op"` (call) node, never `"return"`.
local function test_has_top_level_return_false_for_return_prefixed_call()
  local source = lines({ "return_value(x)" })
  assert(not has_return(source))
end

--- `return(x)`, a genuine return of a parenthesized expression with no
--- space before the `(`, must still be flagged: the two cases above
--- must not overcorrect and swallow this legitimate one.
local function test_has_top_level_return_true_for_a_parenthesized_return()
  local source = lines({ "return(x)" })
  assert(has_return(source))
end

--- `analyze` on `source`, asserting the parse succeeded, and returning
--- just its guidance catalog.
local function catalog(source: string): {positions.CatalogEntry}
  local found, err = positions.analyze(built, source, "fixture.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  return found.catalog
end

--- A top-level function whose doc comment carries a `guidance:` line
--- yields one entry per literal `return nil, ...` in its body, naming
--- the function, the message text, the guidance, and the return's line.
local function test_catalogs_a_guided_literal_failure()
  local source = lines({
    "--- Opens a thing.",
    "--- guidance: check the thing is there",
    "local function open_thing(): boolean, string",
    "  return nil, \"the thing was not found\"",
    "end",
  })
  local found = catalog(source)
  assert(#found == 1, "expected one entry, got " .. #found)
  assert(found[1].symbol == "open_thing", found[1].symbol)
  assert(found[1].message == "the thing was not found", found[1].message)
  assert(found[1].guidance == "check the thing is there", found[1].guidance)
  assert(found[1].line == 4, tostring(found[1].line))
end

--- Every comment line after the `guidance:` one joins the guidance,
--- space-separated, with the comment leaders stripped.
local function test_guidance_spans_the_remaining_comment_lines()
  local source = lines({
    "--- Opens a thing.",
    "--- guidance: check the thing is there,",
    "--- and that it is readable",
    "local function open_thing(): boolean, string",
    "  return nil, \"the thing was not found\"",
    "end",
  })
  local found = catalog(source)
  assert(#found == 1)
  assert(found[1].guidance == "check the thing is there, and that it is readable",
    found[1].guidance)
end

--- A function whose comments name no guidance contributes nothing,
--- however many literal failures it returns.
local function test_catalogs_nothing_without_guidance()
  local source = lines({
    "--- Opens a thing, with no guidance to offer.",
    "local function open_thing(): boolean, string",
    "  return nil, \"the thing was not found\"",
    "end",
  })
  assert(#catalog(source) == 0)
end

--- `return false, ...` is an honest failure too, and is catalogued the
--- same way.
local function test_catalogs_a_false_return()
  local source = lines({
    "--- guidance: retry later",
    "local function try_thing(): boolean, string",
    "  return false, \"the thing is busy right now\"",
    "end",
  })
  local found = catalog(source)
  assert(#found == 1)
  assert(found[1].message == "the thing is busy right now", found[1].message)
end

--- A concatenated message keeps its literal pieces and drops the
--- interpolated ones, so the entry holds exactly the text an error
--- would always contain.
local function test_message_keeps_only_the_literal_text()
  local source = lines({
    "--- guidance: check the path",
    "local function open_thing(path: string): boolean, string",
    "  return nil, \"could not open \" .. path .. \" for reading\"",
    "end",
  })
  local found = catalog(source)
  assert(#found == 1)
  assert(found[1].message == "could not open  for reading", found[1].message)
end

--- A message that reduces to too little literal text to anchor a match
--- is left out rather than shipped as a near-universal false hit.
local function test_drops_a_mostly_interpolated_message()
  local source = lines({
    "--- guidance: check the path",
    "local function open_thing(path: string): boolean, string",
    "  return nil, path .. \": \" .. describe()",
    "end",
    "--- guidance: check the index",
    "local function pick(index: integer): boolean, string",
    "  return nil, \"no \" .. tostring(index)",
    "end",
  })
  assert(#catalog(source) == 0)
end

--- A record function's symbol names its owner the way it was declared,
--- with `.` for a plain function and `:` for a method.
local function test_record_function_symbols_name_their_owner()
  local source = lines({
    "local record Thing",
    "end",
    "--- guidance: open it first",
    "function Thing.read(): boolean, string",
    "  return nil, \"the thing is not open\"",
    "end",
    "--- guidance: open it first",
    "function Thing:write(): boolean, string",
    "  return nil, \"the thing is not open for writing\"",
    "end",
  })
  local found = catalog(source)
  assert(#found == 2, "expected two entries, got " .. #found)
  assert(found[1].symbol == "Thing.read", found[1].symbol)
  assert(found[2].symbol == "Thing:write", found[2].symbol)
end

--- A failure returned from a nested block is found; one returned by a
--- function declared inside the guided one belongs to that inner
--- function's own comments, and is not attributed to the outer one.
local function test_walks_nested_blocks_but_not_inner_functions()
  local source = lines({
    "--- guidance: check both conditions",
    "local function open_thing(a: boolean): boolean, string",
    "  if a then",
    "    if not a then",
    "      return nil, \"the thing is deeply wrong\"",
    "    end",
    "  end",
    "  local function inner(): boolean, string",
    "    return nil, \"the inner thing is wrong\"",
    "  end",
    "  return inner()",
    "end",
  })
  local found = catalog(source)
  assert(#found == 1, "expected one entry, got " .. #found)
  assert(found[1].message == "the thing is deeply wrong", found[1].message)
  assert(found[1].line == 5, tostring(found[1].line))
end

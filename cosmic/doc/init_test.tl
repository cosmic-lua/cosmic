#!/usr/bin/env cosmic
-- test cosmic.doc module

local fs = require("cosmic.fs")
local doc = require("cosmic.doc")
local check = require("cosmic.check")

local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  fs.write(filepath, content)
  return filepath
end

-- Test parsing module-level doc comment
local function test_parse_module_doc()
  local source = [[--- This is the module description
--- It spans multiple lines
local x = 1
]]

  local result = doc.parse(source, "test.tl")
  assert(result.module_doc, "should extract module doc")
  assert(result.module_doc:find("module description"), "should contain description")
  assert(result.module_doc:find("multiple lines"), "should contain all lines")
end
test_parse_module_doc()

-- Test parsing function with doc comment
local function test_parse_function_doc()
  local source = [[
--- Add two numbers together
--- @param a number the first number
--- @param b number the second number
--- @return number the sum
local function add(a: number, b: number): number
  return a + b
end
]]

  local result = doc.parse(source, "test.tl")
  assert(#result.functions == 1, "should find one function")
  local fn = result.functions[1]
  assert(fn.name == "add", "function name should be 'add'")
  assert(fn.description:find("Add two numbers"), "should have description")
  assert(#fn.params == 2, "should have two params")
  assert(fn.params[1].name == "a", "first param should be 'a'")
  assert(fn.params[1].param_type == "number", "first param type should be 'number'")
  assert(#fn.returns == 1, "should have one return")
  assert(fn.returns[1].return_type == "number", "return type should be 'number'")
end
test_parse_function_doc()

-- Test parsing record
local function test_parse_record()
  local source = [[
--- A point in 2D space
local record Point
  x: number
  y: number
end
]]

  local result = doc.parse(source, "test.tl")
  assert(#result.records == 1, "should find one record")
  assert(result.records[1].name == "Point", "record name should be 'Point'")
  assert(result.records[1].description:find("2D space"), "should have description")
end
test_parse_record()

-- A keyword inside a field's doc comment must not close the record: an
-- "end" in a comment used to truncate Socket at that field, dropping
-- every later field from the docs. Identifiers like end_time must not
-- count either.
local function test_parse_record_keyword_in_comment()
  local source = [[
--- A stream endpoint.
local record Conn
  --- Returns bare nil at end of stream, per the record contract.
  recv: function(self: Conn): string | nil, string
  --- Ends after end_time elapses.
  deadline: function(self: Conn): integer
  close: function(self: Conn): boolean, string
end
]]

  local result = doc.parse(source, "test.tl")
  assert(#result.records == 1, "should find one record")
  local rec = result.records[1]
  assert(#rec.fields == 3, "expected 3 fields, got " .. #rec.fields)
  assert(rec.fields[3][1] == "close", "field after keyword comments should survive")
end
test_parse_record_keyword_in_comment()

-- Keywords inside string literals (nested enum values) and long comments
-- must not close the record either.
local function test_parse_record_keyword_in_strings_and_long_comments()
  local source = [[
--- Connection settings.
local record Config
  --[==[ a long comment: end record enum ]==]
  enum Mode
    "fast end"
    "safe \"end\" mode"
  end
  mode: Mode
  retries: integer
end
]]
  source = source:gsub("%[==%[", "[["):gsub("%]==%]", "]]")

  local result = doc.parse(source, "test.tl")
  assert(#result.records >= 1, "should find the record")
  local rec = result.records[1]
  local last = rec.fields[#rec.fields]
  assert(last and last[1] == "retries", "fields after strings/comments should survive")
end
test_parse_record_keyword_in_strings_and_long_comments()

-- A `local type Name = target` alias is a public name whose fields live
-- on the target (zip's Archive = cosmo.zip.Reader): it must render as a
-- Types entry with the target resolved through the file's requires.
local function test_parse_type_alias_points_at_target()
  local source = [[
local zip = require("gen.zip")

--- Reader for extracting files from an archive.
local type Archive = zip.Reader
]]

  local result = doc.parse(source, "test.tl")
  assert(#result.records == 1, "alias should produce a Types entry")
  local rec = result.records[1]
  assert(rec.name == "Archive", "alias name")
  assert(rec.description:find("extracting files", 1, true), "keeps its doc comment")
  assert(rec.description:find("alias of `gen.zip.Reader`", 1, true),
    "resolves the local require binding: " .. rec.description)
  assert(rec.description:find("cosmic --docs gen.zip.Reader", 1, true),
    "points at the target's own docs")
end
test_parse_type_alias_points_at_target()

-- Test parsing Example_* functions
local function test_parse_example()
  local source = [[
local function Example_basic()
  print("hello")
  -- Output:
  -- hello
end
]]

  local result = doc.parse(source, "test.tl")
  assert(#result.examples == 1, "should find one example")
  assert(result.examples[1].name == "Example_basic", "example name should match")
  -- doc.parse extracts output with trailing newline from comment lines
  assert(result.examples[1].expected_output:match("^hello"), "should extract expected output")
end
test_parse_example()

-- Every line of a multi-line Output block must lose its `-- ` prefix:
-- `.` matches newlines in Lua patterns, so the extraction used to take
-- the whole rest of the body as line one and leave later lines raw.
local function test_parse_example_multiline_output()
  local source = [[
local function Example_multi()
  print("a")
  print("b:", 1)
  -- Output:
  -- a
  -- b:	1
end
]]

  local result = doc.parse(source, "test.tl")
  assert(#result.examples == 1, "should find one example")
  local got = result.examples[1].expected_output
  assert(got == "a\nb:\t1", "prefixes stripped on every line, got: " .. string.format("%q", got))
end
test_parse_example_multiline_output()

-- Test that regular `--` comments (not `---`) directly above an
-- Example_* function are picked up as its description: doc.parse is
-- the one caller that passes allow_regular_comments=true to
-- extract_doc_comment.
local function test_example_regular_comment_description()
  local source = [[
local unrelated = 1

-- part of the example doc
-- second line
local function Example_annotated()
  print("hi")
end
]]
  local result = doc.parse(source, "test.tl")
  assert(#result.examples == 1, "should find one example")
  assert(result.examples[1].description, "should have a description")
  assert(result.examples[1].description:find("part of the example doc", 1, true),
    "should pick up the regular -- comment: " .. (result.examples[1].description or ""))
  -- A blank line above the comment block stops the walk without error.
  assert(not result.examples[1].description:find("unrelated", 1, true),
    "should not reach past the blank line above the comment block")
end
test_example_regular_comment_description()

-- Same, but the comment block is directly preceded by a non-blank,
-- non-comment line (the other way extract_doc_comment's upward walk
-- stops when allow_regular_comments is true).
local function test_example_regular_comment_stops_at_code()
  local source = [[
local unrelated = 1
-- part of the example doc
local function Example_annotated2()
  print("hi")
end
]]
  local result = doc.parse(source, "test.tl")
  assert(#result.examples == 1, "should find one example")
  assert(result.examples[1].description, "should have a description")
  assert(result.examples[1].description:find("part of the example doc", 1, true),
    "should pick up the regular -- comment: " .. (result.examples[1].description or ""))
  assert(not result.examples[1].description:find("unrelated", 1, true),
    "should stop at the preceding code line")
end
test_example_regular_comment_stops_at_code()

-- Test that Example_* functions are not included in regular functions
local function test_example_not_in_functions()
  local source = [[
local function Example_foo()
  print("test")
end

local function real_function()
  return 42
end
]]

  local result = doc.parse(source, "test.tl")
  assert(#result.functions == 1, "should only find one regular function")
  assert(result.functions[1].name == "real_function", "should be the non-example function")
  assert(#result.examples == 1, "should find one example")
end
test_example_not_in_functions()

-- Test that a variable/local named with a keyword prefix (`end_time`)
-- is not lexed as the keyword `end`: a bare `%a+` word match stops at
-- the `_`, so the scanner used to close the body right there.
local function test_example_end_time_not_truncated()
  local source = [[
local function Example_time_tracking()
  local start_time = 1
  local end_time = 2
  local elapsed = end_time - start_time
  print(elapsed)
end
]]
  local result = doc.parse(source, "test.tl")
  assert(#result.examples == 1, "should find one example")
  assert(result.examples[1].body:find("elapsed", 1, true),
    "body should include the statement after end_time, not stop early")
end
test_example_end_time_not_truncated()

-- Test that a variable named with a block-opening keyword prefix
-- (`for_each`) is not lexed as `for`: that would open a phantom nesting
-- level, needing an extra `end` to close and swallowing whatever
-- example comes next.
local function test_example_for_each_prefix_not_over_extended()
  local source = [[
local function Example_for_each()
  local for_each = function(t) return #t end
  print(for_each({1, 2, 3}))
end

local function Example_after_for_each()
  print("after")
end
]]
  local result = doc.parse(source, "test.tl")
  assert(#result.examples == 2, "should find two separate examples, not merge them")
  assert(result.examples[1].name == "Example_for_each", "first example name")
  assert(result.examples[2].name == "Example_after_for_each", "second example name")
  assert(not result.examples[1].body:find("Example_after_for_each", 1, true),
    "for_each's body must not swallow the next example")
end
test_example_for_each_prefix_not_over_extended()

-- Test that a bare `do ... end` block (not attached to a for/while)
-- opens its own nesting level: `do` was missing from the depth-tracking
-- keyword set, so its `end` was mistaken for the function's own.
local function test_example_bare_do_end_block()
  local source = [[
local function Example_bare_do()
  do
    local x = 1
  end
  print(x or "after do")
end

local function Example_after_do()
  print("later")
end
]]
  local result = doc.parse(source, "test.tl")
  assert(#result.examples == 2, "should find two examples")
  assert(result.examples[1].body:find("after do", 1, true),
    "body should include the statement after the bare do-block")
  assert(result.examples[2].name == "Example_after_do", "next example parsed separately")
end
test_example_bare_do_end_block()

-- Test a nested (anonymous) function definition inside the example
-- body: unaffected by either bug, but a regression guard for the
-- shared scanner now that all three extractors share it.
local function test_example_nested_function_definition()
  local source = [[
local function Example_nested_fn()
  local adder = function(a, b)
    return a + b
  end
  print(adder(1, 2))
end
]]
  local result = doc.parse(source, "test.tl")
  assert(#result.examples == 1, "should find one example")
  assert(result.examples[1].body:find("adder%(1, 2%)"),
    "body should include the statement after the nested function")
end
test_example_nested_function_definition()

-- Test render produces markdown
local function test_render_markdown()
  local source = [[--- Test module
local record Foo
  x: number
end

local function Example_usage()
  print("hello")
  -- Output:
  -- hello
end
]]

  local result = doc.parse(source, "mymodule.tl")
  local md = doc.render(result)
  assert(md:find("# mymodule"), "should have module header")
  assert(md:find("Test module"), "should have module description")
  assert(md:find("## Types"), "should have Types section")
  assert(md:find("### Foo"), "should have Foo record")
  assert(md:find("## Examples"), "should have Examples section")
  assert(md:find("```teal"), "should have teal code block")
end
test_render_markdown()

-- Test render_file with valid file
local function test_render_file()
  local input = write_temp("doc_test.tl", [[--- A test file
local function helper()
  return 1
end
]])
  local md = check.must(doc.render_file(input), "render_file should succeed")
  assert(md:find("# doc_test"), "should have filename as header")
  assert(md:find("A test file"), "should have module doc")
end
test_render_file()

-- Test render_file with missing file
local function test_render_file_missing()
  local md, err = doc.render_file("/nonexistent/file.tl")
  assert(md == nil, "render_file should fail on missing file")
  assert(err:find("cannot open"), "should have error message")
end
test_render_file_missing()

-- Note: --doc CLI flag has been removed. Use the doc.render_file() function directly
-- for build-time documentation generation.

-- Test function without doc comment
local function test_function_no_doc()
  local source = [[
local function undocumented()
  return 42
end
]]

  local result = doc.parse(source, "test.tl")
  assert(#result.functions == 1, "should find function")
  assert(result.functions[1].description == nil, "should have no description")
  assert(#result.functions[1].params == 0, "should have no params")
end
test_function_no_doc()

-- Test multiple functions
local function test_multiple_functions()
  local source = [[
--- First function
local function first()
end

--- Second function
local function second()
end
]]

  local result = doc.parse(source, "test.tl")
  assert(#result.functions == 2, "should find two functions")
  assert(result.functions[1].name == "first", "first function")
  assert(result.functions[2].name == "second", "second function")
end
test_multiple_functions()

-- Test example title conversion
local function test_example_title()
  local source = [[
local function Example_foo_bar_baz()
  print("test")
end
]]

  local result = doc.parse(source, "test.tl")
  local md = doc.render(result)
  assert(md:find("### foo bar baz"), "should convert underscores to spaces in title")
end
test_example_title()

-- Test that actual library files have proper documentation
-- These tests verify that our source files have doc comments
local function test_embed_has_module_doc()
  local md = check.must(doc.render_file("cosmic/embed/init.tl"), "should read embed/init.tl")
  -- Module should have a description after the header
  assert(md:find("# embed\n\n[^#]"), "embed/init.tl should have module description")
end
test_embed_has_module_doc()

local function test_embed_has_type_descriptions()
  -- EmbedResult is declared in the extraction half; init.tl aliases it.
  local md = check.must(doc.render_file("cosmic/embed/extract.tl"), "should read embed/extract.tl")
  -- EmbedResult should have a description, not just a bare header
  assert(md:find("### EmbedResult\n\n[^#]"), "EmbedResult should have description")
end
test_embed_has_type_descriptions()

local function test_child_has_type_descriptions()
  local md = check.must(doc.render_file("cosmic/child/init.tl"), "should read child/init.tl")
  -- Handle should have a description
  assert(md:find("### Handle\n\n[^#]"), "Handle should have description")
end
test_child_has_type_descriptions()

local function test_fetch_has_module_description()
  local md = check.must(doc.render_file("cosmic/fetch/init.tl"), "should read fetch/init.tl")
  -- Module should have a description after the header
  assert(md:find("# fetch\n\n[^#]"), "fetch.tl should have module description")
  -- Should describe what it does
  assert(md:find("HTTP fetch"), "should describe HTTP fetching")
end
test_fetch_has_module_description()

-- Test that record field parser skips comment lines (bug 2 regression test)
local function test_record_fields_skip_comments()
  local source = [[
local record Foo
  --- Some description.
  --- @return function Iterator yielding (fd: number, events: Bar)
  wait: function(Foo, number): function(): number, Bar
  bar: string
end
]]
  local result = doc.parse(source, "test.tl")
  assert(#result.records == 1, "should find one record")
  local rec = result.records[1]
  -- Should only find 'wait' and 'bar', NOT 'fd' from inside the comment
  local field_names: {string} = {}
  for _, f in ipairs(rec.fields) do
    table.insert(field_names, f[1])
  end
  local names_str = table.concat(field_names, ",")
  assert(not names_str:find("fd"), "should not parse 'fd' from inside comment (got: " .. names_str .. ")")
  assert(names_str:find("wait"), "should find 'wait' field")
  assert(names_str:find("bar"), "should find 'bar' field")
  print("test_record_fields_skip_comments: PASS")
end
test_record_fields_skip_comments()

print("All doc tests passed!")

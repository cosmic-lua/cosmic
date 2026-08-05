#!/usr/bin/env cosmic
-- test cosmic.example module

local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local example = require("cosmic.example")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  fs.write(filepath, content)
  return filepath
end

-- Test parsing examples from source
local function test_parse_examples()
  local source = [[
local function Example_basic()
  print("hello")
  -- Output:
  -- hello
end
]]

  local examples = example.parse_examples(source)
  assert(#examples == 1, "should find one example")
  assert(examples[1].name == "Example_basic", "name should match")
  -- expected_output includes trailing newline from parsing
  assert(examples[1].expected_output:match("^hello"), "should extract expected output")
end
test_parse_examples()

-- Test parsing multiple examples
local function test_parse_multiple_examples()
  local source = [[
local function Example_first()
  print("one")
  -- Output:
  -- one
end

local function Example_second()
  print("two")
  -- Output:
  -- two
end
]]

  local examples = example.parse_examples(source)
  assert(#examples == 2, "should find two examples")
  assert(examples[1].name == "Example_first", "first example name")
  assert(examples[2].name == "Example_second", "second example name")
end
test_parse_multiple_examples()

-- Test example without output (skip)
local function test_example_no_output()
  local source = [[
local function Example_no_check()
  print("anything")
end
]]

  local examples = example.parse_examples(source)
  assert(#examples == 1, "should find example")
  assert(examples[1].expected_output == nil, "should have no expected output")
end
test_example_no_output()

-- Test that a variable/local named with a keyword prefix (`end_time`)
-- is not lexed as the keyword `end`: a bare `%a+` word match stops at
-- the `_`, so the scanner used to close the body right there.
local function test_end_time_not_truncated()
  local source = [[
local function Example_time_tracking()
  local start_time = 1
  local end_time = 2
  local elapsed = end_time - start_time
  print(elapsed)
  -- Output:
  -- 1
end
]]
  local examples = example.parse_examples(source)
  assert(#examples == 1, "should find one example")
  assert(examples[1].body:find("elapsed", 1, true),
    "body should include the statement after end_time, not stop early")
end
test_end_time_not_truncated()

-- Test that a variable named with a block-opening keyword prefix
-- (`for_each`) is not lexed as `for`: that would open a phantom nesting
-- level, needing an extra `end` to close and swallowing whatever
-- example comes next.
local function test_for_each_prefix_not_over_extended()
  local source = [[
local function Example_for_each()
  local for_each = function(t) return #t end
  print(for_each({1, 2, 3}))
  -- Output:
  -- 3
end

local function Example_after_for_each()
  print("after")
  -- Output:
  -- after
end
]]
  local examples = example.parse_examples(source)
  assert(#examples == 2, "should find two separate examples, not merge them")
  assert(examples[1].name == "Example_for_each", "first example name")
  assert(examples[2].name == "Example_after_for_each", "second example name")
  assert(not examples[1].body:find("Example_after_for_each", 1, true),
    "for_each's body must not swallow the next example")
end
test_for_each_prefix_not_over_extended()

-- Test that a bare `do ... end` block (not attached to a for/while)
-- opens its own nesting level: `do` was missing from the depth-tracking
-- keyword set, so its `end` was mistaken for the function's own.
local function test_bare_do_end_block()
  local source = [[
local function Example_bare_do()
  do
    local x = 1
  end
  print(x or "after do")
  -- Output:
  -- after do
end

local function Example_after_do()
  print("later")
  -- Output:
  -- later
end
]]
  local examples = example.parse_examples(source)
  assert(#examples == 2, "should find two examples")
  assert(examples[1].body:find("after do", 1, true),
    "body should include the statement after the bare do-block")
  assert(examples[2].name == "Example_after_do", "next example parsed separately")
end
test_bare_do_end_block()

-- Test a nested (anonymous) function definition inside the example
-- body: unaffected by either bug, but a regression guard for the
-- shared scanner now that all three extractors share it.
local function test_nested_function_definition()
  local source = [[
local function Example_nested_fn()
  local adder = function(a, b)
    return a + b
  end
  print(adder(1, 2))
  -- Output:
  -- 3
end
]]
  local examples = example.parse_examples(source)
  assert(#examples == 1, "should find one example")
  assert(examples[1].body:find("adder%(1, 2%)"),
    "body should include the statement after the nested function")
end
test_nested_function_definition()

-- Test running passing example
local function test_run_passing()
  local input = write_temp("pass.tl", [[
local function Example_pass()
  print("hello")
  -- Output:
  -- hello
end
]])
  local result = example.run(input)
  assert(result.exit_code == 0, "should pass")
  assert(#result.results == 1, "should have one result")
  assert(result.results[1].passed, "example should pass")
end
test_run_passing()

-- Test running failing example
local function test_run_failing()
  local input = write_temp("fail.tl", [[
local function Example_fail()
  print("wrong")
  -- Output:
  -- expected
end
]])
  local result = example.run(input)
  assert(result.exit_code == 1, "should fail")
  assert(#result.results == 1, "should have one result")
  assert(not result.results[1].passed, "example should fail")
end
test_run_failing()

-- Test file with no examples (skip)
local function test_run_no_examples()
  local input = write_temp("none.tl", [[
local function regular_function()
  return 42
end
]])
  local result = example.run(input)
  assert(result.exit_code == 2, "should return skip code")
  assert(#result.results == 0, "should have no results")
end
test_run_no_examples()

-- Test missing file
local function test_run_missing_file()
  local result = example.run("/nonexistent/file.tl")
  assert(result.exit_code == 1, "should fail")
  assert(string.find(result.error or "", "cannot open"), "should have error message")
end
test_run_missing_file()

-- Test cosmic --check example command passing
local function test_cosmic_example_pass()
  local input = write_temp("cmd_pass.tl", [[
local function Example_cmd()
  print("works")
  -- Output:
  -- works
end
]])
  local h = check.must(spawn.spawn({cosmic, "--check", "example", input}))
  local __r1 = check.must(h:wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic --check example should succeed")
  assert(out:find("PASS"), "output should show PASS")
end
test_cosmic_example_pass()

-- Test cosmic --check example command failing
local function test_cosmic_example_fail()
  local input = write_temp("cmd_fail.tl", [[
local function Example_cmd()
  print("actual")
  -- Output:
  -- expected
end
]])
  local h = check.must(spawn.spawn({cosmic, "--check", "example", input}))
  local __r2 = check.must(h:wait())
  local ok, out = __r2.ok, __r2.stdout
  assert(not ok, "cosmic --check example should fail")
  assert(out:find("FAIL"), "output should show FAIL")
end
test_cosmic_example_fail()

-- Test cosmic --check example with skip
local function test_cosmic_example_skip()
  local input = write_temp("cmd_skip.tl", [[
local x = 1
]])
  local r = check.must(spawn.run({cosmic, "--check", "example", input}))
  assert(r.code == 2, "should return skip code 2")
  assert(r.stdout:find("SKIP"), "output should show SKIP")
end
test_cosmic_example_skip()

-- Test multiline output
local function test_multiline_output()
  local input = write_temp("multi.tl", [[
local function Example_multi()
  print("line1")
  print("line2")
  -- Output:
  -- line1
  -- line2
end
]])
  local result = example.run(input)
  assert(result.exit_code == 0, "should pass")
  assert(result.results[1].passed, "multiline example should pass")
end
test_multiline_output()

-- Test blank lines in output
local function test_blank_line_in_output()
  local input = write_temp("blank.tl", [[
local function Example_blank()
  print("before")
  print("")
  print("after")
  -- Output:
  -- before
  --
  -- after
end
]])
  local result = example.run(input)
  assert(result.exit_code == 0, "should pass with blank line: " .. (result.results[1].error or ""))
  assert(result.results[1].passed, "blank line example should pass")
  assert(result.results[1].expected:find("\n\n"), "expected should contain blank line")
end
test_blank_line_in_output()

-- Test trailing newline normalization
local function test_trailing_newline()
  local input = write_temp("newline.tl", [[
local function Example_newline()
  io.write("no newline")
  -- Output:
  -- no newline
end
]])
  local result = example.run(input)
  assert(result.exit_code == 0, "should pass with normalized newlines")
end
test_trailing_newline()

-- Test example with nested blocks
local function test_nested_blocks()
  local input = write_temp("nested.tl", [[
local function Example_nested()
  for i = 1, 2 do
    if i == 1 then
      print("first")
    end
  end
  -- Output:
  -- first
end
]])
  local result = example.run(input)
  assert(result.exit_code == 0, "should handle nested blocks")
end
test_nested_blocks()

-- Test format_results output
local function test_format_results()
  local input = write_temp("format.tl", [[
local function Example_fmt()
  print("test")
  -- Output:
  -- test
end
]])
  local result = example.run(input)
  local formatted = example.format_results(input, result)
  assert(formatted:find("Example_fmt"), "should contain example name")
  assert(formatted:find("PASS"), "should show PASS status")
end
test_format_results()

-- Test example with runtime error
local function test_runtime_error()
  local input = write_temp("error.tl", [[
local function Example_error()
  error("intentional error")
  -- Output:
  -- never reached
end
]])
  local result = example.run(input)
  assert(result.exit_code == 1, "should fail on runtime error")
  assert(string.find(result.results[1].error or "", "runtime error"), "should capture error")
end
test_runtime_error()

print("All example tests passed!")

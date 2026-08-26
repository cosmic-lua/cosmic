local check = require("cosmic.check")
local env = require("cosmic.env")
local test = require("cosmic.test")

local type Case = test.Case
local type Options = test.Options

--- Run `main` with its stdout captured.
--- `main` writes through `io.write` and never through `print`, so
--- swapping that one function collects everything it emits.
--- @param cases {Case} The cases to hand the runner
--- @param opts Options? The runner's options
--- @return integer The exit code the runner returned
--- @return string Everything it wrote
local function capture(cases: {Case}, opts?: Options): integer, string
  local chunks: {string} = {}
  local old_write = io.write
  local function capture_write(...: any): FILE, string, integer
    for _, v in ipairs({...}) do
      chunks[#chunks + 1] = tostring(v)
    end
    return io.stdout
  end
  -- `main` is contracted never to throw, and the pcall is what makes a
  -- broken contract report as one failing test instead of swallowing
  -- every later line this file writes. The code is assigned through an
  -- upvalue so it stays an integer: pcall's second slot is `any`.
  local code = -1
  io.write = capture_write
  -- The wrapper returns a string so pcall types its second slot as one.
  local ok, err = pcall(function(): string
      code = test.main(cases, opts)
      return ""
    end)
  io.write = old_write
  check.truthy(ok, "main threw: " .. tostring(err))
  return code, table.concat(chunks)
end

--- The last line of `text`, ignoring its trailing newline.
--- @param text string The captured output
--- @return string The last non-empty line, "" when there is none
local function last_line(text: string): string
  local lines: {string} = {}
  for line in text:gmatch("([^\n]+)") do
    lines[#lines + 1] = line
  end
  return lines[#lines] or ""
end

local function test_every_case_runs_past_a_failure()
  local ran: {string} = {}
  local code, out = capture({
      {name = "test_first", fn = function() ran[#ran + 1] = "first" end},
      {name = "test_middle", fn = function() error("boom") end},
      {name = "test_last", fn = function() ran[#ran + 1] = "last" end},
    })
  check.equal(code, 1, "a failing case fails the file")
  check.equal(#ran, 2, "the case after the failure still ran")
  check.equal(ran[2], "last", "and it ran last")
  check.truthy(out:find("test_middle", 1, true),
    "the output names the failing case: " .. out)
  check.equal(last_line(out), "3 checks: 2 passed, 1 failed", out)
end
test_every_case_runs_past_a_failure()

local function test_all_passing_returns_zero()
  local code, out = capture({
      {name = "test_a", fn = function() end},
      {name = "test_b", fn = function() end},
    })
  check.equal(code, 0, "every case passed")
  check.equal(last_line(out), "2 checks: 2 passed", out)
  check.truthy(not out:find("✗", 1, true), "nothing failed: " .. out)
end
test_all_passing_returns_zero()

local function test_failure_output_names_the_function_and_carries_a_traceback()
  local _code, out = capture({
      {name = "test_thrower", fn = function() error("the reason") end},
    })
  check.truthy(out:find("✗ test_thrower\n", 1, true),
    "the failure row names the function: " .. out)
  check.truthy(out:find("    ", 1, true), "the detail is indented: " .. out)
  check.truthy(out:find("the reason", 1, true),
    "the thrown message survives: " .. out)
  -- A test runs as the compiled chunk, so the frames name
  -- `o/cosmic/test_test.lua` rather than the `.tl` it came from.
  check.truthy(out:find("stack traceback:", 1, true),
    "the failure carries a traceback: " .. out)
  check.truthy(out:find("test_test", 1, true),
    "and its frames name this file: " .. out)
end
test_failure_output_names_the_function_and_carries_a_traceback()

local function test_source_order_is_run_order()
  local ran: {string} = {}
  local names = {"test_zulu", "test_alpha", "test_mike"}
  local cases: {Case} = {}
  for _, name in ipairs(names) do
    cases[#cases + 1] = {
      name = name,
      fn = function() ran[#ran + 1] = name end,
    }
  end
  local code = capture(cases)
  check.equal(code, 0, "all three passed")
  check.equal(table.concat(ran, ","), table.concat(names, ","),
    "the runner never reorders")
end
test_source_order_is_run_order()

local function test_empty_case_list_is_a_skip()
  local code, out = capture({})
  check.equal(code, 2, "a file with no tests is a skip, not a pass")
  check.equal(out, "0 checks: 0 passed\n", out)
end
test_empty_case_list_is_a_skip()

local function test_filter_selects_by_substring()
  local ran: {string} = {}
  local code, out = capture({
      {name = "test_alpha", fn = function() ran[#ran + 1] = "alpha" end},
      {name = "test_beta", fn = function() ran[#ran + 1] = "beta" end},
      {name = "test_gamma", fn = function() ran[#ran + 1] = "gamma" end},
    }, {filter = "beta"})
  check.equal(code, 0, "the selected case passed")
  check.equal(table.concat(ran, ","), "beta", "only the match ran")
  check.equal(last_line(out), "1 checks: 1 passed", out)
end
test_filter_selects_by_substring()

local function test_filter_matching_nothing_is_a_skip()
  local code, out = capture({
      {name = "test_alpha", fn = function() end},
      {name = "test_beta", fn = function() end},
    }, {filter = "nowhere"})
  check.equal(code, 2, "a filter that matched nothing ran nothing")
  check.truthy(out:find("no tests matching 'nowhere' (found 2 total)", 1, true),
    "the skip says what was asked for: " .. out)
  check.equal(last_line(out), "0 checks: 0 passed", out)
end
test_filter_matching_nothing_is_a_skip()

local function test_the_env_var_is_the_filter_when_no_option_is_passed()
  local cases: {Case} = {
    {name = "test_alpha", fn = function() end},
    {name = "test_beta", fn = function() end},
  }

  check.must(env.set("COSMIC_TEST_FILTER", "alpha", true))
  local code, out = capture(cases)
  check.equal(code, 0, "the environment narrowed the run")
  check.equal(last_line(out), "1 checks: 1 passed", out)

  -- An exported-but-empty variable is no filter, not one that matches
  -- everything: a runner that sets it unconditionally must not change
  -- what runs.
  check.must(env.set("COSMIC_TEST_FILTER", "", true))
  local both_code, both_out = capture(cases)
  check.equal(both_code, 0, "both cases passed")
  check.equal(last_line(both_out), "2 checks: 2 passed", both_out)

  check.must(env.unset("COSMIC_TEST_FILTER"))
  check.truthy(env.get("COSMIC_TEST_FILTER") == nil, "the variable is gone")
end
test_the_env_var_is_the_filter_when_no_option_is_passed()

local function test_an_explicit_filter_beats_the_environment()
  check.must(env.set("COSMIC_TEST_FILTER", "alpha", true))
  local code, out = capture({
      {name = "test_alpha", fn = function() end},
      {name = "test_beta", fn = function() end},
    }, {filter = "beta"})
  check.must(env.unset("COSMIC_TEST_FILTER"))
  check.equal(code, 0, "the option's case passed")
  check.equal(last_line(out), "1 checks: 1 passed", out)
end
test_an_explicit_filter_beats_the_environment()

local function test_a_failing_case_does_not_leak_io_write()
  local before = io.write
  local _code = capture({
      {name = "test_thrower", fn = function() error("boom") end},
    })
  check.equal(io.write, before, "io.write is the real one again")
end
test_a_failing_case_does_not_leak_io_write()

print("all test-runner tests passed")

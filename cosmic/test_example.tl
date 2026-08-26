--- Examples for the cosmic.test module.
--- Demonstrates running an ordered list of cases in process: source
--- order is run order, and the return value is the exit code the caller
--- grades by.

-- Example_main runs two cases in the order given and reports on them.
-- A case that returns has passed; one that throws is recorded and the
-- run continues to the next.
local function Example_main()
  local test = require("cosmic.test")
  local code = test.main({
      {name = "test_addition", fn = function() assert(1 + 1 == 2) end},
      {name = "test_subtraction", fn = function() assert(2 - 1 == 1) end},
    })
  print("exit", code)
  -- Output:
  -- 2 checks: 2 passed
  -- exit	0
end

-- Example_filter narrows a run to the cases whose names contain a
-- substring. Nothing matching is a skip (exit 2), never a silent pass.
local function Example_filter()
  local test = require("cosmic.test")
  local cases: {test.Case} = {
    {name = "test_alpha", fn = function() end},
    {name = "test_beta", fn = function() end},
  }
  print("filtered", test.main(cases, {filter = "beta"}))
  print("no match", test.main(cases, {filter = "gamma"}))
  -- Output:
  -- 1 checks: 1 passed
  -- filtered	0
  -- no tests matching 'gamma' (found 2 total)
  -- 0 checks: 0 passed
  -- no match	2
end

-- Suppress unused warnings for examples
local _ = {Example_main, Example_filter}

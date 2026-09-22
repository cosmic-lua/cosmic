local Result = require("cosmic_ci.result")

local record Case
  name: string
  output: string
  ok: boolean
  timed: boolean
  signal: integer | nil
  code: integer | nil
  expected: boolean
end

local function test_fresh_test_result_table()
  local cases: {Case} = {
    { name = "pass", output = "test: PASS (2 tests, 1 modules; 2 ran, 0 stood, 31 ms)\ntest: coverage 50%\n", ok = true, timed = false, code = 0, expected = true },
    { name = "stood", output = "test: PASS (1 ms; 2 ran, 1 stood)", ok = true, timed = false, code = 0, expected = false },
    { name = "zero", output = "test: PASS (1 ms; 0 ran, 0 stood)", ok = true, timed = false, code = 0, expected = false },
    { name = "malformed", output = "PASS", ok = true, timed = false, code = 0, expected = false },
    { name = "junk suffix", output = "test: PASS (1 ms; 2 ran, 0 stood garbage)", ok = true, timed = false, code = 0, expected = false },
    { name = "timeout", output = "", ok = false, timed = true, expected = false },
    { name = "signal", output = "", ok = false, timed = false, signal = 15, expected = false },
    { name = "exit", output = "", ok = false, timed = false, code = 23, expected = false },
  }
  for _, case in ipairs(cases) do
    local verdict = Result.fresh(case.output, case.ok, case.timed,
      case.signal, case.code)
    assert(verdict.ok == case.expected, "unexpected verdict for " .. case.name)
  end
end

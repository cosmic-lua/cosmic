--- What the tests of Seatbelt's hold on a child share
--- (cosmic/child_seatbelt_*_test.tl and cosmic/child_relay_seatbelt_test.tl):
--- the skip off macOS and the system log's account of what was denied. Test
--- support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")

local record seatbelt_fixture
end

--- Ends the test where Seatbelt does not hold `held`.
--- @param held what Seatbelt holds in the test's subject, a child where nil
function seatbelt_fixture.macos_only(held?: string)
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("Seatbelt holds " .. (held or "a child") .. " on macOS alone")
  end
end

--- What Seatbelt denied lately, as the system's log names it, which says
--- what a profile lacks. Empty where the log cannot be read.
-- TODO: bound the `log show` well under the time left to the test: its
-- 60 s outlasts the test's 10 s timeout, so a check that fails on a busy
-- runner can lose its message to the timeout.
--- @param window how far back `log show` reads, as its `--last` takes it; "1m" where nil
--- @return "\nlog: " and the last 60 lines of the log
function seatbelt_fixture.denials(window?: string): string
  local result, _ = Child.run({ "/usr/bin/log", "show", "--last", window or "1m", "--style", "compact",
    "--predicate", "eventMessage CONTAINS \"Sandbox: \"" },
    { stdout = "capture", stderr = "capture", stdin = "null", timeout_ns = Clock.seconds(60) })
  if result == nil then return "" end
  local lines: mut {string} = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
  return "\nlog: " .. table.concat(lines, "\n", math.max(1, #lines - 60), #lines)
end

return seatbelt_fixture

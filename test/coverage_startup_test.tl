--- A test worker collects Lua coverage from its first instruction:
--- COSMIC_COVERAGE_STARTUP, which the runner sets, keeps what ran before
--- the first window could open -- the command line's dispatch and every
--- module it loads -- in that first window. The core consumes the name
--- before any Lua runs, so the program never sees it. Run in fresh
--- processes, since this test's own worker opened its first window long
--- ago.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- Runs a script whose own line 4 runs only while it loads, then prints
--- whether the name was visible and whether the first and second
--- windows each hold that line.
local function windows(tmp: string, startup: boolean): string
  local dir = tmp .. (startup and "/startup" or "/plain")
  assert(Fs.mkdirs(dir))
  assert(Fs.write(dir .. "/windows.tl", [[
local Coverage = require("cosmic.coverage")
local Env = require("cosmic.env")

local loaded = true

local function holds_load_line(): string
  local session = assert(Coverage.start())
  local hits = assert(Coverage.stop(session))
  return (hits["windows"] or {})[4] and "held" or "missed"
end

return function(): integer
  assert(loaded)
  local seen = Env.get("COSMIC_COVERAGE_STARTUP") ~= nil and "seen" or "unseen"
  local first = holds_load_line()
  print(seen, first, holds_load_line())
  return 0
end
]]))
  local env = Env.all()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  env.COSMIC_COVERAGE_STARTUP = startup and "1" or nil
  local r = assert(Child.run({ assert(Proc.executable()), "windows.tl" },
    { env = env, cwd = dir, stdout = "capture", stderr = "capture",
      timeout_ms = 30000 }))
  assert(r.ok, tostring(r.stderr))
  return assert(r.stdout)
end

local function test_startup_collection_keeps_load_lines_in_the_first_window(tmp: string)
  local out = windows(tmp, true)
  assert(out == "unseen\theld\tmissed\n", "unexpected: " .. out)
end

local function test_without_it_load_lines_are_never_seen(tmp: string)
  local out = windows(tmp, false)
  assert(out == "unseen\tmissed\tmissed\n", "unexpected: " .. out)
end

--- The core's own C in coverage. A core built with native coverage --
--- every release core and the sanitized one -- answers every C line a
--- block begins on and puts hits on those lines; any other core answers
--- none, and its hits never name a C file.

local Child = require("cosmic.child")
local Coverage = require("cosmic.coverage")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local function is_core_c(path: string): boolean
  return path:match("^core/[%w_]+%.[ch]$") ~= nil
end

local function test_native_lines_are_core_c_files()
  for path, lines in pairs(Coverage.native_lines()) do
    assert(is_core_c(path), "not a core C path: " .. path)
    for line, observable in pairs(lines) do
      assert(line > 0 and observable == true, path .. ": bad line " .. tostring(line))
    end
  end
end

local function test_c_hits_land_on_native_lines()
  -- Hashing runs core/crypto.c inside this test's own window.
  assert(#Hash.sha256("coverage") == 32)
  local observable = Coverage.native_lines()
  local hits = Coverage.snapshot()
  local crypto_hit = false
  for path, lines in pairs(hits) do
    if is_core_c(path) then
      local here = observable[path]
      assert(here ~= nil, path .. " was hit but is not observable")
      for line in pairs(lines) do
        assert(here[line], path .. ":" .. line .. " was hit but is not observable")
      end
      crypto_hit = crypto_hit or path == "core/crypto.c"
    end
  end
  if next(observable) ~= nil then
    assert(crypto_hit, "hashing hit no line of core/crypto.c")
  end
end

--- A process's first window keeps the C that ran before it opened --
--- startup -- and every later one starts empty. Run in a fresh process,
--- since this test's own worker opened its first window long ago.
local function test_first_window_keeps_startup(tmp: string)
  if next(Coverage.native_lines()) == nil then return end
  local script = tmp .. "/windows.tl"
  assert(Fs.write(script, [[
local Coverage = require("cosmic.coverage")
local function main_hits(): integer
  local session = assert(Coverage.start())
  local hits = assert(Coverage.stop(session))
  local count = 0
  for _ in pairs(hits["core/main.c"] or {}) do count = count + 1 end
  return count
end
return function(): integer
  print(main_hits(), main_hits())
  return 0
end
]]))
  local env = Env.all()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  local r = assert(Child.run({ assert(Proc.executable()), script },
    { env = env, cwd = tmp, stdout = "capture", stderr = "capture",
      timeout_ms = 30000 }))
  assert(r.ok, tostring(r.stderr))
  local out = assert(r.stdout)
  local first, second = out:match("^(%d+)\t(%d+)\n$")
  assert(first ~= nil and second ~= nil, "unexpected output: " .. out)
  assert(first ~= "0", "the first window saw no startup in core/main.c")
  assert(second == "0", "a later window kept startup: " .. second)
end

--- Each C function's entry is one of its lines, and hashing enters one
--- of core/crypto.c's functions within this test's own window.
local function test_function_entries_are_observable_lines()
  local lines = Coverage.native_lines()
  local entries = Coverage.native_entries()
  for path, here in pairs(entries) do
    for line in pairs(here) do
      assert((lines[path] or {})[line], path .. ":" .. line .. " is not observable")
    end
  end
  if next(lines) == nil then
    assert(next(entries) == nil, "a core without native coverage has no entries")
    return
  end
  assert(#Hash.sha256("entries") == 32)
  local hit = Coverage.snapshot()["core/crypto.c"] or {}
  local entered = false
  for line in pairs(entries["core/crypto.c"] or {}) do
    entered = entered or hit[line] == true
  end
  assert(entered, "hashing entered no function of core/crypto.c")
end

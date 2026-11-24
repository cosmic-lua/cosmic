--- core/profile.c's sampling profiler: with COSMIC_PROFILE set, a process writes the stacks it sampled to
--- `<path>.<pid>` at exit, in the folded form, and with it unset it writes nothing.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which each test starts again with the variable set or not.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A chunk that runs long enough to be sampled: a function of its own, named, called in a loop.
local CHUNK <const> = "local function spin(n: integer): integer local s = 0 for i = 1, n do s = s + i end return s end " ..
  "for _ = 1, 200 do spin(10000) end"

--- Runs the chunk with COSMIC_PROFILE as `profile` (unset where nil), in a directory of its own, and answers the names
--- of the files the directory holds after.
local function files_after(profile: string?, chunk?: string): {string}, string
  local dir = assert(Fs.mkdtemp("profile"))
  local env = this_program.environment()
  if profile ~= nil then
    env["COSMIC_PROFILE"] = if profile == "" then "" else dir .. "/" .. profile end
  end
  env["COSMIC_PROFILE_PERIOD"] = "100"
  local started = this_program.program({ "-e", chunk or CHUNK },
    { env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, "the chunk exited " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  local names = assert(Fs.list(dir))
  return names, dir
end

--- A profiled process writes `<path>.<pid>`, each line a stack of frames joined by `;` and a count, the outermost
--- first: the chunk's own function is the innermost frame of a stack with the chunk around it.
local function test_a_profiled_process_writes_its_stacks()
  local names, dir = files_after("run")
  local name = names[1]
  assert(#names == 1 and name ~= nil and name:match("^run%.%d+$") ~= nil, table.concat(names, ", "))
  local text = assert(Fs.read(dir .. "/" .. name))
  local spun = false
  for line in text:gmatch("[^\n]+") do
    assert(line:match("^[^ ]+ %d+$") ~= nil, line)
    if line:match(";spin@[^;]*:%d+ %d+$") ~= nil then spun = true end
  end
  assert(spun, text)
end

--- A process that leaves by [`Proc.exit`], which runs no atexit handler, writes its profile too.
local function test_a_process_that_exits_by_proc_exit_writes_its_stacks()
  local names = files_after("run", CHUNK .. " require(\"cosmic.proc\").exit(0)")
  local name = names[1]
  assert(#names == 1 and name ~= nil and name:match("^run%.%d+$") ~= nil, table.concat(names, ", "))
end

--- Unset or empty, the profiler writes nothing.
local function test_an_unprofiled_process_writes_nothing()
  for _, profile in ipairs({ "", "unset" }) do
    local names = files_after(if profile == "unset" then nil else profile end)
    assert(#names == 0, table.concat(names, ", "))
  end
end

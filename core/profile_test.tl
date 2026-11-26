--- core/profile.c's sampling profiler: with COSMIC_PROFILE set to a directory, a process writes its profile there as
--- `<pid>.prof` at exit, and with it unset it writes nothing.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The program itself, which each test starts again with the variable set or not.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A chunk that runs long enough to be sampled: a function of its own, named, called in a loop.
local SPIN <const> = "local function spin(n: integer): integer local s = 0 for i = 1, n do s = s + i end return s end "
local CHUNK <const> = SPIN .. "for _ = 1, 400 do spin(100000) end"

--- What a run left: the names of the files in the profile directory, and the directory.
local record Run
  names: {string}
  dir: string
end

--- Runs `chunk` with COSMIC_PROFILE as `profile` (a name under a directory of its own; unset where nil), and the
--- other variables `env` sets.
local function run(profile: string?, chunk: string, env?: {string: string}): Run
  local dir = assert(Fs.mkdtemp("profile"))
  local vars = Test.environment()
  if profile ~= nil then
    vars["COSMIC_PROFILE"] = if profile == "" then "" else dir .. "/" .. profile end
  end
  vars["COSMIC_PROFILE_HZ"] = "2000"
  for k, v in pairs(env or {}) do vars[k] = v end
  local started = Test.cosmic({ "-e", chunk },
    { env = vars, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, "the chunk exited " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  local names: {string} = if profile ~= nil and profile ~= "" then assert(Fs.list(dir .. "/" .. profile)) else {} end
  return { names = names, dir = if profile ~= nil then dir .. "/" .. profile else dir end }
end

--- The one profile a run wrote.
local function only(r: Run): string
  local name = r.names[1]
  assert(#r.names == 1 and name ~= nil and name:match("^%d+%.prof$") ~= nil, table.concat(r.names, ", "))
  return assert(Fs.read(r.dir .. "/" .. name))
end

--- The microseconds of the samples in `text` whose innermost frame matches `pattern`.
local function us_in(text: string, pattern: string): integer
  local us = 0
  for frames, weight in text:gmatch("\nsample ([^ ]+) [^ ]+ (%d+)") do
    local innermost = frames:match("([^;]+)$") or ""
    if innermost:match(pattern) ~= nil then us = us + (math.tointeger(tonumber(weight)) or 0) end
  end
  return us
end

--- A profile says what it is, which process and clock it is of, its totals, and its samples: each a stack of frames
--- joined by `;` from the outermost, the innermost line, and the microseconds it stood for. The chunk's own function is innermost.
local function test_a_profiled_process_writes_its_profile()
  local text = only(run("run", CHUNK))
  assert(text:match("^cosmic%-profile 1\nprocess %d+ parent %d+ clock cpu hz 2000\ncommand [^\n]*%-e") ~= nil, text)
  assert(text:match("\ntotal wall_ns %d+ cpu_ns %d+ sampled_us %d+ dropped_us 0 other_us %d+\n") ~= nil, text)
  for line in text:gmatch("[^\n]+") do
    if line:sub(1, 7) == "sample " then
      assert(line:match("^sample [^ ]+ [^ ]+ %d+$") ~= nil, line)
    end
  end
  assert(us_in(text, "^spin@%-e:1$") > 0, text)
end

--- Time in C is seen and named: a long plain search is charged to string.find, under the chunk's line that called it.
local function test_time_in_c_is_charged_to_the_c_function()
  local chunk = "local x = ('ab'):rep(1000000) for _ = 1, 400 do local _ = x:find('abc', 1, true) end"
  local text = only(run("run", chunk))
  assert(us_in(text, "^string%.find@%[C%]$") > 0, text)
  assert(text:match("\nsample [^ ]+;string%.find@%[C%] %-e:1 %d+\n") ~= nil, text)
end

--- A coroutine's samples hold its own frames.
local function test_a_coroutine_is_sampled()
  local chunk = SPIN .. "local co = coroutine.wrap(function() for _ = 1, 400 do spin(100000) end end) co()"
  local text = only(run("run", chunk))
  assert(us_in(text, "^spin@%-e:1$") > 0, text)
end

--- On the wall clock, time a process waits is counted too.
local function test_the_wall_clock_counts_waits()
  local chunk = "local _, _ = require('cosmic.clock').sleep(400 * 1000000)"
  local text = only(run("run", chunk, { COSMIC_PROFILE_CLOCK = "wall" }))
  assert(text:match("clock wall hz 2000\n") ~= nil, text)
  local us = math.tointeger(tonumber(text:match("\ntotal [^\n]* sampled_us (%d+)") or "")) or 0
  assert(us >= 300000, text)
end

--- A process that leaves by [`Proc.exit`], which runs no atexit handler, writes its profile too.
local function test_a_process_that_exits_by_proc_exit_writes_its_profile()
  local text = only(run("run", CHUNK .. " require(\"cosmic.proc\").exit(0)"))
  assert(us_in(text, "^spin@%-e:1$") > 0, text)
end

--- Unset or empty, the profiler writes nothing.
local function test_an_unprofiled_process_writes_nothing()
  for _, profile in ipairs({ "", "unset" }) do
    local r = run(if profile == "unset" then nil else profile end, CHUNK)
    local names = assert(Fs.list(r.dir))
    assert(#names == 0, table.concat(names, ", "))
  end
end

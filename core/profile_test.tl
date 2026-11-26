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
  assert(text:match("\ntotal wall_ns %d+ cpu_ns %d+ sampled_us %d+ dropped_us 0 other_us %d+ peak_rss_kb %d+\n") ~= nil, text)
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

--- A phase and a span of [`cosmic.clock`] are spans of the profile: each has a total, and the samples taken in one
--- stand under it, the outer first.
local function test_phases_and_spans_are_spans_of_the_profile()
  local chunk = SPIN .. "local Clock = require('cosmic.clock') local spans: Clock.Spans = {} " ..
    "local p <close> = Clock.phase('outer') do local _s <close> = Clock.span(spans, 'inner') " ..
    "for _ = 1, 400 do spin(100000) end end p:next('after') for _ = 1, 200 do spin(100000) end"
  local text = only(run("run", chunk))
  assert(text:match("\nspan %[outer%] 1 %d+ %d+ %d+\n") ~= nil, text)
  assert(text:match("\nspan %[outer%];%[inner%] 1 %d+ %d+ %d+\n") ~= nil, text)
  assert(text:match("\nspan %[after%] 1 %d+ %d+ %d+\n") ~= nil, text)
  assert(text:match("\nsample %[outer%];%[inner%];[^ ]*spin@%-e:1 ") ~= nil, text)
  assert(text:match("\nsample %[after%];[^ ]*spin@%-e:1 ") ~= nil, text)
end

--- A child given an environment of its own profiles itself into its parent's directory: the start adds the profile's
--- variables back.
local function test_a_child_given_its_own_environment_is_profiled_too()
  local chunk = "local Child = require('cosmic.child') local Env = require('cosmic.env') " ..
    "local Proc = require('cosmic.proc') local again = assert(Proc.relaunch()) " ..
    "local env: mut {string: string} = {} for k, v in pairs(Env.all()) do " ..
    "if k:sub(1, 14) ~= 'COSMIC_PROFILE' then env[k] = v end end " ..
    "for k, v in pairs(again.env) do env[k] = v end " ..
    "local argv: mut {string} = {} for _, w in ipairs(again.argv) do argv[#argv + 1] = w end " ..
    "argv[#argv + 1] = '-e' argv[#argv + 1] = 'local x = 0 for i = 1, 30000000 do x = x + i end' " ..
    "local r = assert(Child.run(argv, { env = env, fds = again.fds, timeout_ns = 60000000000 })) " ..
    "assert(r.ok, tostring(r.code))"
  local r = run("run", chunk)
  assert(#r.names == 2, table.concat(r.names, ", "))
end

--- A span's token names it alone: one closed already, and closed again after another span took its place, closes
--- nothing.
local function test_a_stale_token_closes_nothing()
  local chunk = SPIN .. "local sys = require('cosmic.sys') " ..
    "local p = sys.profile_span_open('p') local a = sys.profile_span_open('a') " ..
    "assert(sys.profile_span_close(p)) local x = sys.profile_span_open('x') local b = sys.profile_span_open('b') " ..
    "assert(not sys.profile_span_close(a)) for _ = 1, 200 do spin(100000) end " ..
    "assert(sys.profile_span_close(b)) assert(sys.profile_span_close(x))"
  local text = only(run("run", chunk))
  assert(text:match("\nspan %[x%];%[b%] 1 %d+ %d+ %d+\n") ~= nil, text)
  assert(text:match("\nsample %[x%];%[b%];[^ ]*spin@%-e:1 ") ~= nil, text)
end

--- Each module a profiled process loads from the store is a span of its own, from the read to the end of its run,
--- and a module it requires stands in it: cosmic.mcp requires cosmic.json, which nothing loaded before it.
local function test_each_module_loaded_is_a_span()
  local text = only(run("run", "local _ = require('cosmic.mcp')"))
  assert(text:match("\nspan [^\n]*%[require:cosmic%.mcp%] 1 %d+ %d+ %d+\n") ~= nil, text)
  assert(text:match("\nspan [^\n]*%[require:cosmic%.mcp%];%[require:cosmic%.json%] 1 %d+ %d+ %d+\n") ~= nil, text)
end

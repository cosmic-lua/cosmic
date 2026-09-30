--- `cosmic --standalone`, run as this program: a file's path and
--- arguments, its exit status, and the compile cache it keeps. These
--- start this program, its core and retained descriptor, so they need
--- `tool`; the in-process compiles are in `standalone_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- The program itself, which its tests start.
Test.needs{ tool = true }

--- End to end, from a directory holding no tree: the file gets its own
--- path at argv[0] and what follows it, its exit code is the process's,
--- and nothing is written beside it -- no `o/`.
local function test_a_run_writes_nothing_and_passes_its_arguments(tmp: string)
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local record Script
  main: function({string}): integer
end
Script.main = function(argv: {string}): integer
  Fs.put(Fs.stdout, argv[0] .. "|" .. table.concat(argv, ",") .. "\n")
  return 5
end
return Script
]]))
  local started = this_program.program({ "--standalone", script, "one", "two" }, {
    cwd = tmp, stdout = "capture", stderr = "capture",
    timeout_ms = 30000,
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 5, tostring(result.stderr))
  assert(result.stdout == script .. "|one,two\n", tostring(result.stdout))
  local names = assert(Fs.list(tmp))
  assert(#names == 1 and names[1] == "script.tl", "a standalone run wrote beside the file")
end

--- The compile cache is trusted when read back, so it is kept only in
--- a directory no one else can write: never a `/tmp` fallback when no
--- cache home is set, and not in one others could have planted Lua in.
local function test_the_compile_cache_is_kept_only_where_others_cannot_write(tmp: string)
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, "return function(_argv: {string}): integer return 3 end\n"))
  local function run(env: {string:string}): integer
    local started = this_program.program({ "--standalone", script }, {
      env = env, stdout = "capture", stderr = "capture", timeout_ms = 30000,
    })
    local result = assert(Child.run(started.argv, started.options))
    return result.code
  end
  local cache = tmp .. "/cache"
  assert(run({ XDG_CACHE_HOME = cache }) == 3)
  local kept = assert(Fs.list(cache .. "/cosmic/standalone"))
  assert(#kept == 1, tostring(#kept))
  local st = assert(Fs.stat(cache .. "/cosmic/standalone/" .. kept[1]))
  assert(st.mode & 0x1ff == 0x180, tostring(st.mode))
  -- a planted file in a directory others can write is never run
  assert(Fs.write(cache .. "/cosmic/standalone/" .. kept[1], "return function() return 9 end"))
  assert(sys.chmod(cache .. "/cosmic/standalone", 0x1ff))
  assert(run({ XDG_CACHE_HOME = cache }) == 3)
  -- with no cache home at all, it still runs, compiling afresh
  assert(run({}) == 3)
end

--- What main returns is judged as a file run's is: a whole number
--- outside 0-255, text naming none, or a float that is not whole exits
--- 2, the complaint naming the file rather than cmd.cosmic.main; one
--- that has a whole value is that value.
local function test_a_main_that_returns_no_exit_status_is_refused(tmp: string)
  local function run(returned: string): Child.Result
    local script = tmp .. "/script.tl"
    assert(Fs.write(script, "return function(_argv: {string}): any\n  return " ..
      returned .. "\nend\n"))
    local started = this_program.program({ "--standalone", script }, {
      env = { XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ms = 30000,
    })
    return (assert(Child.run(started.argv, started.options)))
  end
  for returned, shown in pairs({ ["300"] = "300", ["\"three\""] = "\"three\"",
      ["1.5"] = "1.5" } as {string:string}) do
    local result = run(returned)
    assert(result.code == 2, returned .. " exited " .. tostring(result.code) .. ": " ..
      tostring(result.stderr))
    local complaint = "cosmic: " .. tmp .. "/script.tl returned " .. shown ..
      ", not an exit status 0-255"
    assert(tostring(result.stderr):find(complaint, 1, true) ~= nil, tostring(result.stderr))
  end
  local whole = run("4.0")
  assert(whole.code == 4, tostring(whole.stderr))
  local text = run("\"4\"")
  assert(text.code == 4, tostring(text.stderr))
end

local function test_a_run_without_a_file_is_a_usage_error()
  local started = this_program.program({ "--standalone" }, {
    stdout = "capture", stderr = "capture", timeout_ms = 30000,
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 2)
  assert(tostring(result.stderr):find("usage", 1, true) ~= nil)
end

--- The compile cache a standalone run and `cosmic -e` keep ([`build.standalone`]), run as this program. Its key is the
--- binary's boot hash, which only the tree's projection records (a test's closure store records none, and its children
--- keep nothing), so these tests read the projection (`o/cosmic.db`).

local Array = require("cosmic.array")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")

--- The program itself, started with the projection as its store: a kept compile is keyed on the boot hash the
--- projection records, and the closure store a test is otherwise given records none.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" } } }

--- The compile cache is trusted when read back, so it is kept only in
--- a directory no one else can write: never a `/tmp` fallback when no
--- cache home is set, and not in one others could have planted Lua in.
local function test_the_compile_cache_is_kept_only_where_others_cannot_write(tmp: string)
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, "return function(_argv: {string}): integer return 3 end\n"))
  local function run(env: {string:string}): integer
    local started = this_program.program({ "--standalone", script }, {
      env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30),
    })
    local result = assert(Child.run(started.argv, started.options))
    local code = result.code
    assert(code ~= nil, "a signal ended the run: " .. tostring(result.signal))
    return code
  end
  local cache = tmp .. "/cache"
  assert(run({ XDG_CACHE_HOME = cache }) == 3)
  local kept = assert(Fs.list(cache .. "/cosmic/standalone"))
  assert(#kept == 1, tostring(#kept))
  local name = Array.at(kept, 1)
  local st = assert(Fs.stat(cache .. "/cosmic/standalone/" .. name))
  assert(st.mode & 0x1ff == 0x180, tostring(st.mode))
  -- a planted file in a directory others can write is never run
  assert(Fs.write(cache .. "/cosmic/standalone/" .. name, "return function() return 9 end"))
  assert(sys.chmod(cache .. "/cosmic/standalone", 0x1ff))
  assert(run({ XDG_CACHE_HOME = cache }) == 3)
  -- with no cache home at all, it still runs, compiling afresh
  assert(run({}) == 3)
end

--- A clean compile of a `-e` chunk is kept, so a second run of it loads no checker; a file of the same text is still
--- checked as a file, and refused for the tool's own module a chunk may take.
local function test_a_chunks_compile_is_kept_apart_from_a_files(tmp: string)
  assert(Store.meta("boot_hash") ~= nil, "the projection records no boot hash")
  local chunk = 'local exit_status = require("build.exit_status") print(exit_status.uncompiled) return 0'
  assert(Fs.write(tmp .. "/same.tl", chunk))
  local env = { XDG_CACHE_HOME = tmp .. "/cache", COSMIC_TRACE_REQUIRE = "1" }
  local function run(words: {string}): Child.Result
    local started = this_program.program(words, { env = env, cwd = tmp, stdout = "capture",
      stderr = "capture", timeout_ns = Clock.seconds(30) })
    local r = assert(Child.run(started.argv, started.options))
    return r
  end
  local function refused_as_a_file()
    local r = run({ "--standalone", "same.tl" })
    assert(r.code == 4 and r.stdout == "", tostring(r.code) .. tostring(r.stdout) .. tostring(r.stderr))
  end
  refused_as_a_file()
  for round = 1, 2 do
    local r = run({ "-e", chunk })
    assert(r.ok and r.stdout == "4\n", tostring(round) .. tostring(r.stdout) .. tostring(r.stderr))
    local checked = (r.stderr or ""):find(" build.pipeline ", 1, true) ~= nil
    assert(checked == (round == 1), ("run %d of the chunk loaded the checker: %s"):format(round, tostring(checked)))
  end
  refused_as_a_file()
end

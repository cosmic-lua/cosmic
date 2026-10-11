--- `Dev.supervise`: a program restarted on a change, not in a loop when
--- it fails, told its boot, and stopped with the supervisor. Each program
--- is this one again running a chunk (`lua`).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Dev = require("cosmic.web.dev")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local fixture = require("build.child_lua_fixture")
local sys = require("cosmic.sys")

Test.policy{ profiles = { "cosmic" } }

local DEADLINE_NS <const> = Clock.seconds(8)

--- The message of the error `fn` raises; fails where it raises none.
local function raised(fn: function()): string
  local ok, err = pcall(function(): any
    fn()
    return nil
  end)
  assert(not ok, "expected a raise")
  return tostring(err)
end

--- Starts the chunk `chunk` as the program, given the environment.
local function program(chunk: string): function(env: {string:string}): Child.Handle | nil, string
  return function(env: {string:string}): Child.Handle | nil, string
    local started = fixture.lua(chunk, nil, { env = env })
    return Child.start(started.argv, started.options)
  end
end

--- A program that writes its boot and development flag to `marks/<boot>`
--- and waits for a signal.
local function marking(tmp: string): string
  return 'local Fs = require("cosmic.fs") local env = require("cosmic.env") ' ..
    'local boot = env.get("COSMIC_WEB_BOOT") ' ..
    'assert(Fs.write("' .. tmp .. '/marks/" .. boot, env.get("COSMIC_WEB_DEV"))) ' ..
    fixture.sleeping(60000)
end

local function alive(pid: integer): boolean
  return sys.kill(pid, 0) == true
end

--- A `stop` that gives up, failing the test, past the deadline.
local function deadline(): function(): boolean
  local until_ns = Clock.monotonic_ns() + DEADLINE_NS
  return function(): boolean
    assert(Clock.monotonic_ns() < until_ns, "the supervisor never reached its goal")
    return false
  end
end

local function test_a_change_replaces_the_program_with_a_counted_boot(tmp: string)
  assert(Fs.mkdirs(tmp .. "/src") and Fs.mkdirs(tmp .. "/marks"))
  assert(Fs.write(tmp .. "/src/a.tl", "one"))
  local pids: {integer} = {}
  local lines: {string} = {}
  local give_up = deadline()
  local edited = false
  local ok, why = Dev.supervise{
    start = program(marking(tmp)), watch = { tmp .. "/src" }, interval_ns = Clock.ms(10),
    log = function(text: string) lines[#lines + 1] = text end,
    on_boot = function(boot: integer, pid: integer)
      pids[boot] = pid
      if boot == 1 then
        assert(Fs.write(tmp .. "/src/a.tl", "two"))
        assert(Fs.set_mtime(tmp .. "/src/a.tl", 1000000))
        edited = true
      end
    end,
    stop = function(): boolean
      give_up()
      return #pids == 2 and Fs.exists(tmp .. "/marks/2") == true
    end,
  }
  assert(ok and why == "")
  assert(edited and #pids == 2 and pids[1] ~= pids[2])
  assert(not alive(pids[1]), "the first program was ended before the second began")
  assert(not alive(pids[2]), "the program is ended with the supervisor")
  assert(Fs.read(tmp .. "/marks/2") == "1", "COSMIC_WEB_DEV is set")
  local told = table.concat(lines, "\n")
  assert(told:find("starting (boot 1)", 1, true) and told:find("a.tl changed", 1, true))
  assert(told:find("starting (boot 2)", 1, true))
end

local function test_a_program_that_exits_is_not_started_again_until_a_change(tmp: string)
  assert(Fs.mkdirs(tmp .. "/src"))
  assert(Fs.write(tmp .. "/src/a.tl", "broken"))
  local boots = 0
  local rounds = 0
  local lines: {string} = {}
  local give_up = deadline()
  local ok = Dev.supervise{
    start = program("return 3"), watch = { tmp .. "/src" },
    interval_ns = Clock.ms(5), log = function(text: string) lines[#lines + 1] = text end,
    on_boot = function(boot: integer, _pid: integer) boots = boot end,
    stop = function(): boolean
      give_up()
      rounds = rounds + 1
      if rounds == 30 then
        assert(boots == 1, "no restart loop")
        assert(Fs.write(tmp .. "/src/a.tl", "fixed!"))
      end
      return boots == 2
    end,
  }
  assert(ok and rounds > 30)
  local told = table.concat(lines, "\n")
  assert(told:find("exited with status 3; waiting for a change", 1, true))
end

local function test_the_ignored_files_and_the_static_directory_do_not_restart(tmp: string)
  local root = tmp .. "/w"
  assert(Fs.mkdirs(root .. "/static") and Fs.mkdirs(root .. "/.git") and Fs.mkdirs(tmp .. "/marks"))
  assert(Fs.write(root .. "/app.tl", "x"))
  local boots = 0
  local rounds = 0
  local give_up = deadline()
  local ok = Dev.supervise{
    start = program(marking(tmp)), watch = { root }, interval_ns = Clock.ms(5),
    log = function(_text: string) end,
    on_boot = function(boot: integer, _pid: integer) boots = boot end,
    stop = function(): boolean
      give_up()
      rounds = rounds + 1
      if rounds == 3 then
        assert(Fs.write(root .. "/static/app.css", "a{}"))
        assert(Fs.write(root .. "/.git/HEAD", "ref"))
        assert(Fs.write(root .. "/data.db", "rows"))
        assert(Fs.write(root .. "/data.db-wal", "rows"))
        assert(Fs.write(root .. "/app.tl~", "backup"))
      end
      if rounds == 12 then assert(Fs.write(root .. "/page.html", "<p>")) end
      return boots == 2
    end,
  }
  assert(ok)
  assert(rounds > 12, "only the page restarted the program")
end

local function test_options_of_the_wrong_kind_raise()
  local unknown: any = { watches = {} }
  assert(raised(function() Dev.supervise(unknown as Dev.SuperviseOptions) end):find("no field watches", 1, true))
  assert(raised(function() Dev.supervise{ interval_ns = 0 } end):find("interval_ns", 1, true))
end

local function test_a_watched_directory_that_is_missing_is_refused(tmp: string)
  local ok, why = Dev.supervise{ start = program("return 0"), watch = { tmp .. "/absent" } }
  assert(ok == false and why:find("absent", 1, true) ~= nil)
end

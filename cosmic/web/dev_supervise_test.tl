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
local function program(chunk: string): function(env: {string:string}): Child.Handle?, string
  return function(env: {string:string}): Child.Handle?, string
    local started = fixture.lua(chunk, nil, { env = env })
    return Child.start(started.argv, started.options)
  end
end

--- A program that writes its boot and development flag to `marks/<boot>`
--- and waits for a signal.
local function marking(tmp: string): string
  return 'local Fs = require("cosmic.fs") local env = require("cosmic.env") ' ..
    'local boot = assert(env.get("COSMIC_WEB_BOOT")) local dev = assert(env.get("COSMIC_WEB_DEV")) ' ..
    'assert(Fs.write("' .. tmp .. '/marks/" .. boot, dev)) ' ..
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
  local lines: mut {string} = {}
  local give_up = deadline()
  local edited: boolean = false
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
  local pids_2 = assert(pids[2], "expected pids[2]")
  assert(not alive(pids_2), "the program is ended with the supervisor")
  assert(Fs.read(tmp .. "/marks/2") == "1", "COSMIC_WEB_DEV is set")
  local told = table.concat(lines, "\n")
  assert(told:find("starting (boot 1)", 1, true) and told:find("a.tl changed", 1, true))
  assert(told:find("starting (boot 2)", 1, true))
end

local function test_a_program_that_exits_is_not_started_again_until_a_change(tmp: string)
  assert(Fs.mkdirs(tmp .. "/src"))
  assert(Fs.write(tmp .. "/src/a.tl", "broken"))
  local boots: integer = 0
  local rounds: integer = 0
  local quiet_rounds: integer = 0
  local fixed: boolean = false
  local lines: mut {string} = {}
  local give_up = deadline()
  local ok = Dev.supervise{
    start = program("return 3"), watch = { tmp .. "/src" },
    interval_ns = Clock.ms(5), log = function(text: string) lines[#lines + 1] = text end,
    on_boot = function(boot: integer, _pid: integer) boots = boot end,
    stop = function(): boolean
      give_up()
      rounds = rounds + 1
      if not fixed and table.concat(lines, "\n"):find("exited with status 3", 1, true) ~= nil then
        quiet_rounds = quiet_rounds + 1
        assert(boots == 1, "no restart loop")
        if quiet_rounds == 30 then
          fixed = true
          assert(Fs.write(tmp .. "/src/a.tl", "fixed!"))
        end
      end
      return boots == 2
    end,
  }
  assert(ok and fixed and quiet_rounds >= 30, "the program was left alone for 30 looks after it exited")
  local told = table.concat(lines, "\n")
  assert(told:find("exited with status 3; waiting for a change", 1, true))
end

local function test_the_ignored_files_and_the_static_directory_do_not_restart(tmp: string)
  local root = tmp .. "/w"
  assert(Fs.mkdirs(root .. "/static") and Fs.mkdirs(root .. "/.git") and Fs.mkdirs(tmp .. "/marks"))
  assert(Fs.write(root .. "/app.tl", "x"))
  local boots: integer = 0
  local rounds: integer = 0
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
        assert(Fs.mkdirs(root .. "/node_modules/dep"))
        assert(Fs.write(root .. "/node_modules/dep/index.js", "x"))
      end
      if rounds == 12 then
        assert(boots == 1, "nothing ignored restarted the program")
        assert(Fs.write(root .. "/page.html", "<p>"))
      end
      return boots == 2
    end,
  }
  assert(ok)
  assert(rounds > 12, "only the page restarted the program")
end

local function test_a_burst_of_changes_restarts_once(tmp: string)
  assert(Fs.mkdirs(tmp .. "/src") and Fs.mkdirs(tmp .. "/marks"))
  assert(Fs.write(tmp .. "/src/a.tl", "one"))
  local boots: integer = 0
  local rounds: integer = 0
  local lines: mut {string} = {}
  local give_up = deadline()
  local ok = Dev.supervise{
    start = program(marking(tmp)), watch = { tmp .. "/src" }, interval_ns = Clock.ms(20),
    log = function(text: string) lines[#lines + 1] = text end,
    on_boot = function(boot: integer, _pid: integer) boots = boot end,
    stop = function(): boolean
      give_up()
      rounds = rounds + 1
      -- Three edits on three successive looks, then quiet.
      if rounds >= 2 and rounds <= 4 then
        assert(Fs.write(tmp .. "/src/a.tl", ("edit %d"):format(rounds)))
        assert(Fs.set_mtime(tmp .. "/src/a.tl", 1000000 + rounds))
      end
      assert(boots == 1 or rounds > 4, "no restart while changes still arrive")
      return boots == 2 and rounds > 8
    end,
  }
  assert(ok and boots == 2)
  local restarts = select(2, table.concat(lines, "\n"):gsub("restarting", ""))
  assert(restarts == 1, "one restart for the burst, not " .. tostring(restarts))
end

local function test_a_static_directory_named_by_the_option_is_ignored(tmp: string)
  local root = tmp .. "/w"
  assert(Fs.mkdirs(root .. "/public") and Fs.mkdirs(root .. "/static") and Fs.mkdirs(tmp .. "/marks"))
  assert(Fs.write(root .. "/app.tl", "x"))
  local boots: integer = 0
  local rounds: integer = 0
  local give_up = deadline()
  local ok = Dev.supervise{
    start = program(marking(tmp)), watch = { root }, static = "public", interval_ns = Clock.ms(5),
    log = function(_text: string) end,
    on_boot = function(boot: integer, _pid: integer) boots = boot end,
    stop = function(): boolean
      give_up()
      rounds = rounds + 1
      if rounds == 3 then assert(Fs.write(root .. "/public/app.css", "a{}")) end
      if rounds == 12 then
        assert(boots == 1, "the configured static directory is ignored")
        assert(Fs.write(root .. "/static/app.css", "a{}"))
      end
      return boots == 2
    end,
  }
  assert(ok and rounds > 12)
end

--- Runs the program `chunk` under the supervisor, sends the supervisor
--- (this process) a SIGTERM once `marks/<ready>` exists, and answers the
--- program's pid after [`Dev.supervise`] returns.
local function sigterm_the_supervisor(tmp: string, chunk: string, ready: string, grace_ns?: integer): integer
  assert(Fs.mkdirs(tmp .. "/src") and Fs.mkdirs(tmp .. "/marks"))
  assert(Fs.write(tmp .. "/src/a.tl", "one"))
  local pid: integer = 0
  local sent: boolean = false
  local give_up = deadline()
  local ok = Dev.supervise{
    start = program(chunk), watch = { tmp .. "/src" }, interval_ns = Clock.ms(10), grace_ns = grace_ns,
    log = function(_text: string) end,
    on_boot = function(_boot: integer, started: integer) pid = started end,
    stop = function(): boolean
      give_up()
      if pid ~= 0 and Fs.exists(tmp .. "/marks/" .. ready) == true and not sent then
        sent = true
        assert(sys.kill(sys.getpid(), sys.SIGTERM))
      end
      return false
    end,
  }
  assert(ok and sent and pid ~= 0)
  return pid
end

local function test_a_sigterm_to_the_supervisor_stops_it_and_its_program(tmp: string)
  local pid = sigterm_the_supervisor(tmp, marking(tmp), "1")
  -- The program is reaped before supervise returns: a zombie would answer.
  assert(not alive(pid), "the program was ended with the supervisor")
end

--- A program that holds SIGTERM, as a server finishing its requests does,
--- and takes `ms` more milliseconds to finish before it writes `marks/done`.
local function finishing(tmp: string, ms: integer): string
  return 'local Fs = require("cosmic.fs") local Clock = require("cosmic.clock") ' ..
    'local guard = assert(require("cosmic.signal").guard()) ' ..
    'assert(Fs.write("' .. tmp .. '/marks/ready", "x")) ' ..
    'while guard:cancelled() == 0 do Clock.sleep_ns(Clock.ms(10)) end ' ..
    'Clock.sleep_ns(Clock.ms(' .. tostring(ms) .. ')) ' ..
    'assert(Fs.write("' .. tmp .. '/marks/done", "x"))'
end

local function test_a_sigterm_to_the_supervisor_gives_the_program_its_grace(tmp: string)
  -- Longer than cosmic.child's own 250 ms, well within the supervisor's.
  local pid = sigterm_the_supervisor(tmp, finishing(tmp, 800), "ready", Clock.seconds(5))
  assert(not alive(pid), "the program was ended with the supervisor")
  assert(Fs.exists(tmp .. "/marks/done") == true, "the program finished within its grace")
end

local function test_a_program_that_outlasts_the_grace_is_killed(tmp: string)
  local pid = sigterm_the_supervisor(tmp, finishing(tmp, 60000), "ready", Clock.ms(300))
  assert(not alive(pid), "the program was ended with the supervisor")
  assert(Fs.exists(tmp .. "/marks/done") ~= true, "the program did not finish")
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

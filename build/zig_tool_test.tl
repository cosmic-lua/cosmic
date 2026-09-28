--- `build/zig.tl`'s tests that start a program: bin/zig itself, to see
--- the status a zig that cannot run exits with, and the stand-in zig
--- (`build.stand_in`), built from the program's core, that `Zig.run`
--- and a build answer or pass a signal on to. Apart from
--- build/zig_test.tl's so those stand while the tree moves.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")
local Test = require("cosmic.test")
local Zig = require("build.zig")

--- A source whose build a test interrupts, and the program itself, which
--- its tests start and whose core building the stand-in zig reads
--- (`build.stand_in`). bin/zig is started with an environment of the
--- test's own, and the stand-in reads none of the one it inherits.
Test.needs{ reads = { "build/patch.tl" }, tool = true }

--- `bin/zig` exits as a shell would when the zig it is given cannot
--- run: 127 when there is none on PATH, 126 when there is one that is
--- not executable.
local function test_main_exits_127_for_no_zig_and_126_for_an_unrunnable_one(tmp: string)
  local script = assert(Fs.absolute("build/zig.tl"))
  local function run(): Child.Result
    local started = this_program.program({ "--standalone", script, "version" }, {
      env = { COSMIC_ZIG = "zig-for-test", PATH = tmp, XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ms = 30000,
    })
    return (assert(Child.run(started.argv, started.options)))
  end
  local missing = run()
  assert(missing.code == 127, tostring(missing.stderr))
  local missing_err = missing.stderr or ""
  assert(missing_err:find("zig-for-test: not found", 1, true), missing_err)
  assert(Fs.write(tmp .. "/zig-for-test", "not executable", 0x1a4))
  local denied = run()
  assert(denied.code == 126, tostring(denied.stderr))
  local denied_err = denied.stderr or ""
  assert(denied_err:find("zig-for-test: permission denied", 1, true), denied_err)
end

local function test_run_answers_as_the_child_did(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Zig.run({ probe, "exit 0" }) == 0)
  assert(Zig.run({ probe, "exit 3" }) == 3)
  assert(Zig.run({ probe, "signal KILL" }) == 128 + sys.SIGKILL)
end

local function test_run_passes_on_a_signal_sent_to_it_alone(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- The child has this process interrupted, as a `kill -INT` aimed at
  -- bin/zig alone would; the child hears of it only if it is passed on.
  local started = Time.monotonic_ns()
  local status = Zig.run({ probe,
    "trap 42; signal INT " .. tostring(sys.getpid()) .. "; sleep 10000" })
  assert(status == 42, tostring(status))
  assert(Time.monotonic_ns() - started < 5 * 1000 * 1000 * 1000)
end

--- A root of its own under `tmp` for `build/zig.tl` to build from: the
--- script and the patch applier it runs first, and no vendored tree to
--- patch. Answers the script's path there.
local function bare_root(tmp: string): string
  assert(Fs.mkdirs(tmp .. "/root/build"))
  assert(Fs.mkdirs(tmp .. "/root/vendor"))
  for _, name in ipairs({ "zig.tl", "patch.tl" }) do
    assert(Fs.write(tmp .. "/root/build/" .. name, (assert(Fs.read("build/" .. name)))))
  end
  return tmp .. "/root/build/zig.tl"
end

--- Runs `build/zig.tl` from `script` as bin/zig, building with the
--- stand-in `tmp/zig-for-test`, and answers how it ended. Once it has
--- started, `tmp/zig-pid` holds its pid -- negated, naming its process
--- group, which it leads, when `group` -- for the stand-in to wait for
--- and signal, as a shell's `$PPID` or `0` would name it.
-- TODO: have the stand-in signal its parent, or its own process group,
-- itself, as the shell's `kill $PPID` and `kill 0` did, rather than wait
-- for the pid in a file, once cosmic.sys carries getppid and a kill of
-- pid 0 (its binding refuses 0 as out of range): today a program has
-- neither, and /proc/self/stat, which names both, is Linux's alone.
local function build_with_stand_in(tmp: string, script: string, group: boolean): Child.Result
  local started = this_program.program({ "--standalone", script, "build" }, {
    env = { COSMIC_ZIG = "zig-for-test", PATH = tmp, XDG_CACHE_HOME = tmp .. "/cache" },
    stdout = "capture", stderr = "capture",
  })
  local h = assert(Child.start(started.argv, started.options))
  -- Written whole under another name, so the stand-in never reads half.
  assert(Fs.write(tmp .. "/zig-pid.writing", (group and "-" or "") .. tostring(h.pid)))
  assert(Fs.rename(tmp .. "/zig-pid.writing", tmp .. "/zig-pid"))
  return (assert(h:wait(30000)))
end

--- A Ctrl-C that reached zig and `bin/zig` both, which zig caught and
--- exited cleanly from before `bin/zig` passed it on, is answered by
--- zig's status, as bash answers it: `bin/zig` exits 0 rather than
--- dying of the SIGINT. The stub signals its whole group, as a terminal
--- does, and exits at once, well inside the pass-on window.
local function test_run_answers_a_caught_ctrl_c_by_the_childs_status(tmp: string)
  local script = bare_root(tmp)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- Child.start starts bin/zig in a group of its own, so the SIGINT to
  -- that group stays inside it.
  assert(stand_in.place(probe, tmp .. "/zig-for-test",
    "trap 0; wait-for $DIR/zig-pid; signal INT @$DIR/zig-pid; exit 0"))
  local result = build_with_stand_in(tmp, script, true)
  assert(result.signal == nil and result.code == 0,
    tostring(result.code) .. " " .. tostring(result.signal) .. ": " .. tostring(result.stderr))
end

--- A SIGTERM sent to `bin/zig` alone that its child exits before being
--- passed is not swallowed: `bin/zig` ends of it, as it would have had
--- it not been running a build.
local function test_run_reraises_a_signal_its_child_never_got(tmp: string)
  local script = bare_root(tmp)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(stand_in.place(probe, tmp .. "/zig-for-test",
    "wait-for $DIR/zig-pid; signal TERM @$DIR/zig-pid; exit 0"))
  local result = build_with_stand_in(tmp, script, false)
  assert(result.signal == sys.SIGTERM,
    tostring(result.code) .. " " .. tostring(result.signal) .. ": " .. tostring(result.stderr))
end

--- `build/stand_in.tl`: the stand-in program a test starts where it
--- would otherwise write a shell script, each of its verbs, and what it
--- reads its script and words from.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")
local stand_in = require("build.stand_in")
local Test = require("cosmic.test")

--- The program's core, which building a stand-in reads.
Test.needs{ tool = true }

--- A stand-in built under `tmp`.
local function built(tmp: string): string
  return (assert(stand_in.build(tmp .. "/stand-in")))
end

--- Runs `argv` to its end with only `env`, its output captured.
local function run(argv: {string}, env?: {string:string}, input?: string): Child.Result
  return (assert(Child.run(argv, { env = env or {}, input = input, stdout = "capture",
    stderr = "capture", timeout_ms = 30000 })))
end

--- Waits, a little at a time, until `path` exists.
local function await(path: string)
  local deadline = Time.monotonic_ns() + 30 * 1000 * 1000 * 1000
  while Fs.exists(path) ~= true do
    assert(Time.monotonic_ns() < deadline, "waited for " .. path)
    local _, _ = sys.nanosleep(5 * 1000 * 1000)
  end
end

--- A placed copy runs the script beside it, one command a line or
--- between semicolons, with its arguments, its directory and the
--- environment put in, and a `[w]` command only when its first argument
--- is `w`; the script's end is status 0, and `exit` ends it sooner.
local function test_a_placed_copy_runs_its_script_with_its_words(tmp: string)
  local probe = built(tmp)
  local tool = tmp .. "/bin/tool"
  assert(Fs.mkdirs(tmp .. "/bin"))
  assert(stand_in.place(probe, tool,
    "print args $@ in $DIR; eprint to  stderr $NAME$UNSET.\n" ..
    "[build] print building; [build] exit 3\n" ..
    "[other] print never\nprint done"))
  local st = assert(Fs.stat(tool))
  assert(st.mode & 0x1ff == 0x1ed, tostring(st.mode))
  local dir = assert(Fs.absolute(tmp .. "/bin"))
  local plain = run({ tool, "a", "b" }, { NAME = "named" })
  assert(plain.code == 0, tostring(plain.stderr))
  assert(plain.stdout == "args a b in " .. dir .. "\ndone\n", plain.stdout)
  assert(plain.stderr == "to stderr named.\n", plain.stderr)
  local building = run({ tool, "build", "boot" })
  assert(building.code == 3, tostring(building.stderr))
  assert(building.stdout == "args build boot in " .. dir .. "\nbuilding\n", building.stdout)
  -- One placed without a script runs its first argument, as the probe
  -- itself does.
  assert(stand_in.place(probe, tmp .. "/bin/bare"))
  assert(not Fs.exists(tmp .. "/bin/bare.do"))
  local bare = run({ tmp .. "/bin/bare", "print $@; exit 4", "x", "y" })
  assert(bare.code == 4 and bare.stdout == "x y\n", tostring(bare.stdout))
  local empty = run({ probe })
  assert(empty.ok and empty.stdout == "", tostring(empty.stdout))
end

--- What is put in for `$@` or a variable is not read for a `$` again:
--- an argument naming a variable is printed as it was given, and reads
--- nothing of the environment. Blanks after the verb and its first word
--- go, and the rest keeps its own.
local function test_what_is_put_in_is_not_expanded_again(tmp: string)
  local probe = built(tmp)
  local r = run({ probe, "print  $@;print $@$SET;print $SET$@x;print a   b  c", "$HOME", "$SET" },
    { HOME = "/home", SET = "$HOME" })
  assert(r.ok, tostring(r.stderr))
  assert(r.stdout == "$HOME $SET\n$HOME $SET$HOME\n$HOME$HOME $SETx\na b  c\n", r.stdout)
end

--- An unknown verb ends it with 2, and a command that fails with 1,
--- saying why.
local function test_a_failed_command_ends_it(tmp: string)
  local probe = built(tmp)
  local unknown = run({ probe, "print first; frobnicate; print never" })
  assert(unknown.code == 2 and unknown.stdout == "first\n", tostring(unknown.stdout))
  assert(assert(unknown.stderr):find("unknown verb frobnicate", 1, true), unknown.stderr)
  local missing = run({ probe, "cat " .. tmp .. "/missing; print never" })
  assert(missing.code == 1 and missing.stdout == "", tostring(missing.stdout))
  assert(assert(missing.stderr):find(tmp .. "/missing", 1, true), missing.stderr)
end

--- The verbs over files and directories.
local function test_the_file_verbs(tmp: string)
  local probe = built(tmp)
  local d = tmp .. "/d"
  local r = run({ probe, table.concat({
    "mkdirs " .. d .. "/sub",
    "write " .. d .. "/f one two",
    "append " .. d .. "/f three",
    "append " .. d .. "/log first",
    "copy " .. d .. "/f " .. d .. "/g",
    "mkfifo " .. d .. "/pipe",
    "cat " .. d .. "/g",
    "cat-quiet " .. d .. "/nothing",
    "cat-quiet " .. d .. "/log",
    "ls " .. d,
    "grep-count " .. d .. "/g t",
    "grep-count " .. d .. "/g one",
    "cwd",
    "cwd " .. d .. "/where",
    "exists " .. d .. "/nothing 5",
    "print still here",
    "exists " .. d .. "/f 6",
    "print never",
  }, "\n") }, {})
  assert(r.code == 6, tostring(r.stderr))
  local here = assert(sys.getcwd())
  assert(r.stdout == "one two\nthree\nfirst\nf\ng\nlog\npipe\nsub\n2\n1\n" .. here ..
    "\nstill here\n", r.stdout)
  assert(Fs.read(d .. "/where") == here .. "\n")
  -- A named pipe is none of a file, a directory or a link.
  assert(assert(Fs.stat(d .. "/pipe")).kind == "other", assert(Fs.stat(d .. "/pipe")).kind)
  assert(assert(Fs.stat(d .. "/sub")).kind == "dir")
  -- `cat` alone copies its input to its end.
  local fed = run({ probe, "cat; print end" }, {}, "fed\nthrough")
  assert(fed.ok and fed.stdout == "fed\nthroughend\n", tostring(fed.stdout))
end

--- It ends of a signal it sends itself, or, holding SIGINT and SIGTERM
--- with `trap`, with the trap's status; one sent to its group reaches
--- it too, and one sent to a pid reaches that process alone.
local function test_the_signal_verbs(tmp: string)
  local probe = built(tmp)
  local term = run({ probe, "signal TERM; print never" })
  assert(term.signal == sys.SIGTERM and term.stdout == "", tostring(term.code))
  local killed = run({ probe, "signal KILL" })
  assert(killed.signal == sys.SIGKILL, tostring(killed.code))
  local trapped = run({ probe, "trap 7; signal INT; print never" })
  assert(trapped.code == 7 and trapped.stdout == "", tostring(trapped.code))
  local unknown = run({ probe, "signal NONE" })
  assert(unknown.code == 1, tostring(unknown.code))
  -- 0 and -1 name no one process or group, from a word or a file.
  for _, target in ipairs({ "0", "-1" }) do
    local refused = run({ probe, "signal TERM " .. target .. "; print never" })
    assert(refused.code == 1 and refused.stdout == "", tostring(refused.code))
    assert(assert(refused.stderr):find("refusing pid " .. target, 1, true), refused.stderr)
    assert(Fs.write(tmp .. "/pid", target .. "\n"))
    local from_file = run({ probe, "signal TERM @" .. tmp .. "/pid; print never" })
    assert(from_file.code == 1 and from_file.stdout == "", tostring(from_file.code))
    assert(assert(from_file.stderr):find("refusing pid " .. target, 1, true), from_file.stderr)
  end
  local unnamed = run({ probe, "signal TERM someone" })
  assert(unnamed.code == 1, tostring(unnamed.code))

  -- A group named by the file it waits for, which is its own: Child.start
  -- starts it in a process group of its own, which it leads.
  local group = tmp .. "/group"
  local grouped = assert(Child.start({ probe, "trap 0; wait-for " .. group ..
    "; signal INT @" .. group .. "; exit 3" }, { env = {} }))
  assert(Fs.write(group .. ".writing", "-" .. tostring(grouped.pid) .. "\n"))
  assert(Fs.rename(group .. ".writing", group))
  local grouped_ended = assert(grouped:wait(30000))
  assert(grouped_ended.code == 0,
    tostring(grouped_ended.code) .. " " .. tostring(grouped_ended.signal))

  -- One sleeping, then waiting, under a trap that the signal ends.
  local ready = tmp .. "/ready"
  local sleeper = assert(Child.start({ probe, "trap 9; sleep 20; write " .. ready ..
    " ready; wait-for " .. tmp .. "/never; sleep-forever" }, { env = {} }))
  await(ready)
  local started = Time.monotonic_ns()
  local other = run({ probe, "signal TERM " .. tostring(sleeper.pid) .. "; print sent" })
  assert(other.ok and other.stdout == "sent\n", tostring(other.stdout))
  local ended = assert(sleeper:wait(30000))
  assert(ended.code == 9, tostring(ended.code) .. " " .. tostring(ended.signal))
  assert(Time.monotonic_ns() - started < 10 * 1000 * 1000 * 1000)

  -- `sleep-forever` untrapped ends of the signal itself.
  local forever = assert(Child.start({ probe, "sleep-forever" }, { env = {} }))
  assert(forever:stop(sys.SIGTERM))
  local stopped = assert(forever:wait(30000))
  assert(stopped.signal == sys.SIGTERM, tostring(stopped.code))
end

--- `sleep` takes as long as it says, and `wait-for` until its file is
--- there.
local function test_it_sleeps_and_waits(tmp: string)
  local probe = built(tmp)
  local started = Time.monotonic_ns()
  local slept = run({ probe, "sleep 60; print woke" })
  assert(slept.ok and slept.stdout == "woke\n", tostring(slept.stdout))
  assert(Time.monotonic_ns() - started >= 60 * 1000 * 1000)
  local flag = tmp .. "/flag"
  local waiting = assert(Child.start({ probe, "write " .. tmp .. "/waiting w; wait-for " ..
    flag .. "; print seen" }, { env = {}, stdout = "capture" }))
  await(tmp .. "/waiting")
  assert(Fs.write(flag, ""))
  local seen = assert(waiting:wait(30000))
  assert(seen.ok and seen.stdout == "seen\n", tostring(seen.stdout))
end

--- `run` starts a program and goes on past one that succeeds, ending
--- with the status of one that fails, 128 past a signal, or 127 for one
--- that cannot start; `fd-closed` holds for a closed descriptor alone;
--- and `status-field` reads its own line of /proc/self/status.
local function test_the_process_verbs(tmp: string)
  local probe = built(tmp)
  local ran = run({ probe, "run " .. probe .. " print from the child; print back" })
  assert(ran.ok and ran.stdout == "from the child\nback\n", tostring(ran.stdout))
  local failed = run({ probe, "run " .. probe .. " exit 5; print never" })
  assert(failed.code == 5, tostring(failed.code))
  local signalled = run({ probe, "run " .. probe .. " signal TERM" })
  assert(signalled.code == 128 + sys.SIGTERM, tostring(signalled.code))
  local plain = run({ probe, "run " .. probe .. "; print none" })
  assert(plain.ok and plain.stdout == "none\n", tostring(plain.stdout))
  local absent = run({ probe, "run " .. tmp .. "/absent" })
  assert(absent.code == 127, tostring(absent.code))

  local closed = run({ probe, "fd-closed 9; print closed; fd-closed 1; print never" })
  assert(closed.code == 1 and closed.stdout == "closed\n", tostring(closed.stdout))
  for _, word in ipairs({ "abc", "-1", "" }) do
    local unnamed = run({ probe, "fd-closed " .. word .. "; print never" })
    assert(unnamed.code == 2 and unnamed.stdout == "", word .. ": " .. tostring(unnamed.code))
    assert(assert(unnamed.stderr):find("no descriptor", 1, true), unnamed.stderr)
  end

  if Fs.exists("/proc/self/status") then
    local field = run({ probe, "status-field SigIgn; status-field NoSuchField" })
    assert(field.code == 1, tostring(field.code))
    assert(assert(field.stdout):match("^SigIgn:%s*%x+\n$"), field.stdout)
  end
end

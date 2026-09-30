--- `build/stand_in.tl`: the stand-in program a test starts where it
--- would otherwise write a shell script, each of its verbs, and what it
--- reads its script and words from.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")
local stand_in = require("build.stand_in")
local artifact = require("build.artifact")

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

--- A build that cannot be written says why.
local function test_a_failed_build_says_why(tmp: string)
  local dir = tmp .. "/stand-in"
  assert(Fs.write(dir, "a file where its directory would be\n"))
  local probe, trouble = stand_in.build(dir)
  assert(probe == nil, probe)
  assert(trouble:find(dir, 1, true), trouble)
end

--- Commands chain as a shell's do: `&&` goes on to the next only past a
--- command that went on, and `||` only past one that would have ended
--- the script, saying nothing of the failure it takes up; a chain that
--- ends the script ends it with its last command's status, saying why.
local function test_commands_chain_as_a_shell_s_do(tmp: string)
  local probe = built(tmp)
  local missing = tmp .. "/missing"
  local r = run({ probe, table.concat({
    "print a && print b || print never",
    "cat " .. missing .. " && print never || print caught",
    "exit 3 || print past-exit",
    "print |one&&two || print never",
    "cat " .. missing .. " || cat " .. missing .. " && print never",
    "print never",
  }, "\n") })
  assert(r.code == 1, tostring(r.code))
  assert(r.stdout == "a\nb\ncaught\npast-exit\n|one&&two\n", r.stdout)
  -- Only the failure that ended it is said.
  local said = assert(r.stderr)
  local _, count = said:gsub("probe: ", "")
  assert(count == 1 and said:find(missing, 1, true), said)
end

--- The verbs that ask of a path: whether it is there, whether it opens
--- to write -- never making it -- its permission bits, and, walking a
--- directory, the regular files beneath it that open to write, passing
--- over a link, whatever it leads to, and a named pipe, which it never
--- opens.
local function test_the_verbs_that_ask_of_a_path(tmp: string)
  local probe = built(tmp)
  local d = tmp .. "/d"
  assert(Fs.mkdirs(d .. "/sub/deeper"))
  assert(Fs.write(d .. "/sub/deeper/f", "x"))
  assert(sys.mkfifo(d .. "/sub/fifo"))
  assert(Fs.symlink(d .. "/sub/deeper/f", d .. "/file-link"))
  assert(Fs.symlink(d .. "/sub", d .. "/dir-link"))
  assert(sys.chmod(d .. "/sub", 0x1e8)) -- 0o750
  local r = run({ probe, table.concat({
    "present " .. d .. "/sub && print there",
    "present " .. d .. "/missing || print absent",
    "writable " .. d .. "/sub/deeper/f && print opens",
    "writable " .. d .. "/sub || print a-directory-does-not",
    "writable " .. d .. "/missing || print nor-a-missing-file",
    "mode " .. d .. "/sub",
    "find-writable " .. d,
  }, "\n") })
  assert(r.ok, tostring(r.stderr))
  assert(r.stdout == "there\nabsent\nopens\na-directory-does-not\nnor-a-missing-file\n750\n" ..
    d .. "/sub/deeper/f\n", r.stdout)
  assert(not Fs.exists(d .. "/missing"), "writable made the file")
  assert(Fs.read(d .. "/sub/deeper/f") == "x", "writable wrote to the file")
  local absent = run({ probe, "present " .. d .. "/missing" })
  assert(absent.code == 1 and assert(absent.stderr):find(d .. "/missing", 1, true),
    tostring(absent.stderr))
end

--- `start` goes on without waiting, and what it started outlives the
--- script; `run`, as a shell runs a program, leaves what that program
--- started running once it ends.
local function test_what_start_and_run_leave_running_runs_on(tmp: string)
  local probe = built(tmp)
  assert(Fs.mkdirs(tmp .. "/bin"))
  local late = tmp .. "/bin/late"
  assert(stand_in.place(probe, late, "wait-for $DIR/go-$@\nwrite $DIR/done-$@ done"))
  for _, how in ipairs({ "start " .. late .. " started", "run " .. probe .. " start " .. late ..
      " ran" }) do
    local word = how:match("(%S+)$")
    -- In no group of its own, which a wait would end with it.
    local r = assert(Child.run({ probe, how .. "; print gone on" },
      { env = {}, process_group = false, stdout = "capture", timeout_ms = 30000 }))
    assert(r.ok and r.stdout == "gone on\n", tostring(r.stdout))
    assert(not Fs.exists(tmp .. "/bin/done-" .. word), "it did not wait")
    assert(Fs.write(tmp .. "/bin/go-" .. word, ""))
    await(tmp .. "/bin/done-" .. word)
  end
end

--- A signal it sends itself that does not end it -- held by `trap -`,
--- which goes on -- ends it in two seconds all the same, with status 4
--- and a line saying so, rather than leave it waiting.
local function test_a_signal_to_itself_that_does_not_land_ends_it_soon(tmp: string)
  local probe = built(tmp)
  local started = Time.monotonic_ns()
  local r = run({ probe, "trap -; signal TERM; print never" })
  local took = Time.monotonic_ns() - started
  assert(r.code == 4 and r.stdout == "", tostring(r.code) .. " " .. tostring(r.stdout))
  assert(assert(r.stderr):find("SIGTERM sent to itself did not end it", 1, true), r.stderr)
  assert(took >= 2 * 1000 * 1000 * 1000 and took < 20 * 1000 * 1000 * 1000, tostring(took))
  -- A trap that ends it still does.
  local trapped = run({ probe, "trap -; trap 6; signal INT" })
  assert(trapped.code == 6, tostring(trapped.code))
end

--- `write-fd` writes to a descriptor it was handed, and `env-of` tells a
--- variable set, set empty and unset apart.
local function test_it_writes_to_a_descriptor_and_names_a_variable(tmp: string)
  local probe = built(tmp)
  local fd = assert(sys.open(tmp .. "/handed", sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local r = run({ probe, "env-of SET; env-of EMPTY; env-of UNSET" }, { SET = "x", EMPTY = "" })
  assert(r.ok, tostring(r.stderr))
  assert(r.stdout == "SET=x\nEMPTY=\nUNSET unset\n", r.stdout)
  -- Handed one at 3, it writes there.
  local handed = assert(Child.run({ probe, "write-fd 3 to three" },
    { env = {}, fds = { [3] = fd }, stderr = "capture", timeout_ms = 30000 }))
  assert(handed.ok, tostring(handed.stderr))
  assert(assert(sys.pread(fd, 64, 0)) == "to three\n")
  -- `connect` says why a unix socket file cannot be connected to.
  local missing = run({ probe, "connect " .. tmp .. "/none.sock" }, {})
  assert(missing.ok and missing.stdout == tmp .. "/none.sock: No such file or directory\n",
    missing.stdout)
  -- `connect-tcp` says why a port cannot be connected to, and refuses
  -- a port that is none.
  local refused = run({ probe, "connect-tcp 127.0.0.1 1" }, {})
  assert(refused.ok and refused.stdout == "127.0.0.1:1: Connection refused\n", refused.stdout)
  local portless = run({ probe, "connect-tcp 127.0.0.1 70000" })
  assert(portless.code == 1 and assert(portless.stderr):find("no port 70000", 1, true),
    tostring(portless.stderr))
  assert(sys.close(fd))
  local unnamed = run({ probe, "write-fd x y" })
  assert(unnamed.code == 1 and assert(unnamed.stderr):find("no descriptor x", 1, true),
    tostring(unnamed.stderr))
end

--- A file whose first line is `#!<stand-in>`, and nothing more, runs its
--- body, as a shell script does, with its arguments -- started by its
--- path, or with the stand-in handed its path -- whatever a system does
--- with words after `#!`, which this line has none of; an empty body is
--- status 0.
local function test_a_file_naming_it_on_its_first_line_runs_its_body(tmp: string)
  local probe = built(tmp)
  local script = tmp .. "/script"
  assert(Fs.write(script, "#!" .. probe .. "\nprint body $@\nexit 5\n", 0x1ed))
  local direct = run({ script, "a", "b" })
  assert(direct.code == 5 and direct.stdout == "body a b\n", tostring(direct.stdout))
  local handed = run({ probe, script, "c" })
  assert(handed.code == 5 and handed.stdout == "body c\n", tostring(handed.stdout))
  -- A line naming it and nothing after: the line ends in a newline, as
  -- macOS's exec refuses a `#!` line no newline ends (ENOEXEC), where
  -- Linux takes the file's end for one.
  local empty = tmp .. "/empty"
  assert(Fs.write(empty, "#!" .. probe .. "\n", 0x1ed))
  local ran = run({ empty })
  assert(ran.ok and ran.stdout == "", tostring(ran.stdout))
end

--- The stand-in is a host program whose main module is named under
--- neither `build.*` nor `cosmic.*`, so it loads untrusted, as one
--- `cosmic build --host` makes: it carries no `build.*` row at all, and
--- does carry the modules the core itself requires of a program
--- ([`cosmic.errors`], [`cosmic.removed`]).
local function test_the_stand_in_s_main_loads_as_a_built_program_s(tmp: string)
  local parts = assert(artifact.split((assert(Fs.read(built(tmp))))))
  assert(parts.host)
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, parts.database))
  local db = assert(Sqlite.open(path))
  local function one(sql: string): string
    local rows = assert(Sqlite.text_rows(db, sql))
    return rows[1] and rows[1][1] or ""
  end
  assert(one("SELECT value FROM meta WHERE key = 'main'") == "stand_in.main")
  assert(one("SELECT kind FROM modules WHERE path = 'stand_in.main'") == "main")
  assert(one("SELECT count(*) FROM modules WHERE path LIKE 'build.%'") == "0")
  assert(one("SELECT count(*) FROM modules WHERE path IN " ..
    "('cosmic.errors', 'cosmic.removed', 'cosmic.child')") == "3")
  assert(one("SELECT value FROM meta WHERE key = 'runtime_basis'") ~= "")
  assert(db:close())
end

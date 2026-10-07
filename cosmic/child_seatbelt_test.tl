--- [`Child.start`]'s `policy` on macOS (cosmic/child.tl), which holds a
--- child by Seatbelt: a process of this program applies the compiled
--- profile (cosmic/seatbelt.tl) to itself and executes the child's program
--- last (core/syscalls.c's trampoline). macOS alone has Seatbelt, and no
--- `requires` name stands for it, so every test here calls [`Test.skip`] on any
--- other host, where Landlock and seccomp hold a child
--- (cosmic/child_policy_test.tl). The one that holds on every host --
--- spawn's `seatbelt` is no argument where there is none -- runs on all of
--- them.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")

--- The system's own paths, which the child's program, its loader and its
--- libraries are read and run from, and the temporary directory.
Test.policy{ env = { "TMPDIR" }, profiles = { "system" } }

local type Searcher = function(string): any, any

--- The process table cosmic.child starts a child through.
local function process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: the table core/process.h declares
    end
  end
  error("cosmic.child has no process table")
end

--- Ends the test where Seatbelt does not hold a child.
local function macos_only()
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("Seatbelt holds a child on macOS alone")
  end
end

--- A program Seatbelt's "system" profile runs.
local CAT <const> = "/bin/cat"
local SH <const> = "/bin/sh"

--- What Seatbelt denied lately, as the system's log names it: the
--- operation and path of each refusal, which says what a profile lacks.
--- Empty where the log cannot be read.
local function denials(): string
  local result = Child.run({ "/usr/bin/log", "show", "--last", "1m", "--style", "compact",
    "--predicate", "eventMessage CONTAINS \"Sandbox: cat(\" OR eventMessage CONTAINS \"Sandbox: sh(\" " ..
      "OR eventMessage CONTAINS \"Sandbox: cosmic\" OR eventMessage CONTAINS \"Sandbox: bash(\" " ..
      "OR eventMessage CONTAINS \"Sandbox: test(\" OR process == \"cat\" OR process == \"sh\"" }, { stdout = "capture", stderr = "capture",
        stdin = "null", timeout_ns = Clock.seconds(60) })
  if result == nil then return "" end
  local lines: {string} = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  local first = math.max(1, #lines - 60)
  return "\nlog: " .. table.concat(lines, "\n", first, #lines) .. "\nlog stderr: " ..
    (result.stderr or ""):sub(1, 300)
end

--- How a run ended, for the message of a failed assertion.
local function describe(result: Child.Result): string
  return "code " .. tostring(result.code) .. ", signal " .. tostring(result.signal) ..
    ", stdout " .. string.format("%q", result.stdout or "") ..
    ", stderr " .. string.format("%q", result.stderr or "") ..
    (result.ok and "" or denials())
end

--- `held`, or a failure that says how `result` ended and what was denied.
local function expect(held: boolean, result: Child.Result)
  if held then assert(held) else assert(held, describe(result)) end
end

--- `argv` run to its end under `policy`, its output captured.
local function run(argv: {string}, policy: Sandbox.Policy): Child.Result
  local result, why = Child.run(argv, { policy = policy, stdout = "capture", stderr = "capture",
    stdin = "null", timeout_ns = Clock.seconds(30) })
  return (assert(result, why))
end

--- Two files in `tmp`, one of which a policy grants.
local function files(tmp: string): string, string
  local granted, other = tmp .. "/granted", tmp .. "/other"
  assert(Fs.write(granted, "granted-bytes"))
  assert(Fs.write(other, "other-bytes"))
  return granted, other
end

local function test_a_granted_file_is_read(tmp: string)
  macos_only()
  local granted = files(tmp)
  local result = run({ CAT, granted }, { profiles = { "system" },
    grants = { { path = granted, letters = "r" } } })
  expect(result.ok and result.stdout == "granted-bytes", result)
end

local function test_another_file_is_refused_as_not_permitted(tmp: string)
  macos_only()
  local granted, other = files(tmp)
  local result = run({ CAT, other }, { profiles = { "system" },
    grants = { { path = granted, letters = "r" } } })
  expect(not result.ok and (result.stderr or ""):find("Operation not permitted", 1, true) ~= nil, result)
  expect(not (result.stdout or ""):find("other-bytes", 1, true), result)
end

local function test_no_file_is_written_without_a_grant_to_write(tmp: string)
  macos_only()
  local granted = files(tmp)
  local created = tmp .. "/created"
  local policy: Sandbox.Policy = { profiles = { "system" }, grants = { { path = granted, letters = "r" } } }
  -- Over the granted file, which is read-only, and as a new one.
  local over = run({ SH, "-c", "echo changed > \"$1\"", "sh", granted }, policy)
  expect(not over.ok, over)
  assert(Fs.read(granted) == "granted-bytes", "the granted file was written")
  local made = run({ SH, "-c", "echo made > \"$1\"", "sh", created }, policy)
  expect(not made.ok, made)
  assert(sys.stat(created) == nil, "a file was created without a grant to")
  -- A grant to write is what changes it, so the refusals above are Seatbelt's.
  local allowed = run({ SH, "-c", "echo changed > \"$1\"", "sh", granted }, { profiles = { "system" },
    grants = { { path = granted, letters = "rwc" } } })
  expect(allowed.ok, allowed)
  assert(Fs.read(granted) == "changed\n", "the granted file was not written")
end

--- What `policy` is refused for, in [`Child.start`]'s words.
local function refusal(policy: Sandbox.Policy): string
  local child, why = Child.start({ CAT }, { policy = policy })
  assert(child == nil, "the start was not refused")
  return why
end

local function test_what_seatbelt_cannot_hold_fails_the_start_with_its_own_refusal(tmp: string)
  macos_only()
  local granted = files(tmp)
  local function says(field: Sandbox.Policy, expected: string)
    local policy: Sandbox.Policy = field
    policy.profiles = { "system" }
    policy.grants = { { path = granted, letters = "r" } }
    local why = refusal(policy)
    assert(why:find("^child: start: sandbox: seatbelt: ") and why:find(expected, 1, true), why)
  end
  says({ isolate = { "proc" } }, "isolate needs namespaces")
  says({ isolate = { "file" } }, "isolate needs namespaces")
  says({ connect = { "example.com:443" } }, "connect needs the network relay")
  says({ loopback = { "127.0.0.1" } }, "loopback needs a network namespace")
  says({ promises = { "nest" } }, "nest cannot be held by Seatbelt")
  says({ limits = { processes = 8 } }, "limits.processes needs a user namespace")
  says({ tmp = true }, "tmp needs a prepared temporary directory")
  says({ set_env_digests = { X = string.rep("0", 64) } }, "set_env_digests holds a digest")
  -- A database is a regular file the policy names, which a merge reads.
  local sealed = tmp .. "/sealed.db"
  assert(Fs.write(sealed, "not a database, but a regular file"))
  says({ database = sealed }, "database needs a prepared core and database")
end

local function test_a_grant_from_another_path_is_refused(tmp: string)
  macos_only()
  local granted = files(tmp)
  local why = refusal({ profiles = { "system" },
    grants = { { path = granted, letters = "r", from = "/granted" } } })
  assert(why:find("^child: start: sandbox: ") and why:find("from", 1, true), why)
end

local function test_more_paths_than_a_start_takes_are_refused(tmp: string)
  macos_only()
  local grants: {Sandbox.Grant} = {}
  for i = 1, 520 do
    local path = tmp .. "/many-" .. i
    assert(Fs.write(path, "x"))
    grants[i] = { path = path, letters = "r" }
  end
  local why = refusal({ profiles = { "system" }, grants = grants })
  assert(why:find("^child: start: sandbox: grants: ") and why:find("past the most", 1, true), why)
end

local function test_this_program_is_not_yet_run_under_a_policy()
  macos_only()
  local child, why = Child.start({ assert(Proc.executable()), "x" },
    { policy = { profiles = { "system", "cosmic" } } })
  assert(child == nil and why:find("this program cannot yet be run under a policy", 1, true), why)
end

local function test_a_grant_that_is_not_there_fails_the_start_naming_it(tmp: string)
  macos_only()
  local why = refusal({ profiles = { "system" }, grants = { { path = tmp .. "/absent", letters = "r" } } })
  assert(why:find("^child: start: sandbox: seatbelt: grant ") and why:find("absent", 1, true), why)
end

local function test_a_program_nobody_granted_fails_the_start_naming_the_grant(tmp: string)
  macos_only()
  local granted = files(tmp)
  local child, why = Child.start({ CAT, granted }, { policy = { grants = { { path = granted, letters = "r" } } } })
  assert(child == nil)
  assert(why:find("^child: start: sandbox: ") and why:find("not granted r and x", 1, true), why)
end

local function test_the_environment_the_policy_gives_is_the_whole_environment(tmp: string)
  macos_only()
  local granted = files(tmp)
  local result = run({ SH, "-c", "echo \"[$KEPT][$OTHER][$HOME]\"" }, { profiles = { "system" },
    grants = { { path = granted, letters = "r" } }, set_env = { KEPT = "kept" } })
  expect(result.ok and result.stdout == "[kept][][]\n", result)
end

local function test_the_limits_the_profile_carries_are_the_childs(tmp: string)
  macos_only()
  local granted = files(tmp)
  local result = run({ SH, "-c", "ulimit -n; ulimit -c" }, { profiles = { "system" },
    grants = { { path = granted, letters = "r" } }, limits = { open_files = 128 } })
  -- No subshell: forking is a promise this policy does not make.
  expect(result.ok and result.stdout == "128\n0\n", result)
end

--- The profile a child is started under is whatever the binding is given,
--- so a refusal of it is the system's own, and the program must not run.
local function test_a_profile_the_system_refuses_fails_the_start_and_never_runs_the_program(tmp: string)
  macos_only()
  local marker = tmp .. "/ran"
  local process = process_table()
  local argv = { SH, "-c", "echo ran > \"$1\"", "sh", marker }
  local pid, why, errno = process.spawn(SH, argv, nil, nil, nil, nil, nil, false, nil,
    { seatbelt = { profile = "(version 1)\n(allow default\n", parameters = {} } })
  assert(pid == nil, "a malformed profile was applied")
  assert(why:find("sandbox_init_with_parameters", 1, true), why)
  assert(errno ~= nil and errno > 0)
  assert(sys.stat(marker) == nil, "the program ran with no profile applied")
end

local function test_a_profile_the_system_accepts_holds_the_program_by_its_parameters(tmp: string)
  macos_only()
  local process = process_table()
  local marker = tmp .. "/marker"
  local profile = "(version 1)\n(allow default)\n(deny file-write* (literal (param \"MARKER\")))\n"
  local real_tmp = assert(sys.realpath(tmp))
  local denied = real_tmp .. "/marker"
  local pid = assert(process.spawn(SH, { SH, "-c", "echo ran > \"$1\"", "sh", marker }, nil, nil,
    nil, nil, nil, false, nil, { seatbelt = { profile = profile, parameters = { MARKER = denied } } }))
  local status = assert(process.waitpid(pid, false))
  assert(status.code ~= 0 and sys.stat(marker) == nil, "the profile's rule did not hold the program")
  local other = tmp .. "/other-marker"
  local ran = assert(process.spawn(SH, { SH, "-c", "echo ran > \"$1\"", "sh", other }, nil, nil,
    nil, nil, nil, false, nil, { seatbelt = { profile = profile, parameters = { MARKER = denied } } }))
  assert(assert(process.waitpid(ran, false)).code == 0 and sys.stat(other) ~= nil)
end

--- A policy's child has no terminal to open, by name or otherwise: the
--- profile grants no /dev/tty, and the start gives the child a session of
--- its own, which the caller's terminal is not.
local function test_a_policy_child_leads_a_session_and_opens_no_terminal(tmp: string)
  macos_only()
  local granted = files(tmp)
  local policy: Sandbox.Policy = { profiles = { "system" },
    grants = { { path = granted, letters = "r" } } }
  local shut = run({ SH, "-c", ": </dev/tty" }, policy)
  expect(not shut.ok, shut)
  -- Granted by hand, the open still finds no controlling terminal.
  local granting: Sandbox.Policy = { profiles = { "system" }, grants = {
    { path = granted, letters = "r" }, { path = "/dev/tty", letters = "rw" } } }
  local none = run({ SH, "-c", ": </dev/tty" }, granting)
  expect(not none.ok, none)
  local child = assert(Child.start({ "/bin/sleep", "30" }, { policy = policy }))
  local pid = child.pid
  local group = sys.getpgid(pid)
  child:stop(sys.SIGKILL)
  child:wait()
  assert(group == pid, "the child leads no group of its own: " .. tostring(group))
end

--- A policy's child is a group of its own whatever the caller asks, so a
--- caller that asks for its own group is refused.
local function test_a_policy_start_that_keeps_the_callers_group_is_refused(tmp: string)
  macos_only()
  local granted = files(tmp)
  local child, why = Child.start({ CAT, granted }, { process_group = false,
    policy = { profiles = { "system" }, grants = { { path = granted, letters = "r" } } } })
  assert(child == nil, "a start that keeps the caller's group ran")
  assert(why:find("process_group = false is refused", 1, true), why)
end

--- The C program a terminal child runs, which reports what it can do with
--- the terminal it was given, one `name=value` to a line: ttyname(0), whether
--- /dev/tty opens (and the errno where it does not), tcgetpgrp(0) and
--- tcgetsid(0) against its own session.
local REPORT <const> = [=[
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main (void) {
  errno = 0;
  const char *name = ttyname(0);
  printf("ttyname=%s\n", name != NULL ? name : "none");
  int fd = open("/dev/tty", O_RDWR | O_NOCTTY);
  if (fd >= 0) printf("devtty=ok\n");
  else printf("devtty=fail errno=%d\n", errno);
  errno = 0;
  pid_t group = tcgetpgrp(0);
  if (group > 0) printf("tcgetpgrp=ok\n");
  else printf("tcgetpgrp=fail errno=%d\n", errno);
  errno = 0;
  pid_t session = tcgetsid(0);
  printf("tcgetsid=%s\n", session == getsid(0) ? "own" : "other");
  fflush(stdout);
  return 0;
}
]=]

--- The reporting program, compiled into `tmp`.
local function report_program(tmp: string): string
  local source, binary = tmp .. "/report.c", tmp .. "/report"
  assert(Fs.write(source, REPORT))
  local result = assert(Child.run({ "/usr/bin/cc", "-O0", "-o", binary, source }, {
    stdout = "capture", stderr = "capture", stdin = "null", timeout_ns = Clock.seconds(120),
    env = { PATH = "/usr/bin:/bin", TMPDIR = tmp } }))
  assert(result.code == 0, "cc: " .. (result.stderr or "") .. (result.stdout or ""))
  return (assert(sys.realpath(binary)))
end

--- What `binary` reports of its terminal when started on a pty of its own
--- with the standard `streams` on it, under `policy` where given, and how it
--- ended.
local function on_pty(binary: string, streams: {integer}, policy?: Sandbox.Policy): string, Child.Result
  local on: {integer:boolean} = {}
  for _, number in ipairs(streams) do on[number] = true end
  local opts: Child.Options = { policy = policy, timeout_ns = Clock.seconds(30) }
  if not on[0] then opts.stdin = "null" end
  if not on[2] then opts.stderr = "null" end
  local started, why = Child.start_on_pty({ binary }, opts, { streams = streams })
  assert(started, why)
  local result = assert(started.child:wait())
  local said = ""
  while true do
    local ready, _ = Poll.readable(started.master, Clock.ms(300))
    if not ready then break end
    local data, _ = sys.read(started.master, 4096)
    if data == nil or data == "" then break end
    said = said .. data
  end
  assert(sys.close(started.master))
  return (said:gsub("\r", "")), result
end

--- A policy that runs `binary` and grants nothing else.
local function running(binary: string): Sandbox.Policy
  return { profiles = { "system" }, grants = { { path = binary, letters = "rx" } } }
end

--- Asserts that `said` holds the Lua pattern `pattern`, answering all of it
--- otherwise.
local function holds(said: string, pattern: string)
  assert(said:find(pattern), "missing " .. pattern .. " in " .. string.format("%q", said))
end

--- A policy's child started on a pty has it as its controlling terminal:
--- /dev/tty opens, ttyname names the slave, and the terminal answers
--- tcgetpgrp and tcgetsid, as the profile grants them.
local function test_a_policy_child_on_a_pty_has_it_as_its_controlling_terminal(tmp: string)
  macos_only()
  local binary = report_program(tmp)
  local said, result = on_pty(binary, { 0, 1, 2 }, running(binary))
  assert(result.code == 0, describe(result) .. string.format(" %q", said))
  holds(said, "ttyname=/dev/ttys%d+")
  holds(said, "devtty=ok")
  holds(said, "tcgetpgrp=ok")
  holds(said, "tcgetsid=own")
end

--- The terminal is the pty's alone: where stdin is not on it the child has
--- none, so /dev/tty is refused it as for any policy's child.
local function test_a_policy_child_with_stdin_off_the_pty_has_no_controlling_terminal(tmp: string)
  macos_only()
  local binary = report_program(tmp)
  local said, result = on_pty(binary, { 1 }, running(binary))
  assert(result.code == 0, describe(result) .. string.format(" %q", said))
  holds(said, "devtty=fail")
end

--- A start with no policy gets the pty as its controlling terminal on macOS
--- too, through the same steps of the trampoline.
local function test_a_child_without_a_policy_on_a_pty_has_it_as_its_controlling_terminal(tmp: string)
  macos_only()
  local binary = report_program(tmp)
  local said, result = on_pty(binary, { 0, 1, 2 })
  assert(result.code == 0, describe(result) .. string.format(" %q", said))
  holds(said, "ttyname=/dev/ttys%d+")
  holds(said, "devtty=ok")
  holds(said, "tcgetpgrp=ok")
  holds(said, "tcgetsid=own")
end

--- The process table a test starts a child through hands its twelfth
--- argument on: a terminal asked of a path that is none starts nothing.
local function test_a_terminal_asked_of_no_terminal_starts_nothing()
  local process = process_table()
  local function start(...: any): integer | nil, string, integer
    return (process.spawn as function(...: any): integer | nil, string, integer)(...)
  end
  local pid, why = start(SH, { SH, "-c", "exit 0" }, nil, nil, nil, nil, nil, true,
    nil, nil, nil, "/dev/null")
  if pid ~= nil then process.waitpid(pid, false) end
  assert(pid == nil, "a terminal start of a descriptor that is none ran: " .. tostring(why))
end

--- A profile is macOS's: where Landlock and seccomp hold a child there is
--- none to give, and a call that does is wrong rather than refused.
local function test_a_seatbelt_profile_is_no_argument_where_there_is_no_seatbelt()
  if assert(sys.uname()).sysname == "Darwin" then
    Test.skip("macOS takes a profile: the tests above start a child under one")
  end
  local process = process_table()
  local ok, why = pcall(process.spawn, "/nowhere", { "/nowhere" }, nil, nil, nil, nil, nil, false, nil,
    { seatbelt = { profile = "(version 1)\n", parameters = {} } })
  assert(not ok and tostring(why):find("seatbelt is macOS's", 1, true), tostring(why))
end

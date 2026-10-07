--- [`Child.start_on_pty`] on macOS (core/syscalls.c's trampoline, cosmic/seatbelt.tl's
--- terminal rules): a child started on a pty has it as its controlling
--- terminal, under a policy or not. The tests compile a C program with the
--- system's cc, which reports what the child can do with its terminal, so
--- they need it and run on macOS alone.
---
--- The trampoline's TIOCSCTTY runs only where the slave's
--- open did not already acquire it, which a fresh pty's does, so no test
--- reaches it; the open's acquisition is what these tests show.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")

--- The system's own paths, the program's PATH for the host-program check,
--- and the temporary directory.
Test.policy{ env = { "TMPDIR", "PATH" }, profiles = { "system" }, requires = { "program:cc" } }

--- Ends the test where Seatbelt does not hold a child.
local function macos_only()
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("Seatbelt holds a child on macOS alone")
  end
end

--- How a run ended, for the message of a failed assertion.
local function describe(result: Child.Result): string
  return "code " .. tostring(result.code) .. ", signal " .. tostring(result.signal) ..
    ", timed out " .. tostring(result.timed_out)
end

--- The C program a terminal child runs, which reports what it can do with
--- the terminal it was given, one `name=value` to a line: ttyname(0), whether
--- /dev/tty opens (and the errno where it does not), tcgetpgrp(0) and
--- tcgetsid(0) against its own session.
local REPORT <const> = [=[
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

int main (void) {
  errno = 0;
  const char *name = ttyname(0);
  printf("ttyname=%s\n", name != NULL ? name : "none");
  if (name != NULL) {
    int again = open(name, O_RDWR | O_NOCTTY);
    if (again >= 0) printf("slave=ok\n");
    else printf("slave=fail errno=%d\n", errno);
    errno = 0;
    if (chmod(name, 0666) == 0) printf("chmod=ok\n");
    else printf("chmod=fail errno=%d\n", errno);
  }
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
  local opts: Child.Options = { policy = policy, timeout_ns = Clock.seconds(5) }
  if not on[0] then opts.stdin = "null" end
  if not on[2] then opts.stderr = "null" end
  local started = assert(Child.start_on_pty({ binary }, opts, { streams = streams }))
  -- Read as the child writes: Darwin drops what a slave wrote and the master
  -- had not read when the slave's last descriptor closes.
  local said = ""
  local function read_some(wait_ns: integer): boolean
    local ready, _ = Poll.readable(started.master, wait_ns)
    if not ready then return false end
    local data, _ = sys.read(started.master, 4096)
    if data == nil or data == "" then return false end
    said = said .. data
    return true
  end
  local result: Child.Result
  while result == nil do
    local done, _ = Child.wait_any({ started.child }, Clock.ms(1))
    if done ~= nil then
      result = assert(done:wait())
    else
      read_some(Clock.ms(50))
    end
  end
  while read_some(Clock.ms(200)) do end
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
  -- EPERM, which the profile gives where it has no /dev/tty rule; with the
  -- rule and no terminal it would be ENXIO.
  holds(said, "devtty=fail errno=1\n")
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

--- A policy child cannot change its slave's mode (the terminal's rules grant
--- its data and ioctls, not its attributes), though it reads and writes it.
local function test_a_policy_child_cannot_chmod_its_slave_but_uses_it(tmp: string)
  macos_only()
  local binary = report_program(tmp)
  local said, result = on_pty(binary, { 0, 1, 2 }, running(binary))
  assert(result.code == 0, describe(result) .. string.format(" %q", said))
  holds(said, "slave=ok")
  holds(said, "chmod=fail errno=1\n")
  local plain = on_pty(binary, { 0, 1, 2 })
  holds(plain, "chmod=ok")
end

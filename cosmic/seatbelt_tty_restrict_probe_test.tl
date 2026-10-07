--- DIAGNOSTIC, for the macOS leg: a probe, not a specification. The pull
--- requests that give a Seatbelt-confined child a controlling terminal
--- (core/syscalls.c's `spawn` refuses `terminal` there, ENOSYS) and that
--- give Sandbox.restrict a Seatbelt hold replace this module with tests of
--- their own, asserting the behaviour they build. It answers two questions
--- only the macOS kernel can:
---
--- A. Where a pseudo-terminal slave given as descriptors 0, 1 and 2 stops
--- being a controlling terminal on the way to a program, in five ways to
--- start it: V0, the trampoline's setsid alone; V1, setsid then an open of
--- the slave (no O_NOCTTY) and TIOCSCTTY; V2, V1 under a profile that grants
--- the terminal; V3, V1 under a profile that does not; V4, no trampoline,
--- posix_spawn's POSIX_SPAWN_SETSID with the slave opened as descriptor 0 by
--- a file action. The trampoline is core/syscalls.c's `cosmic_trampoline`,
--- imitated by a C program the test compiles with the system's cc, so no
--- diagnostic is in the core's spawn; it spawns itself as the trampoline as
--- `spawn_program` does (POSIX_SPAWN_CLOEXEC_DEFAULT, the slave given as
--- 0, 1 and 2).
---
--- B. What a process keeps and loses when a Seatbelt profile is applied to
--- it in place (sandbox_init_with_parameters), through the core's
--- `diagnostic_seatbelt_restrict` binding, which exists for this module.
---
--- Found on the macOS leg (macos15, aarch64): V0, V1 and V4 leave the
--- program a terminal (`/dev/tty` opens) with no profile. Under a profile,
--- a bare setsid (V5, V6) leaves it none: ENXIO with the grants, EPERM
--- without. V1's open and TIOCSCTTY before the profile (V2, V3, V7 to V9)
--- keep it, but the profile then decides what the program may do with it:
--- `/dev/tty` opens only with a grant of that literal, and the descriptor
--- answers tcgetsid and tcgetpgrp only with a grant of the slave's own
--- path; ttyname needs `/dev` readable as well. After an in-place
--- restriction (B), open descriptors, the store and a module not loaded
--- before keep working, and a second profile, a path not granted and a
--- start without the fork promise are refused with EPERM.
---
--- Every test asserts what was found, and a failure prints the whole finding.
-- TODO: remove this module, and core/process.h's
-- `diagnostic_seatbelt_restrict`, once the pull requests named above land.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
-- The child of the B tests loads these from the store, which holds this
-- test's closure alone; the last is loaded only after the child restricts.
local _json = require("cosmic.json")
local _sqlite = require("cosmic.sqlite")
local _store = require("cosmic.store")
local _time = require("cosmic.time")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Seatbelt = require("cosmic.seatbelt")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{
  profiles = { "cosmic", "system" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = { "TMPDIR", "PATH" },
}

local function macos_only()
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("a Seatbelt hold is macOS's alone")
  end
end

--- The C program that imitates the trampoline. `run <variant> <report> <script>
--- [<profile file> <count> <name> <value>...]` makes a terminal, starts
--- itself as `tramp` (or, for V4, /bin/sh) with the slave as descriptors 0, 1
--- and 2, and prints the trampoline's report file, then what the program wrote
--- to the terminal.
local HELPER <const> = [=[
#include <errno.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef POSIX_SPAWN_SETSID
#define POSIX_SPAWN_SETSID 0x0400
#endif
extern char **environ;

static int rpt = -1;

static void say (const char *format, ...) {
  char text[2048];
  va_list args;
  va_start(args, format);
  int length = vsnprintf(text, sizeof text, format, args);
  va_end(args);
  if (length > 0 && rpt >= 0) {
    ssize_t ignored = write(rpt, text, (size_t)length);
    (void)ignored;
  }
}

static int tty_sid (int fd) {
  return (int)tcgetsid(fd);
}

static void snapshot (const char *where) {
  int sid = (int)getsid(0);
  int sid_errno = sid < 0 ? errno : 0;
  errno = 0;
  int tsid = tty_sid(0);
  int tsid_errno = tsid < 0 ? errno : 0;
  errno = 0;
  int tpgrp = (int)tcgetpgrp(0);
  int tpgrp_errno = tpgrp < 0 ? errno : 0;
  errno = 0;
  const char *name = ttyname(0);
  int name_errno = name == NULL ? errno : 0;
  errno = 0;
  int fd = open("/dev/tty", O_RDWR | O_NOCTTY);
  int open_errno = fd < 0 ? errno : 0;
  if (fd >= 0) close(fd);
  errno = 0;
  int is = isatty(0);
  say("%s: getsid(0)=%d(errno %d) getpid=%d getpgrp=%d tcgetsid(0)=%d(errno %d) tcgetpgrp(0)=%d(errno %d) "
      "ttyname(0)=%s(errno %d) open(/dev/tty)=%s(errno %d) isatty(0)=%d\n",
      where, sid, sid_errno, (int)getpid(), (int)getpgrp(), tsid, tsid_errno, tpgrp, tpgrp_errno,
      name != NULL ? name : "NULL", name_errno, fd >= 0 ? "ok" : "fail", open_errno, is);
}

typedef int (*init_function) (const char *, unsigned long long, const char *const *, char **);

static int tramp (int argc, char **argv) {
  /* tramp <variant> <slave> <report> <profile or -> <count> <params...> <script> */
  int variant = atoi(argv[2]);
  /* V5 and V6 are V0 (setsid alone) under a profile with and without the
   * terminal's grants; V7, V8 and V9 are V1 under the profiles of the
   * tests of that name, which all name the slave as TTY. */
  int profiled = variant == 2 || variant == 3 || variant >= 5;
  int granted = variant == 2 || variant == 5 || variant >= 7;
  if (variant >= 7) variant = 1;
  else if (variant >= 5) variant = 0;
  const char *slave = argv[3];
  rpt = open(argv[4], O_WRONLY | O_APPEND | O_CREAT, 0600);
  if (rpt >= 0) fcntl(rpt, F_SETFD, FD_CLOEXEC);
  const char *profile_file = argv[5];
  int count = atoi(argv[6]);
  if (argc < 8 + count) return 90;
  const char *script = argv[7 + count];
  snapshot("tramp-start");
  if (variant <= 3) {
    errno = 0;
    int rc = setsid();
    say("setsid()=%d errno=%d\n", rc, rc < 0 ? errno : 0);
    snapshot("after-setsid");
  }
  if (variant >= 1 && variant <= 3) {
    errno = 0;
    int fd = open(slave, O_RDWR);
    say("open(slave, O_RDWR)=%s errno=%d\n", fd >= 0 ? "ok" : "fail", fd >= 0 ? 0 : errno);
    snapshot("after-open-slave");
    if (fd >= 0) {
      int mine = (int)getsid(0);
      int theirs = tty_sid(fd);
      say("tcgetsid(slave)=%d getsid(0)=%d\n", theirs, mine);
      if (theirs != mine) {
        errno = 0;
        int rc = ioctl(fd, TIOCSCTTY, 0);
        say("ioctl(TIOCSCTTY)=%d errno=%d\n", rc, rc < 0 ? errno : 0);
      }
      snapshot("after-tiocsctty");
      close(fd);
      snapshot("after-close-slave");
    }
  }
  if (profiled) {
    FILE *file = fopen(profile_file, "r");
    if (file == NULL) { say("cannot read the profile\n"); return 91; }
    char *text = malloc(1 << 20);
    size_t length = fread(text, 1, (1 << 20) - 1, file);
    text[length] = '\0';
    fclose(file);
    const char *words[64];
    int used = 0;
    for (int i = 0; i < count && used < 60; i++) words[used++] = argv[7 + i];
    if (granted) { words[used++] = "TTY"; words[used++] = slave; }
    words[used] = NULL;
    void *symbol = dlsym(RTLD_DEFAULT, "sandbox_init_with_parameters");
    init_function init = NULL;
    memcpy(&init, &symbol, sizeof init);
    if (init == NULL) { say("no sandbox_init_with_parameters\n"); return 92; }
    char *error = NULL;
    errno = 0;
    int rc = init(text, 0, words, &error);
    say("sandbox_init_with_parameters()=%d errno=%d error=%s\n", rc, rc != 0 ? errno : 0, error ? error : "");
    snapshot("after-profile");
  }
  snapshot("pre-exec");
  char *shell[] = { "sh", "-c", (char *)script, NULL };
  execve("/bin/sh", shell, environ);
  say("execve failed errno=%d\n", errno);
  return 93;
}

static void copy_out (int fd, const char *title) {
  char buffer[4096];
  printf("=== %s ===\n", title);
  fflush(stdout);
  ssize_t got;
  while ((got = read(fd, buffer, sizeof buffer)) > 0) {
    for (ssize_t i = 0; i < got; i++) if (buffer[i] != '\r') putchar(buffer[i]);
  }
  fflush(stdout);
}

int main (int argc, char **argv) {
  if (argc >= 8 && strcmp(argv[1], "tramp") == 0) return tramp(argc, argv);
  if (argc < 5 || strcmp(argv[1], "run") != 0) return 2;
  /* run <self> <variant> <report> <script> [profile count params...] */
  int variant = atoi(argv[3]);
  const char *report = argv[4];
  const char *script = argv[5];
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) { printf("openpt failed %d\n", errno); return 3; }
  char *slave_name = strdup(ptsname(master));
  int slave = open(slave_name, O_RDWR | O_NOCTTY);
  if (slave < 0) { printf("open slave failed %d\n", errno); return 3; }
  fcntl(master, F_SETFD, FD_CLOEXEC);
  fcntl(slave, F_SETFD, FD_CLOEXEC);
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  posix_spawn_file_actions_init(&actions);
  posix_spawnattr_init(&attributes);
  short flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK;
  sigset_t none;
  sigemptyset(&none);
  posix_spawnattr_setsigmask(&attributes, &none);
  pid_t pid;
  int rc;
  if (variant == 4) {
    flags |= POSIX_SPAWN_SETSID;
    posix_spawnattr_setflags(&attributes, flags);
    posix_spawn_file_actions_addopen(&actions, 0, slave_name, O_RDWR, 0);
    posix_spawn_file_actions_adddup2(&actions, 0, 1);
    posix_spawn_file_actions_adddup2(&actions, 0, 2);
    char *shell[] = { "sh", "-c", (char *)script, NULL };
    rc = posix_spawn(&pid, "/bin/sh", &actions, &attributes, shell, environ);
  } else {
    posix_spawnattr_setflags(&attributes, flags);
    for (int t = 0; t < 3; t++) posix_spawn_file_actions_adddup2(&actions, slave, t);
    int count = argc > 7 ? atoi(argv[7]) : 0;
    char *words[80];
    int n = 0;
    char number[16];
    snprintf(number, sizeof number, "%d", variant);
    words[n++] = "tramp";
    words[n++] = number;
    words[n++] = slave_name;
    words[n++] = (char *)report;
    words[n++] = argc > 6 ? argv[6] : "-";
    char counted[16];
    snprintf(counted, sizeof counted, "%d", count);
    words[n++] = counted;
    for (int i = 0; i < count; i++) words[n++] = argv[8 + i];
    words[n++] = (char *)script;
    words[n] = NULL;
    /* The program's own name is argv[0] of the helper, ahead of "tramp". */
    char *with_name[84];
    int m = 0;
    with_name[m++] = argv[2];
    with_name[m++] = "tramp";
    for (int i = 1; i < n; i++) with_name[m++] = words[i];
    with_name[m] = NULL;
    rc = posix_spawn(&pid, argv[2], &actions, &attributes, with_name, environ);
  }
  if (rc != 0) { printf("posix_spawn failed %d\n", rc); return 4; }
  close(slave);
  char *captured = malloc(1 << 20);
  size_t have = 0;
  time_t deadline = time(NULL) + 25;
  int timed_out = 0;
  for (;;) {
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(master, &readable);
    struct timeval wait = { 0, 300000 };
    int ready = select(master + 1, &readable, NULL, NULL, &wait);
    if (ready > 0) {
      ssize_t got = read(master, captured + have, (1 << 20) - have - 1);
      if (got <= 0) break;
      have += (size_t)got;
    } else if (time(NULL) > deadline) {
      timed_out = 1;
      kill(pid, SIGKILL);
      break;
    }
  }
  int status = 0;
  waitpid(pid, &status, 0);
  int fd = open(report, O_RDONLY);
  if (fd >= 0) { copy_out(fd, "trampoline report"); close(fd); }
  printf("=== program output (the terminal) ===\n");
  for (size_t i = 0; i < have; i++) if (captured[i] != '\r') putchar(captured[i]);
  printf("=== end ===\nstatus=%d timed_out=%d\n", status, timed_out);
  return 0;
}
]=]

--- What the program reports of its own terminal, through the shell.
local SCRIPT <const> = "echo sh-pid=$$; ps -o pid,sess,tty,stat -p $$ 2>&1; tty 2>&1; echo tty-rc=$?; " ..
  "( : < /dev/tty ) 2>&1 && echo devtty-ok || echo devtty-fail; sleep 1"

local function compile_helper(tmp: string): string
  local source, binary = tmp .. "/ttyprobe.c", tmp .. "/ttyprobe"
  assert(Fs.write(source, HELPER))
  local result = assert(Child.run({ "/usr/bin/cc", "-O0", "-o", binary, source }, {
    stdout = "capture", stderr = "capture", stdin = "null", timeout_ns = Clock.seconds(120),
    env = { PATH = sys.getenv("PATH") or "/usr/bin:/bin", TMPDIR = tmp } }))
  assert(result.code == 0, "cc: " .. (result.stderr or "") .. (result.stdout or ""))
  return binary
end

--- Asserts that `said` holds the Lua pattern `pattern`, answering all of it
--- otherwise.
local function holds(said: string, pattern: string)
  assert(said:find(pattern), "missing " .. pattern .. "\n" .. said)
end

--- Asserts that the trampoline, once the profile was applied, could (or could
--- not) ask the terminal on descriptor 0 for its session.
local function after_profile_asks(said: string, can: boolean)
  if can then
    holds(said, "after%-profile: getsid%(0%)=(%d+)%(errno 0%).- tcgetsid%(0%)=%d+%(errno 0%)")
    local session, asked = said:match("after%-profile: getsid%(0%)=(%d+)%(errno 0%).- tcgetsid%(0%)=(%d+)%(errno 0%)")
    assert(session == asked, said)
  else
    holds(said, "after%-profile:.- tcgetsid%(0%)=%-1%(errno 1%)")
  end
end

--- The system profile as a Seatbelt profile and its parameters, with
--- `extra` rules after it.
local function system_profile(extra: string): string, {string:string}
  -- fork: the shell starts `ps` and `tty` as children.
  local policy: Sandbox.Policy = { profiles = { "system" }, promises = { "fork" } }
  local options = assert(Seatbelt.resolve(policy))
  local compiled = assert(Seatbelt.compile(policy, options))
  return compiled.text .. extra, compiled.parameters
end

local TERMINAL_RULES <const> = '(allow file-read* file-write* file-ioctl (literal (param "TTY")))\n' ..
  '(allow file-read* file-write* file-ioctl (literal "/dev/tty"))\n'

--- Runs variant `variant` and answers everything it printed.
local function variant(tmp: string, number: integer, profile?: string, parameters?: {string:string}): string
  local binary = compile_helper(tmp)
  local report = tmp .. "/report" .. number
  local argv = { binary, "run", binary, tostring(number), report, SCRIPT }
  if profile ~= nil then
    assert(Fs.write(tmp .. "/profile" .. number, profile))
    argv[#argv + 1] = tmp .. "/profile" .. number
    local words: {string} = {}
    for name, value in pairs(parameters or {}) do
      words[#words + 1] = name
      words[#words + 1] = value
    end
    argv[#argv + 1] = tostring(#words)
    for _, word in ipairs(words) do argv[#argv + 1] = word end
  end
  local result = assert(Child.run(argv, { stdout = "capture", stderr = "capture", stdin = "null",
    timeout_ns = Clock.seconds(60), env = { PATH = "/usr/bin:/bin", TMPDIR = tmp } }))
  local said = "V" .. number .. " exit " .. tostring(result.code) .. "\n" .. (result.stdout or "") ..
    (result.stderr or "")
  assert(result.code == 0 and said:find("sh-pid=", 1, true), said)
  return said
end

local function test_v0_trampoline_setsid_alone(tmp: string)
  macos_only()
  local said = variant(tmp, 0)
  holds(said, "devtty%-ok")
  holds(said, "ttys%d+")
end

local function test_v1_setsid_open_and_tiocsctty_without_a_profile(tmp: string)
  macos_only()
  local said = variant(tmp, 1)
  holds(said, "devtty%-ok")
end

local function test_v2_the_same_under_a_profile_that_grants_the_terminal(tmp: string)
  macos_only()
  local text, parameters = system_profile(TERMINAL_RULES)
  local said = variant(tmp, 2, text, parameters)
  holds(said, "devtty%-ok")
  after_profile_asks(said, true)
end

local function test_v3_the_same_under_a_profile_without_the_grants(tmp: string)
  macos_only()
  local text, parameters = system_profile("")
  local said = variant(tmp, 3, text, parameters)
  holds(said, "devtty%-fail")
  holds(said, "/dev/tty: Operation not permitted")
  after_profile_asks(said, false)
end

local function test_v5_setsid_alone_under_a_profile_that_grants_the_terminal(tmp: string)
  macos_only()
  local text, parameters = system_profile(TERMINAL_RULES)
  local said = variant(tmp, 5, text, parameters)
  holds(said, "devtty%-fail")
  holds(said, "/dev/tty: Device not configured")
end

local function test_v6_setsid_alone_under_a_profile_without_the_grants(tmp: string)
  macos_only()
  local text, parameters = system_profile("")
  local said = variant(tmp, 6, text, parameters)
  holds(said, "devtty%-fail")
  holds(said, "/dev/tty: Operation not permitted")
end

local function test_v7_only_the_slave_is_granted(tmp: string)
  macos_only()
  local text, parameters = system_profile(
    '(allow file-read* file-write* file-ioctl (literal (param "TTY")))\n')
  local said = variant(tmp, 7, text, parameters)
  holds(said, "devtty%-fail")
  holds(said, "/dev/tty: Operation not permitted")
  after_profile_asks(said, true)
end

local function test_v8_only_dev_tty_is_granted(tmp: string)
  macos_only()
  local text, parameters = system_profile('(allow file-read* file-write* file-ioctl (literal "/dev/tty"))\n')
  local said = variant(tmp, 8, text, parameters)
  holds(said, "devtty%-ok")
  after_profile_asks(said, false)
end

local function test_v9_both_granted_and_the_dev_directory_readable(tmp: string)
  macos_only()
  local text, parameters = system_profile(TERMINAL_RULES .. '(allow file-read-data (literal "/dev"))\n')
  local said = variant(tmp, 9, text, parameters)
  holds(said, "devtty%-ok")
  holds(said, "/dev/ttys%d+")
  holds(said, "after%-profile:.- ttyname%(0%)=/dev/ttys%d+")
  after_profile_asks(said, true)
end

local function test_v4_posix_spawn_setsid_with_the_slave_opened_as_descriptor_0(tmp: string)
  macos_only()
  local said = variant(tmp, 4)
  holds(said, "devtty%-ok")
  holds(said, "ttys%d+")
end

--- What a child of this program says after `chunk`'s restriction: the
--- raw process table the child reaches `diagnostic_seatbelt_restrict`
--- through, the modules it needs loaded before it, and `say`.
local PRELUDE <const> = [[
local sys = require("cosmic.sys")
local Child = require("cosmic.child")
local Store = require("cosmic.store")
local function say(name, ...)
  local words = {}
  for i = 1, select("#", ...) do words[i] = tostring((select(i, ...))) end
  sys.write(2, name .. "=" .. table.concat(words, " ") .. "\n")
end
local raw
for _, searcher in ipairs(package.searchers) do
  local loader, extra = searcher("cosmic.child")
  if type(loader) == "function" and type(extra) == "table" then raw = extra end
end
local function errno_of(fd, why, code)
  if fd == nil or fd == false then return "fail(" .. tostring(why) .. ", " .. tostring(code) .. ")" end
  return "ok"
end
]]

--- Lua of the child: what is opened before restricting, the restriction,
--- and what is tried after. `text` and `parameters` are the profile.
local function restrict_chunk(text: string, parameters: {string:string}, scratch: string,
                              executable: string): string
  local words: {string} = {}
  for name, value in pairs(parameters) do
    words[#words + 1] = string.format("[%q] = %q", name, value)
  end
  return PRELUDE .. string.format([[
local profile = %q
local parameters = { %s }
local scratch = %q
local executable = %q
local file = assert(sys.open(scratch .. "/readable", sys.O_RDONLY))
local writable = assert(sys.open(scratch .. "/writable", sys.O_WRONLY | sys.O_CREAT, 420))
local pipe = assert(raw.pipe())
local pty = assert(sys.openpty())
assert(sys.dup2(pty.slave, 1))
say("before.isatty1", sys.isatty(1))
say("before.tcgetattr1", errno_of(sys.tcgetattr(1)))
say("before.store.docs", #Store.databases())
local json = require("cosmic.json")
local result, why, code = raw.diagnostic_seatbelt_restrict(profile, parameters)
say("restrict", result and "returned" or ("failed " .. tostring(why) .. " " .. tostring(code)))
if result then
  for line in result:gmatch("[^\n]+") do say("binding", line) end
end
say("read.open.file", errno_of(sys.read(file, 4)))
say("write.open.file", errno_of(sys.write(writable, "x")))
say("write.open.pipe", errno_of(sys.write(pipe.writer, "x")))
say("read.open.pipe", errno_of(sys.read(pipe.reader, 1)))
say("flock.open.file", errno_of(sys.flock(file, "shared")))
say("pread.open.file", errno_of(sys.pread(file, 1, 0)))
say("reopen.file", errno_of(sys.open(scratch .. "/readable", sys.O_RDONLY)))
say("reopen.executable", errno_of(sys.open(executable, sys.O_RDONLY)))
say("isatty1", sys.isatty(1))
say("tcgetattr1", errno_of(sys.tcgetattr(1)))
say("loaded.module.use", pcall(function() return json.encode({ 1 }) end))
for _, name in ipairs({ "cosmic.time", "cosmic.sqlite" }) do
  local was = package.loaded[name] ~= nil
  local ok, loaded = pcall(require, name)
  say("require." .. name, "already-loaded=" .. tostring(was), ok, ok and "loaded" or loaded)
end
local started, why2, code2 = Child.run({ "/usr/bin/true" }, { stdin = "null", stdout = "null", stderr = "null",
  timeout_ns = 20 * 1000 * 1000 * 1000 })
say("spawn.true", started and ("code " .. tostring(started.code)) or ("fail(" .. tostring(why2) .. ", " .. tostring(code2) .. ")"))
]], text, table.concat(words, ", "), scratch, executable)
end

local function restrict_probe(tmp: string, fork: boolean): string
  assert(Fs.write(tmp .. "/readable", "data"))
  local policy: Sandbox.Policy = { profiles = { "system" },
    grants = { { path = tmp .. "/readable", letters = "r" } }, promises = fork and { "fork" } or nil }
  local options = assert(Seatbelt.resolve(policy))
  local compiled = assert(Seatbelt.compile(policy, options))
  local relaunch = Proc.relaunch()
  local executable = relaunch ~= nil and relaunch.argv[#relaunch.argv] or assert(Proc.executable())
  local chunk = restrict_chunk(compiled.text, compiled.parameters, tmp, executable)
  local started = this_program.program({ "-e", chunk }, {
    env = this_program.environment(), stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(90) })
  local result = assert(Child.run(started.argv, started.options))
  local said = "restrict fork=" .. tostring(fork) .. " exit " .. tostring(result.code) .. "\n" ..
    (result.stdout or "") .. (result.stderr or "")
  assert(result.code == 0 and said:find("restrict=returned", 1, true), said)
  return said
end

--- What a restricted process keeps and loses, whatever its profile
--- allows of processes: the descriptors it held open keep working, a
--- second profile and a path the profile does not name are refused, the
--- terminal on descriptor 1 stays a terminal, and the store, read through
--- the descriptor it holds, still serves a module not loaded before.
local function holds_what_a_restricted_process_keeps(said: string)
  for _, line in ipairs({ "binding=init=0 errno=0", "binding=again=%-1 errno=1 error=Operation not permitted",
      "binding=check=1 errno=0", "binding=store_pread=1 errno=0", "binding=thread=0 joined=0",
      "read.open.file=ok", "write.open.file=ok", "write.open.pipe=ok", "read.open.pipe=ok",
      "flock.open.file=ok", "pread.open.file=ok", "reopen.file=ok",
      "reopen.executable=fail%(Operation not permitted, 1%)", "binding=artifact open=%-1 errno=1",
      "binding=database open=%-1 errno=1", "isatty1=true", "tcgetattr1=ok",
      "loaded.module.use=true", "require.cosmic.time=already%-loaded=false true loaded",
      "require.cosmic.sqlite=already%-loaded=true true loaded" }) do
    holds(said, line)
  end
end

local function test_restrict_without_a_fork_allowance(tmp: string)
  macos_only()
  local said = restrict_probe(tmp, false)
  holds_what_a_restricted_process_keeps(said)
  holds(said, "spawn.true=fail%(child: start: Operation not permitted")
end

local function test_restrict_with_a_fork_allowance(tmp: string)
  macos_only()
  local said = restrict_probe(tmp, true)
  holds_what_a_restricted_process_keeps(said)
  holds(said, "spawn.true=code 0")
end

local type Searcher = function(string): any, any

--- Off macOS the diagnostic binding is ENOSYS; on it, it would restrict
--- this worker, so only the child of the tests above calls it.
local function test_the_diagnostic_binding_is_enosys_off_macos()
  if assert(sys.uname()).sysname == "Darwin" then return end
  local raw: any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then raw = extra end
  end
  local report, _, code = (raw as {string:function}).diagnostic_seatbelt_restrict("", {})
  assert(report == nil and code == 38, tostring(code))
end

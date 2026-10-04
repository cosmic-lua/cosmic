--- [`Child.start`]'s `policy` with the `nest` promise (cosmic/child.tl): a
--- program that builds a sandbox of its own, in a root of its own, held
--- by that root instead of Landlock, which the kernel would have refuse
--- every mount. The kernel's own verdict on live children: a stand-in
--- (build/stand_in.tl) that starts a sandboxed child of its own, and
--- perl, where the host has it, that makes the namespaces and mounts
--- the filter lets a program make and tries the ones it must not. A host
--- that gives no user namespace or seccomp, and every platform but Linux,
--- skips the tests that start a child (build.sandbox_skip); the refusals
--- that come before a child do not.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local sandbox_skip = require("build.sandbox_skip")
local searchable = require("build.searchable")
local stand_in = require("build.stand_in")

--- The temporary directory, which a start's root is built in; the host's
--- perl and shell, which the "system" profile gives a policy to run; and
--- `nests`, since the sandboxes this test makes are roots a worker held by
--- a Landlock ruleset cannot build.
Test.policy{ env = { "TMPDIR" }, promises = { "nest" }, profiles = { "system" } }

--- Whether `why`, a start's failure, is the platform or the host giving no
--- seccomp or user namespace.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- Whether this platform cannot sandbox at all, which skips a test whose
--- start would be refused for that before what it checks: off Linux a
--- policy's start never runs, whatever its grants or descriptors.
local function no_sandbox_here(): boolean
  if confine.sandbox_platform() then return false end
  sandbox_skip.refused("a policy holds a program only on Linux")
  return true
end

--- What a program left and how it ended.
local record Outcome
  code: integer
  said: string
end

--- Runs `argv` under `policy`, starting in `cwd`: its output (stderr beside
--- stdout) and how it ended. Skips the test, returning nil, where the host
--- gives no sandbox; fails it where the start is refused for another reason.
local function under(argv: {string}, policy: Sandbox.Policy, cwd: string,
                     fds?: {integer:integer | string}): Outcome
  local result, why = Child.run(argv,
    { policy = policy, cwd = cwd, stdout = "capture", stderr = "stdout", fds = fds })
  if result == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    sandbox_skip.refused(why)
    return nil
  end
  return { code = result.code or -1, said = result.stdout or "" }
end

--- Why a start under `policy` is refused before any child exists.
local function refused(argv: {string}, policy: Sandbox.Policy): string
  local handle, why = Child.start(argv, { policy = policy })
  assert(handle == nil, "the start was not refused")
  return why
end

--- A stand-in, a working directory holding `ro/a`, a directory `rw` beside
--- it and one, `extra`, that only the first sandbox is given, and the
--- grants of the stand-in and the directories.
local record Place
  probe: string
  work: string
  extra: string
  scratch: string
  grants: {Sandbox.Grant}
end

local function placed(tmp: string): Place
  -- Real paths, which a root binds a grant at and mountinfo names.
  local base = assert(sys.realpath(searchable.open(tmp)))
  local probe = assert(stand_in.build(base .. "/stand-in"))
  local work = base .. "/work"
  assert(Fs.mkdirs(work .. "/ro") and Fs.mkdirs(work .. "/rw") and Fs.mkdirs(base .. "/extra"))
  assert(Fs.write(work .. "/ro/a", "alpha\n") and Fs.write(base .. "/extra/e", "epsilon\n"))
  -- Where a start of the program's own builds the root it makes.
  local scratch = base .. "/scratch"
  assert(Fs.mkdirs(scratch))
  searchable.share(scratch)
  searchable.share(work .. "/rw")
  return { probe = probe, work = work, extra = base .. "/extra", scratch = scratch,
    grants = { { path = probe, letters = "rx" }, { path = work, letters = "r" },
      { path = work .. "/rw", letters = "rwc" } } }
end

--- A copy of `grants` with `more` after them.
local function with(grants: {Sandbox.Grant}, ...: Sandbox.Grant): {Sandbox.Grant}
  local out: {Sandbox.Grant} = {}
  for _, grant in ipairs(grants) do out[#out + 1] = grant end
  for _, grant in ipairs({ ... }) do out[#out + 1] = grant end
  return out
end

--- The mount at `point` in a /proc/self/mountinfo `text`: its per-mount options.
local function options_at(text: string, point: string): string | nil
  for line in text:gmatch("[^\n]+") do
    local left = line:match("^(.-) %- ")
    if left ~= nil then
      local fields: {string} = {}
      for word in left:gmatch("%S+") do fields[#fields + 1] = word end
      if fields[5] == point then return fields[6] end
    end
  end
  return nil
end

local function test_nest_needs_isolate_file_and_says_so(tmp: string)
  local at = placed(tmp)
  for _, isolate in ipairs({ {}, { "proc" } }) do
    local why = refused({ at.probe }, { isolate = isolate, promises = { "nest" }, grants = at.grants })
    assert(why:find("nest", 1, true) and why:find("isolate \"file\"", 1, true), why)
  end
end

local function test_nest_refuses_what_a_root_cannot_hold(tmp: string)
  local at = placed(tmp)
  local function without(letters: string, path: string): string
    return refused({ at.probe }, { isolate = { "file" }, promises = { "nest" },
      grants = with(at.grants, { path = path, letters = letters }) })
  end
  -- Landlock told writing a file from making one in a directory, and running
  -- from reading; a bind does not.
  local made = without("w", at.extra)
  assert(made:find("add `c`", 1, true) and made:find("nest", 1, true), made)
  local run = without("x", at.extra)
  assert(run:find("add `r`", 1, true), run)
  local created = without("c", at.extra)
  assert(created:find("add `w`", 1, true), created)
end

local function test_nest_holds_files_by_the_root_alone(tmp: string)
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, promises = { "nest" }, grants = at.grants }
  local read = under({ at.probe, "cat ro/a" }, policy, at.work)
  if read == nil then return end
  assert(read.code == 0 and read.said == "alpha\n", read.code .. ": " .. read.said)
  -- Not granted, so not there; read-only where not granted `w`.
  local other = under({ at.probe, "cat " .. at.extra .. "/e" }, policy, at.work)
  assert(other.code == 1 and other.said:find("No such file or directory", 1, true), other.said)
  local ro = under({ at.probe, "create ro/b x" }, policy, at.work)
  assert(ro.code == 1 and ro.said:find("Read-only file system", 1, true), ro.said)
  local rw = under({ at.probe, "create rw/b x && cat rw/b" }, policy, at.work)
  assert(rw.code == 0 and rw.said == "x\n", rw.code .. ": " .. rw.said)
  -- What Landlock refused to run is held by the mount: a grant without `x`
  -- is noexec, read-only or not, and the program's own is not.
  local mounts = under({ at.probe, "cat /proc/self/mountinfo" }, policy, at.work)
  assert(mounts.code == 0, mounts.said)
  local read_only = options_at(mounts.said, at.work)
  assert(read_only ~= nil and read_only:find("ro", 1, true) and read_only:find("noexec", 1, true),
    tostring(read_only))
  local writable = options_at(mounts.said, at.work .. "/rw")
  assert(writable ~= nil and writable:find("rw", 1, true) and writable:find("noexec", 1, true),
    tostring(writable))
  local program = options_at(mounts.said, at.probe)
  assert(program ~= nil and not program:find("noexec", 1, true), tostring(program))
  local held = under({ at.probe, "status-field Seccomp" }, policy, at.work)
  assert(held.said:find("Seccomp:\t2", 1, true), held.said)
end

local function test_nest_hands_no_directory_nor_half_open_file(tmp: string)
  if no_sandbox_here() then return end
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, promises = { "nest" }, grants = at.grants }
  local plain: Sandbox.Policy = { isolate = { "file" }, grants = at.grants }
  local dir = assert(sys.open(at.extra, sys.O_RDONLY))
  local reading = assert(sys.open(at.extra .. "/e", sys.O_RDONLY))
  local writing = assert(sys.open(at.extra .. "/e", sys.O_WRONLY))
  local both = assert(sys.open(at.extra .. "/e", sys.O_RDWR))
  local function start(held: Sandbox.Policy, fds: {integer:integer | string}): string
    local handle, why = Child.start({ at.probe, "print hi" }, { policy = held, cwd = at.work, fds = fds })
    if handle ~= nil then
      local _, _ = handle:close()
      return ""
    end
    return why
  end
  local why = start(policy, { [3] = dir })
  assert(why:find("descriptor 3", 1, true) and why:find("directory", 1, true) and
      why:find("nest", 1, true), why)
  local shut = start(policy, { [4] = reading })
  assert(shut:find("descriptor 4", 1, true) and shut:find("reading and writing", 1, true), shut)
  assert(start(policy, { [5] = writing }):find("descriptor 5", 1, true))
  assert(start(policy, { [3] = both }) == "")
  -- A pipe has no path to reach.
  assert(start(policy, { [3] = "capture" }) == "")
  assert(start(plain, { [3] = dir }) == "")
  sys.close(dir)
  sys.close(reading)
  sys.close(writing)
  sys.close(both)
end

--- A descriptor this runtime retains of its own -- the artifact and the core
--- a relaunch hands on -- is refused to a `nest` child as a half-open file
--- is, naming it, where stat-ing it raised.
local function test_nest_refuses_the_runtimes_own_descriptors_rather_than_raising(tmp: string)
  if no_sandbox_here() then return end
  local launched, _ = Proc.relaunch()
  if launched == nil or next(launched.fds) == nil then return end
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, promises = { "nest" }, grants = at.grants }
  local handle, why = Child.start({ at.probe, "print hi" },
    { policy = policy, cwd = at.work, fds = launched.fds })
  if handle ~= nil then
    local _, _ = handle:close()
  end
  assert(handle == nil and why:find("retains of its own", 1, true) and
      why:find("nest", 1, true), tostring(why))
end

local function test_a_handed_directory_is_held_by_landlock_without_nest(tmp: string)
  local at = placed(tmp)
  local dir = assert(sys.open(at.extra, sys.O_RDONLY))
  local policy: Sandbox.Policy = { isolate = { "file" }, promises = { "fork" }, grants = at.grants }
  local ran = under({ at.probe, "cat /proc/self/fd/3/e" }, policy, at.work, { [3] = dir })
  sys.close(dir)
  if ran == nil then return end
  assert(ran.code == 1 and ran.said:find("Permission denied", 1, true), ran.code .. ": " .. ran.said)
end

--- Where a start of the program's own meets its host: the directory a root
--- is built in is in TMPDIR, which the sandbox grants.
local function nested(at: Place): Sandbox.Policy
  return { isolate = { "file" }, promises = { "fork", "nest" }, set_env = { TMPDIR = at.scratch },
    grants = with(at.grants, { path = at.scratch, letters = "rwc" },
      { path = at.extra, letters = "r" }) }
end

local function test_a_nested_sandbox_is_confined_to_its_own_grants(tmp: string)
  local at = placed(tmp)
  local policy = nested(at)
  -- The first sandbox reads the extra directory, the stand-in's own sandbox,
  -- granted the stand-in and the working directory, does not.
  local own = under({ at.probe, "cat " .. at.extra .. "/e" }, policy, at.work)
  if own == nil then return end
  assert(own.code == 0 and own.said == "epsilon\n", own.code .. ": " .. own.said)
  local ran = under({ at.probe, "run-isolated " .. at.probe .. " cat ro/a" }, policy, at.work)
  assert(ran.code == 0, ran.said)
  assert(ran.said == "exit 0\nalpha\n", ran.said)
  local hidden = under({ at.probe, "run-isolated " .. at.probe .. " cat " .. at.extra .. "/e" },
    policy, at.work)
  assert(hidden.code == 0, hidden.said)
  assert(hidden.said:find("exit 1\n", 1, true) == 1 and
      hidden.said:find("No such file or directory", 1, true), hidden.said)
  -- Nor is the scratch it was built in, nor the first sandbox's rw directory.
  local scratch = under({ at.probe, "run-isolated " .. at.probe .. " present " .. at.scratch },
    policy, at.work)
  assert(scratch.said:find("exit 1\n", 1, true) == 1 and scratch.said:find("not there", 1, true),
    scratch.said)
end

--- A start of the program's own with a network namespace of its own brings its
--- loopback up with a socket pair and the interface ioctls, which `nest` lets
--- through.
local function test_a_nested_sandbox_with_a_network_of_its_own_brings_its_loopback_up(tmp: string)
  local at = placed(tmp)
  local ran = under({ at.probe, "run-looped " .. at.probe .. " print hi" },
    nested(at), at.work)
  if ran == nil then return end
  assert(ran.code == 0 and ran.said == "exit 0\nhi\n", ran.code .. ": " .. ran.said)
end

local function test_a_nested_sandbox_needs_nest(tmp: string)
  local at = placed(tmp)
  local policy = nested(at)
  policy.promises = { "fork" }
  local ran = under({ at.probe, "run-isolated " .. at.probe .. " print hi" }, policy, at.work)
  if ran == nil then return end
  assert(ran.code == 0, ran.said)
  assert(ran.said:find("namespace was refused", 1, true), ran.said)
end

--- perl's script: what it makes of the calls a program may make, one
--- `name=result` line each, results being "ok" or the errno's name. The
--- numbers are Linux's, by architecture.
local PERL <const> = [==[
use POSIX;
my $arch = (POSIX::uname())[4];
my %n = $arch =~ /aarch64|arm64/
  ? (unshare => 97, mount => 40, umount2 => 39, setns => 268, chroot => 51)
  : (unshare => 272, mount => 165, umount2 => 166, setns => 308, chroot => 161);
my %name = (1 => "EPERM", 22 => "EINVAL", 13 => "EACCES", 2 => "ENOENT", 38 => "ENOSYS");
sub sc {
  my ($label, $call, @args) = @_;
  my $r = syscall($n{$call}, @args);
  printf("%s=%s\n", $label, $r == 0 ? "ok" : ($name{$!+0} // ($!+0)));
}
my ($ro, $rw, $tmpfs) = ("/ro", "/rw", "tmpfs");
my $uid = $<;
my $gid = $(;
$gid =~ s/ .*//;
open(my $fd, "<", "/proc/self/ns/user") or die "ns: $!";
# Before a namespace of its own it holds nothing: the kernel's refusal.
sc("mount_before", "mount", $tmpfs, $rw, $tmpfs, 0, 0);
sc("unshare_mount_before", "unshare", 0x20000);
# Never, whatever it promised: the filter's.
sc("setns", "setns", fileno($fd), 0);
sc("unshare_uts", "unshare", 0x10000000 | 0x04000000);
sc("unshare_cgroup", "unshare", 0x10000000 | 0x02000000);
sc("unshare_time", "unshare", 0x80);
sc("chroot", "chroot", "/");
sc("unshare", "unshare", 0x10000000 | 0x20000 | 0x08000000 | 0x40000000);
for my $f (["setgroups", "deny"], ["uid_map", "0 $uid 1\n"], ["gid_map", "0 $gid 1\n"]) {
  open(my $m, ">", "/proc/self/$f->[0]") or die "$f->[0]: $!";
  print $m $f->[1];
  close($m) or die "$f->[0]: $!";
}
# Inside, what it makes is its own: a tmpfs it may write.
sc("mount_tmpfs", "mount", $tmpfs, $rw, $tmpfs, 0, 0);
my $wrote = "no";
if (open(my $w, ">", "$rw/made")) { print $w "x"; $wrote = "ok" if close($w); }
print "wrote=$wrote\n";
# What it was given read-only stays so, locked: it cannot be remounted, nor
# bound again and remounted, nor unmounted to show what is beneath.
sc("remount_ro", "mount", 0, $ro, 0, 32 | 4096, 0);
sc("remount_ro_plain", "mount", 0, $ro, 0, 32, 0);
sc("bind_ro", "mount", $ro, "/tmp", 0, 4096, 0);
sc("remount_bind", "mount", 0, "/tmp", 0, 32 | 4096, 0);
sc("umount_ro", "umount2", $ro, 0);
sc("umount_ro_detach", "umount2", $ro, 2);
sc("umount_root", "umount2", "/", 2);
my $wrote_ro = open(my $x, ">", "$ro/b") ? "ok" : "no";
print "wrote_ro=$wrote_ro\n";
]==]

local function test_a_nested_program_cannot_widen_what_it_was_given(tmp: string)
  if no_sandbox_here() then return end
  local perl = Proc.find("perl")
  if perl == nil then return end
  local at = placed(tmp)
  -- The directories at the names the script uses; the working directory is
  -- the program's own, which the root must hold.
  local policy: Sandbox.Policy = { profiles = { "system" }, isolate = { "file" },
    promises = { "fork", "nest" }, tmp = true, grants = {
      { path = "/ro", letters = "r", from = at.work .. "/ro" },
      { path = "/rw", letters = "rwc", from = at.work .. "/rw" },
      { path = at.work, letters = "r" } } }
  local ran = under({ perl, "-e", PERL }, policy, at.work)
  if ran == nil then return end
  assert(ran.code == 0, ran.code .. ": " .. ran.said)
  local got: {string:string} = {}
  for name, result in ran.said:gmatch("([%w_]+)=(%w+)") do got[name] = result end
  -- The kernel and the filter refuse before a namespace of its own.
  assert(got.mount_before == "EPERM" and got.unshare_mount_before == "EPERM", ran.said)
  -- setns, chroot and the namespaces it never makes, whatever it promised.
  for _, name in ipairs({ "setns", "unshare_uts", "unshare_cgroup", "unshare_time", "chroot" }) do
    assert(got[name] == "EPERM", name .. ": " .. ran.said)
  end
  -- Its own it makes and mounts in.
  assert(got.unshare == "ok" and got.mount_tmpfs == "ok" and got.wrote == "ok", ran.said)
  -- And what it was given it cannot widen or reveal.
  assert(got.remount_ro == "EPERM" and got.remount_ro_plain == "EPERM", ran.said)
  assert(got.remount_bind == "EPERM", ran.said)
  for _, name in ipairs({ "umount_ro", "umount_ro_detach", "umount_root" }) do
    assert(got[name] == "EINVAL", name .. ": " .. ran.said)
  end
  assert(got.wrote_ro == "no", ran.said)
end

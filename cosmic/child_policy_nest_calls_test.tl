--- [`Child.start`]'s `policy` with the `nest` promise (cosmic/child.tl): the
--- kernel's verdict on a program inside such a sandbox that makes the
--- namespaces and mounts the filter lets it make, and tries the ones it must
--- not. The program is this one, making them through the raw calls every
--- core carries (cosmic.internal.testing); the rest of the `nest` cases are
--- in cosmic/child_policy_nest_test.tl. Where the platform cannot nest a sandbox
--- it is not applicable, and where this host gives no seccomp it skips itself
--- (Test.skip).

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local Proc = require("cosmic.proc")
local searchable = require("build.searchable")

--- The temporary directory, which a start's root is built in; this
--- program, which the child runs; and `nests`, since the sandbox the test
--- makes is a root a worker held by a Landlock ruleset cannot build.
Test.policy{
  env = { "TMPDIR" },
  profiles = { "cosmic" },
  promises = { "nest" },
  requires = { "nest" },
}

--- Whether `why`, a start's failure, is the host giving no seccomp or user
--- namespace.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- What the chunk makes of the calls a program may make, one `name=result`
--- line each, results being "ok" or the errno's name. The flags are
--- Linux's: CLONE_NEWNS 0x20000, CLONE_NEWUSER 0x10000000, CLONE_NEWUTS
--- 0x04000000, CLONE_NEWCGROUP 0x02000000, CLONE_NEWTIME 0x80, CLONE_NEWIPC
--- 0x08000000, CLONE_NEWNET 0x40000000; MS_REMOUNT 32, MS_BIND 4096;
--- MNT_DETACH 2.
local CHUNK <const> = [==[
local testing = require("cosmic.internal.testing")
local sys = require("cosmic.sys")
local named = { [sys.EPERM] = "EPERM", [sys.EINVAL] = "EINVAL", [sys.EACCES] = "EACCES",
  [sys.ENOENT] = "ENOENT", [sys.ENOSYS] = "ENOSYS" }
local function say(label, ok, _, errno)
  print(label .. "=" .. (ok and "ok" or (named[errno] or tostring(errno))))
end
-- Whether `text` is the whole of `path`, written through one descriptor
-- (a /proc file takes no temporary and rename).
local function wrote(path, text, flags)
  local fd = sys.open(path, flags)
  if fd == nil then return false end
  local n = sys.write(fd, text)
  return sys.close(fd) and n == #text
end
local ro, rw, tmpfs = "/ro", "/rw", "tmpfs"
local uid, gid = sys.getuid(), sys.getgid()
local fd = assert(sys.open("/proc/self/ns/user", sys.O_RDONLY))
-- Before a namespace of its own it holds nothing: the kernel's refusal.
say("mount_before", testing.mount(tmpfs, rw, tmpfs, 0))
say("unshare_mount_before", testing.unshare(0x20000))
-- Never, whatever it promised: the filter's.
say("setns", testing.setns(fd, 0))
say("unshare_uts", testing.unshare(0x10000000 | 0x04000000))
say("unshare_cgroup", testing.unshare(0x10000000 | 0x02000000))
say("unshare_time", testing.unshare(0x80))
say("chroot", testing.chroot("/"))
say("unshare", testing.unshare(0x10000000 | 0x20000 | 0x08000000 | 0x40000000))
for _, f in ipairs({ { "setgroups", "deny" }, { "uid_map", "0 " .. uid .. " 1\n" },
    { "gid_map", "0 " .. gid .. " 1\n" } }) do
  assert(wrote("/proc/self/" .. f[1], f[2], sys.O_WRONLY), f[1])
end
-- Inside, what it makes is its own: a tmpfs it may write.
say("mount_tmpfs", testing.mount(tmpfs, rw, tmpfs, 0))
print("wrote=" .. (wrote(rw .. "/made", "x", sys.O_WRONLY | sys.O_CREAT) and "ok" or "no"))
-- What it was given read-only stays so, locked: it cannot be remounted, nor
-- bound again and remounted, nor unmounted to show what is beneath.
say("remount_ro", testing.mount(nil, ro, nil, 32 | 4096))
say("remount_ro_plain", testing.mount(nil, ro, nil, 32))
say("bind_ro", testing.mount(ro, "/tmp", nil, 4096))
say("remount_bind", testing.mount(nil, "/tmp", nil, 32 | 4096))
say("umount_ro", testing.umount2(ro, 0))
say("umount_ro_detach", testing.umount2(ro, 2))
say("umount_root", testing.umount2("/", 2))
print("wrote_ro=" .. (wrote(ro .. "/b", "", sys.O_WRONLY | sys.O_CREAT) and "ok" or "no"))
]==]

local function test_a_nested_program_cannot_widen_what_it_was_given(tmp: string)
  -- Real paths, which a root binds a grant at.
  local base = assert(sys.realpath(searchable.open(tmp)))
  local work = base .. "/work"
  assert(Fs.mkdirs(work .. "/ro") and Fs.mkdirs(work .. "/rw"))
  assert(Fs.write(work .. "/ro/a", "alpha\n"))
  searchable.share(work .. "/rw")
  -- The directories at the names the chunk uses; the working directory is
  -- the program's own, which the root must hold.
  local policy: Sandbox.Policy = { profiles = { "cosmic" }, isolate = { "file" },
    promises = { "fork", "nest" }, tmp = true, grants = {
      { path = "/ro", letters = "r", from = work .. "/ro" },
      { path = "/rw", letters = "rwc", from = work .. "/rw" },
      { path = work, letters = "r" } } }
  -- This program by the path it is started by: a start under a policy runs
  -- it by a relaunch of its own core, which build.this_program's command
  -- line already is.
  local result, why = Child.run({ assert(Proc.executable()), "-e", CHUNK },
    { policy = policy, cwd = work, stdout = "capture", stderr = "stdout" })
  if result == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip(why)
    return
  end
  local said = result.stdout or ""
  assert(result.code == 0, tostring(result.code) .. ": " .. said)
  local got: {string:string} = {}
  for name, outcome in said:gmatch("([%w_]+)=(%w+)") do got[name] = outcome end
  -- The kernel and the filter refuse before a namespace of its own.
  assert(got.mount_before == "EPERM" and got.unshare_mount_before == "EPERM", said)
  -- setns, chroot and the namespaces it never makes, whatever it promised.
  for _, name in ipairs({ "setns", "unshare_uts", "unshare_cgroup", "unshare_time", "chroot" }) do
    assert(got[name] == "EPERM", name .. ": " .. said)
  end
  -- Its own it makes and mounts in.
  assert(got.unshare == "ok" and got.mount_tmpfs == "ok" and got.wrote == "ok", said)
  -- And what it was given it cannot widen or reveal.
  assert(got.remount_ro == "EPERM" and got.remount_ro_plain == "EPERM", said)
  assert(got.remount_bind == "EPERM", said)
  for _, name in ipairs({ "umount_ro", "umount_ro_detach", "umount_root" }) do
    assert(got[name] == "EINVAL", name .. ": " .. said)
  end
  assert(got.wrote_ro == "no", said)
end

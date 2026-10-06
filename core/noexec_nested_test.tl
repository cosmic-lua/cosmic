--- Declared noexec scratch stays so through a namespace of a child's own: a
--- bind of it is noexec too, and remounting the bind to clear that is
--- refused. The child is this program, making the calls through the raw ones
--- every core carries (cosmic.internal.testing), in a user namespace of its
--- own, so this module requires `userns`; the rest of the noexec cases are
--- in core/noexec_tool_test.tl.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local stand_in = require("build.stand_in")
local this_program = require("build.this_program")

--- The declared scratch; this program, which the child runs; and
--- permission to make the mount namespace the child binds in.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "/noexec", letters = "rwc" } },
  promises = { "nest" },
  requires = { "userns" },
}

--- The chunk the child runs on the noexec scratch and the directory to bind
--- it at: it makes a user and mount namespace of its own (CLONE_NEWUSER
--- 0x10000000, CLONE_NEWNS 0x20000), binds the scratch (MS_BIND 4096),
--- tries to remount the bind exec (MS_REMOUNT 32), and tries to run the
--- program through it, which, run, would exit 97 and print nothing.
local CHUNK <const> = [==[
local testing = require("cosmic.internal.testing")
local sys = require("cosmic.sys")
local noexec, alias = %q, %q
local uid, gid = sys.getuid(), sys.getgid()
assert(testing.unshare(0x10000000 | 0x20000))
for _, f in ipairs({ { "setgroups", "deny" }, { "uid_map", "0 " .. uid .. " 1\n" },
    { "gid_map", "0 " .. gid .. " 1\n" } }) do
  local fd = assert(sys.open("/proc/self/" .. f[1], sys.O_WRONLY))
  assert(sys.write(fd, f[2]) == #f[2], f[1])
  assert(sys.close(fd))
end
assert(testing.mount(noexec, alias, nil, 4096))
local cleared, _, errno = testing.mount(nil, alias, nil, 32 | 4096)
print("remount=" .. (cleared and "ok" or tostring(errno)))
local _, _, refused = sys.execve(alias .. "/program", { alias .. "/program", "exit 97" }, {})
print("exec=" .. tostring(refused))
]==]

local function test_nested_bind_preserves_noexec_and_cannot_clear_it(tmp: string)
  local ordinary = tmp .. "/ordinary"
  assert(stand_in.place(assert(stand_in.build(tmp .. "/stand-in")), ordinary))
  local noexec = assert(Env.get("COSMIC_TEST_NOEXEC"))
  assert(noexec == "/noexec" and noexec ~= Env.get("TMPDIR"))
  local path = noexec .. "/program"
  assert(Fs.write(path, assert(Fs.read(ordinary)), 0x1c0))
  local alias = tmp .. "/bound"
  assert(Fs.mkdirs(alias))
  local started = this_program.program({ "-e", CHUNK:format(noexec, alias) },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(10) })
  local result, trouble = Child.run(started.argv, started.options)
  assert(result ~= nil, trouble)
  local said = tostring(result.stdout) .. tostring(result.stderr)
  assert(result.ok, said)
  local got: {string:string} = {}
  for name, outcome in said:gmatch("([%w_]+)=(%w+)") do got[name] = outcome end
  -- The remount is refused, not merely a no-op, and the bind runs nothing.
  assert(got.remount ~= nil and got.remount ~= "ok", "nested bind cleared noexec: " .. said)
  assert(got.exec == tostring(sys.EACCES), "nested alias: " .. said)
  local ok, why, errno = sys.execve(path, { path, "exit 97" }, {})
  assert(not ok and errno == sys.EACCES, why)
end

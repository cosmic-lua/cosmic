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
local test_child = require("build.test_child")
local testing = require("cosmic.internal.testing")
local this_program = require("build.this_program")

--- The declared scratch; this program, which the child runs; and
--- permission to make the mount namespace the child binds in.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "/noexec", letters = "rwc" } },
  promises = { "nest" },
  requires = { "userns" },
}

--- The child that runs on the noexec scratch (its first word) and the directory to bind
--- it at (its second): it makes a user and mount namespace of its own (CLONE_NEWUSER
--- 0x10000000, CLONE_NEWNS 0x20000), binds the scratch (MS_BIND 4096),
--- tries to remount the bind exec (MS_REMOUNT 32), and tries to run the
--- program through it, which, run, would exit 97 and print nothing.
test_child.register("nested bind", function(args: {string}): integer
  local noexec, alias = assert(args[1]), assert(args[2])
  local uid, gid = sys.getuid(), sys.getgid()
  -- A refusal of the namespace or of the write of its ids is said as
  -- `setup_<step>=<errno>` and ends the child: the test decides what it is.
  local made, _, errno = testing.unshare(0x10000000 | 0x20000)
  if not made then
    print("setup_unshare=" .. tostring(errno))
    return 0
  end
  local steps: {{string}} = { { "setgroups", "deny" }, { "uid_map", "0 " .. tostring(uid) .. " 1\n" },
    { "gid_map", "0 " .. tostring(gid) .. " 1\n" } }
  for _, step in ipairs(steps) do
    local name, text = assert(step[1]), assert(step[2])
    local fd, _, open_errno = sys.open("/proc/self/" .. name, sys.O_WRONLY)
    if fd == nil then
      print("setup_" .. name .. "=" .. tostring(open_errno))
      return 0
    end
    local n, _, write_errno = sys.write(fd, text)
    assert(sys.close(fd))
    if n ~= #text then
      print("setup_" .. name .. "=" .. tostring(write_errno))
      return 0
    end
  end
  assert(testing.mount(noexec, alias, nil, 4096))
  local cleared, _, refused_errno = testing.mount(nil, alias, nil, 32 | 4096)
  print("remount=" .. (if cleared then "ok" else tostring(refused_errno) end))
  local _, _, refused = sys.execve(alias .. "/program", { alias .. "/program", "exit 97" }, {})
  print("exec=" .. tostring(refused))
  return 0
end)

local function test_nested_bind_preserves_noexec_and_cannot_clear_it(tmp: string)
  local ordinary = tmp .. "/ordinary"
  assert(stand_in.place(assert(stand_in.build(tmp .. "/stand-in")), ordinary))
  local noexec = assert(Env.get("COSMIC_TEST_NOEXEC"))
  assert(noexec == "/noexec" and noexec ~= Env.get("TMPDIR"))
  local path = noexec .. "/program"
  assert(Fs.write(path, assert(Fs.read(ordinary)), 0x1c0))
  local alias = tmp .. "/bound"
  assert(Fs.mkdirs(alias))
  local started = this_program.program(test_child.words(tmp, "core.noexec_nested_test", "nested bind", { noexec, alias }),
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(10) })
  local result, trouble = Child.run(started.argv, started.options)
  assert(result ~= nil, trouble)
  local said = tostring(result.stdout) .. tostring(result.stderr)
  assert(result.ok, said)
  local got: mut {string:string} = {}
  for name, outcome in said:gmatch("([%w_]+)=(%w+)") do got[name] = outcome end
  -- A host that gives the sandbox but refuses a namespace of its own, or
  -- the write of its ids (AppArmor's restriction), cannot be asked.
  for name, outcome in pairs(got) do
    if name:sub(1, 6) == "setup_" then
      local refused = outcome == tostring(sys.EPERM) or outcome == tostring(sys.EACCES)
      assert(refused, name:sub(7) .. " failed: " .. said)
      Test.skip(name:sub(7) .. " was refused here (errno " .. outcome .. ")")
      return
    end
  end
  -- The remount is refused, not merely a no-op, and the bind runs nothing.
  assert(got.remount ~= nil and got.remount ~= "ok", "nested bind cleared noexec: " .. said)
  assert(got.exec == tostring(sys.EACCES), "nested alias: " .. said)
  local ok, why, errno = sys.execve(path, { path, "exit 97" }, {})
  assert(not ok and errno == sys.EACCES, why)
end

--- Required Linux CI proof for Child's ordinary credential transition.
--- The small setup/probe executable establishes privileged prerequisites;
--- this driver exercises the real public API without a root test suite.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local record Proof
end

local function identity(): string
  local status = assert(Fs.read("/proc/self/status"))
  local fields: {string} = {}
  for _, name in ipairs({ "Uid", "Gid", "Groups", "CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb", "NoNewPrivs" }) do
    fields[#fields + 1] = assert(status:match("\n" .. name .. ":([^\n]*)"), name)
  end
  return table.concat(fields, "\n")
end

local function exists(path: string): boolean
  local found, trouble = Fs.exists(path)
  assert(found ~= nil, trouble)
  return found
end

local function children(): string
  local pid = tostring(sys.getpid())
  return (assert(Fs.read("/proc/self/task/" .. pid .. "/children")))
end

function Proof.main(argv: {integer:string}): integer
  assert(argv[1] ~= nil and argv[2] ~= nil and argv[3] ~= nil and argv[4] == nil,
    "credentials proof needs helper, directory and mode")
  local helper, directory, mode = argv[1], argv[2], argv[3]
  assert(sys.getuid() == 0 and sys.getgid() == 0, "credentials proof requires root")
  local groups = assert(sys.getgroups())
  assert(#groups == 2 and groups[1] == 17 and groups[2] == 23, "setup groups missing")
  local before = identity()
  local status = assert(Fs.read("/proc/self/status"))
  for _, name in ipairs({ "CapInh", "CapAmb" }) do
    local bits = assert(status:match("\n" .. name .. ":%s*(%x+)"), name)
    assert(tonumber(bits, 16) ~= 0, "setup " .. name .. " missing")
  end
  local owned_before = children()
  local secret = directory .. "/secret/file"
  local marker = directory .. "/target/" .. mode
  local credentials: Child.Credentials = { user = 65532, group = 65532 }
  if mode ~= "success" then
    -- For restore, exec may have occurred; cleanup must still leave no
    -- owned child. Every other refusal precedes target execution.
    local started, trouble = Child.start({ helper, "marker", marker },
      { credentials = credentials, stdout = "capture", stderr = "capture" })
    assert(started == nil and trouble ~= "", "injected refusal started a child")
    assert(children() == owned_before, "failed start left an owned child")
    assert(identity() == before, "failed start changed parent credentials")
    if mode ~= "restore" then assert(not exists(marker), "failed setup reached exec") end
    if mode ~= "capture" and mode ~= "restore" then
      assert(assert(sys.dumpable()) == 1, "failed setup changed parent dumpability")
    end
    print("credentials: PASS (" .. mode .. ")")
    return 0
  end
  local grant = assert(Fs.open_read(secret))
  for _, dumpable in ipairs({ 0, 1 }) do
    assert(assert(sys.dumpable(dumpable)) == dumpable)
    for _, binary in ipairs({ helper, directory .. "/setuid-probe" }) do
      assert(assert(sys.lseek(grant, 0, sys.SEEK_SET)) == 0)
      local result, trouble = Child.run({ binary, "probe", secret, marker }, {
        credentials = credentials, cwd = directory .. "/target", fds = { [9] = grant },
        stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(5),
      })
      assert(result ~= nil, trouble)
      assert(result.ok, tostring(result.stderr))
      assert(exists(marker), "probe never completed")
      assert(Fs.remove(marker))
      assert(assert(sys.dumpable()) == dumpable, "successful start changed parent dumpability")
      assert(identity() == before, "successful start changed parent credentials")
    end
    local denied, trouble = Child.start({ helper, "marker", marker },
      { credentials = credentials, cwd = directory .. "/secret" })
    assert(denied == nil and trouble ~= "", "root-only cwd accepted")
    assert(not exists(marker), "cwd refusal reached exec")
    assert(assert(sys.dumpable()) == dumpable, "cwd failure changed parent dumpability")
    assert(identity() == before and children() == owned_before, "cwd failure changed parent ownership")
  end
  assert(sys.close(grant))
  print("credentials: PASS (IDs, groups, capabilities, no_new_privs, grants and parent state)")
  return 0
end

return Proof

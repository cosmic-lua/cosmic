--- The cases of cosmic.child's `end_strays`, which finds the strays a
--- process adopted in /proc's list of its children
--- (/proc/thread-self/children, which a kernel built without
--- CONFIG_PROC_CHILDREN lacks). Each child is this program again
--- (build/child_lua_fixture.tl), as in cosmic/child_lua_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local fixture = require("build.child_lua_fixture")

--- /proc, where a test reads a stray's name; and the program itself,
--- started past its launcher (`lua`).
Test.policy{
  profiles = { "cosmic", "proc" },
  requires = { "path:/proc/thread-self/children" },
}

local FS <const> = fixture.FS
local AGAIN <const> = fixture.AGAIN
local sleep = fixture.sleeping

--- The child each test starts ([`build/child_lua_fixture.tl`]'s `lua`): its
--- argv and options, for [`Child.run`] or [`Child.start`].
local function lua(chunk: string, args?: {string}, opts?: Child.Options): {string}, Child.Options
  local started = fixture.lua(chunk, args, opts)
  return started.argv, started.options
end

--- `end_strays` ends a stray whatever it calls itself: one named as a
--- sandbox's init is (/proc/<pid>/comm), since only the process table's
--- own record says which children are inits. The stray is orphaned to
--- this process, which adopts it, in the worker's pid namespace. It has
--- the name by the one it is run by, a link to this program, which exec
--- gives its comm, and not by a write to /proc/self/comm, which a policy
--- grants no process of a sandbox.
local function test_end_strays_ends_a_stray_named_as_an_init(tmp: string)
  local link = tmp .. "/cosmic-init"
  assert(Fs.symlink(this_program.program({}).argv[1], link))
  do
    -- A group started first makes this process the subreaper it adopts
    -- the stray as.
    assert(Child.run(lua("")))
    local r = assert(Child.run(lua(AGAIN .. 'local started = this_program.program({ "-e", [=[' ..
        "while true do " .. sleep(1000) .. "end]=] }, " ..
        '{ process_group = false, stdout = "null", stderr = "null" }) ' ..
        "started.argv[1] = " .. string.format("%q", link) .. " " ..
        "local h = assert(Child.start(started.argv, started.options)) " .. FS ..
        'Fs.put(1, tostring(h.pid)) require("cosmic.sys").exit(0)', nil,
      { stdout = "capture", process_group = false })))
    local pid = assert(math.tointeger(tonumber(r.stdout)))
    local name = Fs.read("/proc/" .. tostring(pid) .. "/comm")
    local by = Clock.monotonic_ns() + Clock.seconds(5)
    while name ~= "cosmic-init\n" and Clock.monotonic_ns() < by do
      Clock.sleep_ns(Clock.ms(10))
      name = Fs.read("/proc/" .. tostring(pid) .. "/comm")
    end
    assert(name == "cosmic-init\n", tostring(name))
    assert(Child.end_strays() >= 1)
    local alive, _, errno = sys.kill(pid, 0)
    assert(not alive and errno == sys.ESRCH, "the stray named cosmic-init survived")
  end
end

--- `end_strays` leaves running a stray in a group it is told to spare
--- -- here this process's own, which the stray is orphaned in -- and
--- ends it once told to spare none.
local function test_end_strays_spares_a_stray_in_a_spared_group()
  -- A group started first makes this process the subreaper it adopts
  -- the stray as.
  assert(Child.run(lua("")))
  local r = assert(Child.run(lua(AGAIN .. "local h = again('" .. sleep(30000) ..
      "', { process_group = false, stdout = \"null\", stderr = \"null\" }) " .. FS ..
      'Fs.put(1, tostring(h.pid)) require("cosmic.sys").exit(0)', nil,
    { stdout = "capture", process_group = false })))
  local pid = assert(math.tointeger(tonumber(r.stdout)))
  local group = assert(sys.getpgid(0))
  assert(sys.getpgid(pid) == group)
  assert(Child.end_strays({ group }) == 0)
  assert(sys.kill(pid, 0), "the spared stray was ended")
  assert(Child.end_strays() >= 1)
  local alive, _, errno = sys.kill(pid, 0)
  assert(not alive and errno == sys.ESRCH, "the stray survived")
end

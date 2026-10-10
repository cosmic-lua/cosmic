--- A process a test confines (build.confine's `confine`) is given the system's
--- own paths, which only a worker given them has to give: the case of
--- build/test_sandbox_test.tl and build/confine_test.tl that looks for
--- /usr, and so declares the profile "system" itself. It needs a host with
--- a /usr (`requires`): /usr/bin/env stands for it, a directory being no
--- file a policy grants.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local confine = require("build.confine")
local stand_in = require("build.stand_in")
local Test = require("cosmic.test")

--- The system's own paths; `nests`, since a process it confines has a
--- root of its own; and `tool`: a process confined is given the program,
--- and the case starts it.
Test.policy{
  profiles = { "system", "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/dev/urandom", letters = "r" },
    { path = "/usr/bin/env", letters = "r" } },
  promises = { "nest" },
  requires = { "path:/usr/bin/env" },
}

--- A process a test confines is given the system's own paths beside
--- what the test declared, where its worker has them -- here, since this
--- module declares `system`. Where the kernel cannot confine it, it runs
--- unconfined, and sees /usr all the same.
local function test_a_confined_process_is_given_the_system_s_paths(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local code: integer = nil
  local ran = confine.call(function()
    confine.confine({ reads = { probe } })
    local r = assert(Child.run({ probe, "present /usr || exit 3" }, { env = {} }))
    confine.confine(nil)
    code = r.code
  end, nil, { own })
  assert(ran.ok, tostring(ran.produced))
  assert(code == 0, "the process did not see /usr: " .. tostring(code))
end

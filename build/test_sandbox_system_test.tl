--- A process a module that declares `system` confines (build.confine's
--- `confine`): the case of build/filesystem_observations_test.tl that
--- looks for the system's own paths, which only a worker given them has
--- to give, and so declares them itself. The plan's case, for a worker
--- of such a module (build/test_sandbox.tl), is
--- build/test_sandbox_system_tool_test.tl's.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local confine = require("build.confine")
local observations = require("build.filesystem_observations")
local stand_in = require("build.stand_in")
local Test = require("cosmic.test")

--- The system's own paths, which a confined process looks for where the
--- host has them, and /proc, where the stand-in it runs finds itself.
Test.needs{
  host = { "/proc" },
  system = true,
}

--- Whether `list` holds `value`.
local function holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- A process a test confines is given the system's own paths beside
--- what the test declared, where its worker has them -- here, since this
--- module declares `system` -- and each is noted "u", as a path given
--- is. Where the kernel cannot confine it, it runs unconfined, noted "p".
local function test_a_confined_process_is_given_the_system_s_paths(tmp: string)
  if Fs.exists("/usr") ~= true then return end -- no /usr to give
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local code: integer = nil
  local run = observations.call(function()
    confine.confine({ reads = { probe } })
    local r = assert(Child.run({ probe, "present /usr || exit 3" }, { env = {} }))
    confine.confine(nil)
    code = r.code
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local notes: {string} = {}
  local unconfined = false
  for _, observation in ipairs(run.reads) do
    if observation.kind == "p" then unconfined = true end
    if observation.kind == "u" then notes[#notes + 1] = observation.path end
  end
  local text = table.concat(notes, "\n") .. "\n"
  assert(code == 0, "the process did not see /usr: " .. tostring(code))
  if unconfined then return end
  assert(holds(notes, "/usr"), text)
  assert(holds(notes, probe), text)
end

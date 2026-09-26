local SandboxProbe = require("build.sandbox_probe")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- What the probe reads of the host, and the shell it starts under each
--- sandbox, which inherits the environment: it asks what the host holds.
Test.needs{
  host = { "/etc", "/proc", "/usr/" },
  env = { "*" },
  processes = true,
}

--- A report of a host where every part held but the unveiling.
local function without_unveil(): SandboxProbe.Report
  return {
    parts = {
      { name = "landlock", needed = false, held = true, said = "held" },
      { name = "unveil", needed = true, held = false, said = "EPERM (Operation not permitted)" },
      { name = "offline", needed = true, held = true, said = "held" },
    },
    host = { { "kernel", "6.8.0" }, { "AppArmor label", "docker-default (enforce)" } },
  }
end

--- A part a confined test needs that did not hold makes confinement
--- unavailable, and the report names it and why; one it does not need
--- does not.
local function test_a_needed_part_that_fails_makes_confinement_unavailable()
  local report = without_unveil()
  local ok, missing = SandboxProbe.enforceable(report)
  assert(not ok and missing == "unveil", missing)
  local text = SandboxProbe.markdown(report)
  assert(text:find("| unveil | yes | **failed**: EPERM (Operation not permitted) |", 1, true), text)
  assert(text:find("| AppArmor label | docker-default (enforce) |", 1, true), text)
  assert(text:find("Confinement: **unavailable** (unveil).", 1, true), text)
  report.parts[2].held = true
  report.parts[1].held = false
  assert(SandboxProbe.enforceable(report))
  assert(SandboxProbe.markdown(report):find("Confinement: available.", 1, true))
end

--- A pipe in what a part said does not end its table cell early.
local function test_a_pipe_in_a_reason_stays_in_its_cell()
  local report = without_unveil()
  report.parts[2].said = "exited 1: a|b"
  assert(SandboxProbe.markdown(report):find("exited 1: a\\|b |", 1, true))
end

local function test_an_errno_is_named()
  assert(SandboxProbe.errno_name(sys.EPERM) == "EPERM")
  assert(SandboxProbe.errno_name(sys.ENOSYS) == "ENOSYS")
  assert(SandboxProbe.errno_name(-7) == "errno -7")
end

--- Every part is tried, and each either held or says why not.
local function test_every_part_is_tried(tmp: string)
  local report = SandboxProbe.run(tmp)
  local names: {string} = {}
  for _, part in ipairs(report.parts) do
    names[#names + 1] = part.name
    assert(part.held == (part.said == "held") and part.said ~= "", part.name .. ": " .. part.said)
  end
  assert(table.concat(names, ",") ==
    "landlock,pledge,offline,unveil,unveil + offline (a confined test),all four",
    table.concat(names, ","))
  assert(#report.host > 0)
end

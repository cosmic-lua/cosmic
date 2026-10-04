local SandboxProbe = require("build.sandbox_probe")
local Test = require("cosmic.test")

--- The probe reads what the host holds (/proc), and starts a shell under
--- each sandbox, which, as a confined test that starts one would, needs
--- the system's paths (`system`). The parts it tries unveil a root of the shell's own (`nests`).
Test.needs{
  host = { "/proc" },
  nests = true,
  system = true,
}

--- Every part is tried, and each either held or says why not.
local function test_every_part_is_tried(tmp: string)
  local report = SandboxProbe.run(tmp)
  local names: {string} = {}
  for _, part in ipairs(report.parts) do
    names[#names + 1] = part.name
    assert(part.held == (part.said == "held") and part.said ~= "", part.name .. ": " .. part.said)
  end
  assert(table.concat(names, ",") ==
      "landlock,pledge,offline,unveil,unveil + offline (a confined test)," ..
      "unveiled: a pid namespace of its own,unveiled: a /proc of its own,all four",
    table.concat(names, ","))
  assert(#report.host > 0)
end

local SandboxProbe = require("build.sandbox_probe")
local Test = require("cosmic.test")

--- What the probe reads of the host, and the shell it starts under each
--- sandbox, which inherits the environment: it asks what the host holds,
--- and a host confines a shell with the system's paths by design -- what
--- a confined test that starts one needs -- so this keeps `system`; and
--- `nests`, since the parts it tries unveil a root of the shell's own.
Test.needs{
  host = { "/proc" },
  env = { "*" },
  processes = true,
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

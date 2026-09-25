local Fs = require("cosmic.fs")
local reboot = require("build.reboot")
local observations = require("build.filesystem_observations")

-- What these tests start is a stand-in for bin/zig the test writes.
observations.confine({})

--- A core change boots unless COSMIC_AUTO_BOOT is "0".
local function test_auto_boot_unless_told_not_to()
  assert(reboot.auto_boot({}))
  assert(reboot.auto_boot({ COSMIC_AUTO_BOOT = "1" }))
  assert(not reboot.auto_boot({ COSMIC_AUTO_BOOT = "0" }))
end

--- A tree whose bin/zig is a stand-in that records how it was run and
--- exits with `status`.
local function tree_with_zig(tmp: string, status: integer): string
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/bin"))
  assert(Fs.write(root .. "/bin/zig",
    "#!/bin/sh\necho \"$*\" > \"$(dirname \"$0\")/ran\"\n" ..
    "echo built\nexit " .. tostring(status) .. "\n", 0x1ed))
  return root
end

--- A boot that fails is reported, not re-entered.
local function test_boot_into_reports_a_failed_boot(tmp: string)
  local root = tree_with_zig(tmp, 1)
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  assert(trouble:find("bin/zig build boot failed", 1, true), trouble)
  assert(Fs.read(root .. "/bin/ran") == "build boot\n")
end

--- After a boot, the tool it wrote is what runs the command again; one
--- that is not there is reported rather than silently skipped.
local function test_boot_into_enters_the_booted_tool(tmp: string)
  local root = tree_with_zig(tmp, 0)
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  assert(Fs.read(root .. "/bin/ran") == "build boot\n")
  assert(trouble ~= "", "boot_into returned without a reason")
end

--- A tool still stale after its own boot refuses instead of booting again.
local function test_boot_into_boots_once(tmp: string)
  local root = tree_with_zig(tmp, 0)
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" },
    { COSMIC_REBOOTED = "1" })
  assert(trouble == "the tool is still stale after a reboot", trouble)
  assert(Fs.read(root .. "/bin/ran") == nil, "booted a second time")
end

--- Only a binary under the tree's o/ is its own tool, judged by the
--- path it was started as, its directory resolved: a link into o/ from
--- outside is outside, a name in o/ is inside even when the file is gone
--- (renamed or removed while it runs), and a directory link into o/
--- counts. A tree with no o/ has no tool of its own to judge.
local function test_own_tool_is_a_binary_under_the_trees_outputs(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o/bin"))
  assert(Fs.mkdirs(root .. "/o/sanitized/bin"))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  for _, path in ipairs({ root .. "/o/bin/cosmic",
      root .. "/o/sanitized/bin/cosmic", tmp .. "/elsewhere/cosmic" }) do
    assert(Fs.write(path, "binary", 0x1ed))
  end
  assert(Fs.symlink(root .. "/o/bin/cosmic", tmp .. "/elsewhere/into"))
  assert(Fs.symlink(root .. "/o/bin", tmp .. "/bin-link"))
  local cases: {string:boolean} = {
    [root .. "/o/bin/cosmic"] = true,
    [root .. "/o/sanitized/bin/cosmic"] = true,
    [root .. "/o/bin/gone"] = true,
    [tmp .. "/bin-link/cosmic"] = true,
    [tmp .. "/elsewhere/into"] = false,
    [tmp .. "/elsewhere/cosmic"] = false,
  }
  for path, want in pairs(cases) do
    local own, trouble = reboot.own_tool(root, path)
    assert(own == want, path .. ": " .. tostring(own) .. " " .. trouble)
  end
  local none, missing = reboot.own_tool(tmp .. "/elsewhere", tmp .. "/elsewhere/cosmic")
  assert(none == nil and missing:find("/elsewhere/o", 1, true), missing)
end

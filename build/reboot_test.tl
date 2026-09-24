local Fs = require("cosmic.fs")
local reboot = require("build.reboot")

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

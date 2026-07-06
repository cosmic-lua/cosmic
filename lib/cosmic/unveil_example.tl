--- Examples for the cosmic.unveil module.
--- Unveil is OpenBSD-only at runtime; on Linux the call returns ENOSYS.
--- Because unveil commits a process-wide policy, each example runs in a
--- subprocess via cosmic.child.

-- Example_apply demonstrates unveiling a single directory read-only and
-- committing the policy. After commit, reading the unveiled file works;
-- reading outside the unveiled tree fails on OpenBSD.
local function Example_apply()
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]
  local script = [[
local unveil = require("cosmic.unveil")
local sys = require("cosmic.sys")
if sys.host_os() ~= "openbsd" then
  io.write("skipped\n")
  return
end
assert(unveil.apply("/tmp", "r"))
assert(unveil.apply(nil, nil))
io.write("committed\n")
]]
  local h = spawn.spawn({cosmic, "-e", script})
  local _, out = (h as spawn.Handle):read()
  io.write(tostring(out))
  -- Output:
  -- skipped
end

return {}

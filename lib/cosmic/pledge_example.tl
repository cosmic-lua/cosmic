--- Examples for the cosmic.pledge module.
--- Pledge is irreversible, so each example runs the pledged code in a
--- subprocess via cosmic.child and captures the result.

-- Example_apply demonstrates narrowing the current process to the
-- "stdio" promise set. After pledge.apply returns, file-opening calls
-- fail with EPERM on Linux (or kill the process on OpenBSD).
local function Example_apply()
  local spawn = require("cosmic.child")
  local cosmic = arg[-1]
  local script = [[
local pledge = require("cosmic.pledge")
assert(pledge.apply("stdio"))
io.write("stdio only\n")
]]
  local r = spawn.run({cosmic, "-e", script}) as spawn.Result
  io.write(r.stdout)
  -- Output:
  -- stdio only
end

return {}
